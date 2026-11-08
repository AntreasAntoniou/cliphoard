import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

/// Sequential local-media extraction. The caller must hold file access and admit privacy/Pro
/// before construction and each callback. No extracted plaintext is written to disk.
/// Limits bound input size and emitted buffers, not internal AVFoundation codec allocations.
final class MediaAssetDecoder: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case invalidLimits, invalidFile, changedFile, limitExceeded, unsupported, invalidPlan, busy, cancelled
    }
    struct Limits {
        var maximumFileBytes: Int64 = 2 * 1024 * 1024 * 1024
        var maximumDuration: Double = 6 * 3600
        var maximumFrameDimension: Int = 1024
        var maximumSourcePixels: Int = 3840 * 2160
        var maximumEncodedFrameBytes: Int = 8 * 1024 * 1024
        var maximumOutputBytes: Int = 64 * 1024 * 1024
        var deadlineSeconds: Double = 120
        fileprivate func validate() throws {
            guard maximumFileBytes > 0, maximumFileBytes <= 2 * 1024 * 1024 * 1024,
                  maximumDuration.isFinite, maximumDuration > 0, maximumDuration <= 6 * 3600,
                  (1...2048).contains(maximumFrameDimension),
                  (1...(3840 * 2160)).contains(maximumSourcePixels),
                  (1...(8 * 1024 * 1024)).contains(maximumEncodedFrameBytes),
                  (1...(128 * 1024 * 1024)).contains(maximumOutputBytes),
                  deadlineSeconds.isFinite, deadlineSeconds > 0, deadlineSeconds <= 1800 else { throw Failure.invalidLimits }
        }
    }
    struct Metadata {
        let duration: Double
        let hasVideo: Bool
        let hasAudio: Bool
        let contentSHA256: String
    }
    struct Frame {
        let jpeg: Data
        let requestedTimestamp: Double
        let actualTimestamp: Double
        let width: Int
        let height: Int
    }
    struct AudioWindow {
        let wav: Data
        let start: Double
        let end: Double
        let sampleCount: Int
    }
    let metadata: Metadata
    private let url: URL
    private let limits: Limits
    private let asset: AVURLAsset
    private let stamp: Stamp
    private let control: Control
    private var outputBytes = 0
    private var emittedFrames = 0
    private var emittedAudio = 0
    private struct Stamp: Equatable {
        let size: Int64
        let modified: Date
        let inode: UInt64
        static func read(_ url: URL, limit: Int64) throws -> Self {
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { throw Failure.invalidFile }
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                  let size = attrs[.size] as? NSNumber, size.int64Value > 0,
                  size.int64Value <= limit,
                  let date = attrs[.modificationDate] as? Date,
                  let inode = attrs[.systemFileNumber] as? NSNumber else { throw Failure.invalidFile }
            return Self(size: size.int64Value, modified: date, inode: inode.uint64Value)
        }
    }
    private final class Control: @unchecked Sendable {
        let lock = NSLock()
        var cancelled = false
        var busy = false
        var stop: (() -> Void)?
        let expires: Double
        var timer: DispatchSourceTimer?
        init(seconds: Double) {
            expires = ProcessInfo.processInfo.systemUptime + seconds
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            self.timer = timer
            timer.schedule(deadline: .now() + seconds)
            timer.setEventHandler { [weak self] in self?.cancel() }
            timer.resume()
        }
        deinit { timer?.cancel() }
        func cancel() {
            lock.lock(); cancelled = true; let action = stop; lock.unlock(); action?()
        }
        func check() throws {
            lock.lock(); let stopped = cancelled; lock.unlock()
            if stopped || Task.isCancelled || ProcessInfo.processInfo.systemUptime >= expires { cancel(); throw Failure.cancelled }
        }
        func begin() throws {
            try check()
            lock.lock(); defer { lock.unlock() }
            guard !busy else { throw Failure.busy }; busy = true
        }
        func install(_ action: @escaping () -> Void) {
            lock.lock(); stop = action; let stopped = cancelled; lock.unlock()
            if stopped { action() }
        }
        func finish() { lock.lock(); busy = false; stop = nil; lock.unlock() }
    }
    init(url: URL, limits: Limits = Limits()) async throws {
        try limits.validate()
        let stamp = try Stamp.read(url, limit: limits.maximumFileBytes)
        let control = Control(seconds: limits.deadlineSeconds)
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue),
            AVURLAssetShouldSupportAliasDataReferencesKey: false,
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])
        control.install { asset.cancelLoading() }
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var hash = SHA256(); var read: Int64 = 0
            while true {
                try control.check()
                let chunk = try file.read(upToCount: 1024 * 1024) ?? Data()
                if chunk.isEmpty { break }
                read += Int64(chunk.count)
                guard read <= stamp.size else { throw Failure.changedFile }
                hash.update(data: chunk)
            }
            guard read == stamp.size, try Stamp.read(url, limit: limits.maximumFileBytes) == stamp else { throw Failure.changedFile }
            let duration = try await withTaskCancellationHandler {
                try await asset.load(.duration).seconds
            } onCancel: { control.cancel() }
            let videos = try await withTaskCancellationHandler {
                try await asset.loadTracks(withMediaType: .video)
            } onCancel: { control.cancel() }
            let audios = try await withTaskCancellationHandler {
                try await asset.loadTracks(withMediaType: .audio)
            } onCancel: { control.cancel() }
            guard duration.isFinite, duration > 0, duration <= limits.maximumDuration,
                  !videos.isEmpty || !audios.isEmpty else { throw Failure.unsupported }
            if let video = videos.first {
                let size = try await video.load(.naturalSize)
                guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
                      size.width * size.height <= Double(limits.maximumSourcePixels) else { throw Failure.limitExceeded }
            }
            try control.check()
            self.url = url; self.limits = limits; self.stamp = stamp; self.asset = asset; self.control = control
            self.metadata = Metadata(duration: duration, hasVideo: !videos.isEmpty, hasAudio: !audios.isEmpty,
                contentSHA256: hash.finalize().map { String(format: "%02x", $0) }.joined())
            control.finish()
        } catch { control.cancel(); throw error }
    }
    func cancel() { control.cancel() }
    private func checkFile() throws {
        try control.check()
        guard try Stamp.read(url, limit: limits.maximumFileBytes) == stamp else { throw Failure.changedFile }
    }
    private func validate(_ plan: MediaSamplingPlan, audio: Bool) throws {
        guard plan.actualSegmentCount <= 120 else { throw Failure.invalidPlan }
        var previous = 0.0
        for window in plan.segments {
            guard window.start.isFinite, window.end.isFinite, window.start >= previous,
                  window.end > window.start, window.end <= metadata.duration,
                  window.duration <= (audio ? 30 : 3), window.frameTimestamps.count <= 3,
                  audio ? window.frameTimestamps.isEmpty : !window.frameTimestamps.isEmpty else { throw Failure.invalidPlan }
            var priorFrame = -1.0
            for time in window.frameTimestamps {
                guard time.isFinite, time >= window.start, time < window.end, time > priorFrame else { throw Failure.invalidPlan }
                priorFrame = time
            }
            previous = window.end
        }
    }
    private func account(_ count: Int) throws {
        guard count >= 0, count <= limits.maximumOutputBytes - outputBytes else { throw Failure.limitExceeded }
        outputBytes += count
    }
    func frames(plan: MediaSamplingPlan, onFrame: (Frame) async throws -> Void) async throws {
        try await withTaskCancellationHandler {
            try await extractFrames(plan: plan, onFrame: onFrame)
        } onCancel: { self.cancel() }
    }
    private func extractFrames(plan: MediaSamplingPlan, onFrame: (Frame) async throws -> Void) async throws {
        try control.begin(); defer { control.finish() }
        try validate(plan, audio: false); try checkFile()
        guard metadata.hasVideo else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: limits.maximumFrameDimension, height: limits.maximumFrameDimension)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        control.install { generator.cancelAllCGImageGeneration() }
        for window in plan.segments {
            for time in window.frameTimestamps {
                try checkFile()
                guard emittedFrames < 360 else { throw Failure.limitExceeded }
                let result = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 60000))
                try checkFile()
                let image = result.image
                let actual = result.actualTime.seconds
                guard actual.isFinite, actual >= 0, actual <= metadata.duration,
                      image.width <= limits.maximumFrameDimension, image.height <= limits.maximumFrameDimension else { throw Failure.limitExceeded }
                let bytes = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { throw Failure.unsupported }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
                guard CGImageDestinationFinalize(destination), bytes.length <= limits.maximumEncodedFrameBytes else { throw Failure.limitExceeded }
                let data = bytes as Data
                try account(data.count); emittedFrames += 1
                try checkFile()
                try await onFrame(Frame(jpeg: data, requestedTimestamp: time, actualTimestamp: actual, width: image.width, height: image.height))
            }
        }
    }
    func audio(plan: MediaSamplingPlan, onWindow: (AudioWindow) async throws -> Void) async throws {
        try await withTaskCancellationHandler {
            try await extractAudio(plan: plan, onWindow: onWindow)
        } onCancel: { self.cancel() }
    }
    private func extractAudio(plan: MediaSamplingPlan, onWindow: (AudioWindow) async throws -> Void) async throws {
        try control.begin(); defer { control.finish() }
        try validate(plan, audio: true); try checkFile()
        guard metadata.hasAudio else { return }
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw Failure.unsupported }
        // A MOV track.timeRange may include leading/trailing empty edits. Use its actual
        // nonempty target mappings; internal discontinuous audio still fails closed.
        let mappings = try await track.load(.segments)
        guard mappings.count <= 256 else { throw Failure.limitExceeded }
        let ranges = mappings.filter { !$0.isEmpty }.map { $0.timeMapping.target }
        guard let firstRange = ranges.first else { return }
        let trackStart = firstRange.start.seconds
        var trackEnd = trackStart
        for range in ranges {
            let start = range.start.seconds, end = range.end.seconds
            guard start.isFinite, end.isFinite, start >= 0, end > start,
                  end <= limits.maximumDuration, start == trackEnd else { throw Failure.unsupported }
            // AAC encoder padding can extend the track beyond the movie duration.
            // Requested windows are already bounded by that duration; intersect below
            // instead of rejecting an otherwise valid multiplexed file.
            trackEnd = end
        }
        for requested in plan.segments {
            try checkFile()
            let start = max(requested.start, trackStart), end = min(requested.end, trackEnd)
            guard end > start else { continue } // no audio track here: no fabricated silence/embedding
            let window = MediaSampleWindow(start: start, end: end, frameTimestamps: [])
            guard emittedAudio < 120 else { throw Failure.limitExceeded }
            let reader = try AVAssetReader(asset: asset)
            control.install { reader.cancelReading() }
            defer { reader.cancelReading() }
            reader.timeRange = CMTimeRange(start: CMTime(seconds: window.start, preferredTimescale: 16000),
                                          end: CMTime(seconds: window.end, preferredTimescale: 16000))
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw Failure.unsupported }
            reader.add(output)
            guard reader.startReading() else { throw Failure.unsupported }
            let maximumSamples = min(480000, Int((window.duration * 16000).rounded(.down)))
            var pcm = Data(); pcm.reserveCapacity(maximumSamples * 2)
            var firstSampleTick: Int64?
            while let sample = output.copyNextSampleBuffer() {
                try checkFile()
                defer { CMSampleBufferInvalidate(sample) }
                guard let format = CMSampleBufferGetFormatDescription(sample),
                      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                      asbd.mFormatID == kAudioFormatLinearPCM, asbd.mSampleRate == 16000,
                      asbd.mChannelsPerFrame == 1, asbd.mBitsPerChannel == 16,
                      let block = CMSampleBufferGetDataBuffer(sample) else { throw Failure.unsupported }
                let count = CMBlockBufferGetDataLength(block)
                guard count >= 0, count <= 960000, count % 2 == 0 else { throw Failure.limitExceeded }
                let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
                guard presentation.isNumeric, presentation.seconds.isFinite,
                      presentation.seconds >= -30, presentation.seconds <= limits.maximumDuration else { throw Failure.unsupported }
                // Integer output-sample ticks avoid losing a sample to floating subtraction.
                let pts = CMTimeConvertScale(presentation, timescale: 16000, method: .roundTowardPositiveInfinity).value
                let firstAllowed = Int64((window.start * 16000).rounded(.up))
                let lastAllowed = Int64((window.end * 16000).rounded(.down))
                guard pts >= -16000 * 30, pts <= Int64(limits.maximumDuration * 16000) else { throw Failure.unsupported }
                let samplesInBuffer = count / 2
                let skip = Int(min(Int64(samplesInBuffer), max(0, firstAllowed - pts)))
                let end = Int(min(Int64(samplesInBuffer), max(0, lastAllowed - pts)))
                let take = min(maximumSamples * 2 - pcm.count, max(0, end - skip) * 2)
                if take > 0 {
                    let start = pts + Int64(skip)
                    guard start >= firstAllowed, start < lastAllowed else { throw Failure.unsupported }
                    if let first = firstSampleTick {
                        guard start == first + Int64(pcm.count / 2) else { throw Failure.unsupported }
                    } else { firstSampleTick = start }
                    var bytes = Data(count: take)
                    let status = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: skip * 2, dataLength: take, destination: $0.baseAddress!) }
                    guard status == kCMBlockBufferNoErr else { throw Failure.unsupported }
                    pcm.append(bytes)
                }
                if pcm.count == maximumSamples * 2 { reader.cancelReading(); break }
            }
            guard reader.status == .completed || (reader.status == .cancelled && pcm.count == maximumSamples * 2),
                  !pcm.isEmpty, let actualFirstTick = firstSampleTick else { throw Failure.unsupported }
            let actualStart = Double(actualFirstTick) / 16000
            let wav = Self.wav(pcm)
            try account(wav.count); emittedAudio += 1; try checkFile()
            try await onWindow(AudioWindow(wav: wav, start: actualStart,
                end: min(window.end, actualStart + Double(pcm.count / 2) / 16000), sampleCount: pcm.count / 2))
        }
    }
    private static func wav(_ pcm: Data) -> Data {
        var out = Data("RIFF".utf8)
        func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { out.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { out.append(contentsOf: $0) } }
        u32(UInt32(pcm.count + 36)); out.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(16000); u32(32000); u16(2); u16(16); out.append(Data("data".utf8)); u32(UInt32(pcm.count)); out.append(pcm)
        return out
    }
}
