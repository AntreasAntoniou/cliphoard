import XCTest
import AVFoundation
@testable import Cliphoard

final class MediaAssetDecoderTests: XCTestCase {
    private func fixtureDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("media-decoder-public-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    private func wavFixture(_ folder: URL, seconds: Int = 2) throws -> URL {
        var data = Data("RIFF".utf8)
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        let count = seconds * 16000
        u32(UInt32(count * 2 + 36)); data.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(16000); u32(32000); u16(2); u16(16); data.append(Data("data".utf8)); u32(UInt32(count * 2))
        for i in 0..<count { u16(UInt16(bitPattern: Int16(sin(Double(i) * 2 * .pi * 440 / 16000) * 1000))) }
        let url = folder.appendingPathComponent("public-tone.wav"); try data.write(to: url); return url
    }
    private func videoFixture(_ folder: URL) async throws -> URL {
        let url = folder.appendingPathComponent("public-colors.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for frame in 0..<20 {
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32ARGB, nil, &buffer), kCVReturnSuccess)
            let pixel = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            memset(CVPixelBufferGetBaseAddress(pixel), Int32(frame * 10), CVPixelBufferGetBytesPerRow(pixel) * 48)
            CVPixelBufferUnlockBaseAddress(pixel, [])
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertTrue(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
        }
        input.markAsFinished(); await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed); return url
    }
    func testAACPaddingBeyondMovieDurationIsClippedNotRejected() async throws {
        // Synthetic teal video + macOS speech, muxed by FFmpeg: movie4.1s,
        // AAC track4.161s. No user media and no network access.
        let url = try XCTUnwrap(Bundle.module.url(forResource: "aac-padding", withExtension: "mp4", subdirectory: "Fixtures"))
        let decoder = try await MediaAssetDecoder(url: url)
        let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)[0]
        let mappings = try await track.load(.segments)
        XCTAssertGreaterThan(try XCTUnwrap(mappings.last).timeMapping.target.end.seconds, decoder.metadata.duration)
        var seen = 0
        try await decoder.audio(plan: MediaSamplingPlan.make(duration: decoder.metadata.duration, preset: .lightweight, modality: .audio)) { window in
            seen += 1
            XCTAssertGreaterThan(window.sampleCount, 0)
            XCTAssertLessThanOrEqual(window.end, decoder.metadata.duration)
        }
        XCTAssertGreaterThan(seen, 0)
    }
    func testActualAudioExtractionWAVAndNoVideo() async throws {
        let folder = try fixtureDirectory(); let url = try wavFixture(folder)
        let decoder = try await MediaAssetDecoder(url: url)
        XCTAssertTrue(decoder.metadata.hasAudio); XCTAssertFalse(decoder.metadata.hasVideo)
        XCTAssertEqual(decoder.metadata.contentSHA256.count, 64)
        let plan = try MediaSamplingPlan.make(duration: decoder.metadata.duration, preset: .balanced, modality: .audio)
        var outputs: [MediaAssetDecoder.AudioWindow] = []
        try await decoder.audio(plan: plan) { outputs.append($0) }
        XCTAssertEqual(outputs.count, 1)
        let audio = try XCTUnwrap(outputs.first)
        XCTAssertEqual(String(data: audio.wav.prefix(4), encoding: .utf8), "RIFF")
        XCTAssertEqual(String(data: audio.wav[8..<12], encoding: .utf8), "WAVE")
        XCTAssertEqual(audio.wav.count, 44 + audio.sampleCount * 2)
        XCTAssertEqual(audio.sampleCount, 32000)
        XCTAssertEqual(audio.start, 0); XCTAssertEqual(audio.end, 2)
        var frames = 0
        let videoPlan = try MediaSamplingPlan.make(duration: 2, preset: .balanced, modality: .video)
        try await decoder.frames(plan: videoPlan) { _ in frames += 1 }
        XCTAssertEqual(frames, 0)
    }
    func testActualVideoFramesBoundedAndAbsentAudio() async throws {
        let folder = try fixtureDirectory(); let url = try await videoFixture(folder)
        var limits = MediaAssetDecoder.Limits(); limits.maximumFrameDimension = 32
        let decoder = try await MediaAssetDecoder(url: url, limits: limits)
        XCTAssertTrue(decoder.metadata.hasVideo); XCTAssertFalse(decoder.metadata.hasAudio)
        let plan = try MediaSamplingPlan.make(duration: decoder.metadata.duration, preset: .balanced, modality: .video)
        var count = 0
        try await decoder.frames(plan: plan) { frame in
            count += 1
            XCTAssertLessThanOrEqual(frame.width, 32); XCTAssertLessThanOrEqual(frame.height, 32)
            XCTAssertEqual(Array(frame.jpeg.prefix(2)), [0xff, 0xd8])
            XCTAssertGreaterThanOrEqual(frame.actualTimestamp, 0)
            XCTAssertLessThanOrEqual(frame.actualTimestamp, decoder.metadata.duration)
        }
        XCTAssertEqual(count, 3)
        var audio = 0
        try await decoder.audio(plan: MediaSamplingPlan.make(duration: decoder.metadata.duration, preset: .balanced, modality: .audio)) { _ in audio += 1 }
        XCTAssertEqual(audio, 0)
    }
    func testCancellationAndOutputLimitPreventCallbacks() async throws {
        let folder = try fixtureDirectory(); let url = try wavFixture(folder)
        let decoder = try await MediaAssetDecoder(url: url)
        decoder.cancel()
        let plan = try MediaSamplingPlan.make(duration: 2, preset: .balanced, modality: .audio)
        do { try await decoder.audio(plan: plan) { _ in XCTFail("cancelled callback") }; XCTFail("accepted cancel") }
        catch { XCTAssertEqual(error as? MediaAssetDecoder.Failure, .cancelled) }
        var limits = MediaAssetDecoder.Limits(); limits.maximumOutputBytes = 100
        let bounded = try await MediaAssetDecoder(url: url, limits: limits)
        do { try await bounded.audio(plan: plan) { _ in XCTFail("over budget callback") }; XCTFail("accepted excess") }
        catch { XCTAssertEqual(error as? MediaAssetDecoder.Failure, .limitExceeded) }
    }
    func testFileMutationAndCorruptionRefused() async throws {
        let folder = try fixtureDirectory(); let url = try wavFixture(folder)
        let decoder = try await MediaAssetDecoder(url: url)
        try Data("broken public fixture".utf8).write(to: url)
        do { try await decoder.audio(plan: MediaSamplingPlan.make(duration: 2, preset: .balanced, modality: .audio)) { _ in XCTFail("changed file") }; XCTFail("accepted change") }
        catch { XCTAssertEqual(error as? MediaAssetDecoder.Failure, .changedFile) }
        do { _ = try await MediaAssetDecoder(url: url); XCTFail("corrupt media accepted") } catch { }
    }
    func testApprovedLongSessionCeilingsAndStrictExcessRejection() async throws {
        let folder = try fixtureDirectory(); let url = try wavFixture(folder)
        var limits = MediaAssetDecoder.Limits()
        limits.deadlineSeconds = 1800; limits.maximumOutputBytes = 128 * 1024 * 1024
        let decoder = try await MediaAssetDecoder(url: url, limits: limits)
        decoder.cancel()
        limits.deadlineSeconds = 1800.0001
        do { _ = try await MediaAssetDecoder(url: url, limits: limits); XCTFail("deadline expanded") }
        catch { XCTAssertEqual(error as? MediaAssetDecoder.Failure, .invalidLimits) }
        limits.deadlineSeconds = 120; limits.maximumOutputBytes = 128 * 1024 * 1024 + 1
        do { _ = try await MediaAssetDecoder(url: url, limits: limits); XCTFail("output expanded") }
        catch { XCTAssertEqual(error as? MediaAssetDecoder.Failure, .invalidLimits) }
    }
    func testActualAudioFromMuxedVideo() async throws {
        let folder = try fixtureDirectory()
        let video = AVURLAsset(url: try await videoFixture(folder))
        let audio = AVURLAsset(url: try wavFixture(folder))
        let composition = AVMutableComposition()
        let vt = try await video.loadTracks(withMediaType: .video)[0]
        let at = try await audio.loadTracks(withMediaType: .audio)[0]
        let span = CMTimeRange(start: .zero, duration: CMTime(seconds: 1.8, preferredTimescale: 16000))
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(span, of: vt, at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(span, of: at, at: .zero)
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
        let url = folder.appendingPathComponent("public-muxed.mov")
        exporter.outputURL = url; exporter.outputFileType = .mov
        await exporter.export(); XCTAssertEqual(exporter.status, .completed)
        let decoder = try await MediaAssetDecoder(url: url)
        XCTAssertTrue(decoder.metadata.hasVideo); XCTAssertTrue(decoder.metadata.hasAudio)
        var seen = 0
        try await decoder.audio(plan: MediaSamplingPlan.make(duration: decoder.metadata.duration, preset: .balanced, modality: .audio)) { window in
            seen += 1; XCTAssertGreaterThan(window.sampleCount, 20000)
            XCTAssertLessThanOrEqual(window.end, decoder.metadata.duration)
            XCTAssertEqual(window.wav.count, window.sampleCount * 2 + 44)
        }
        XCTAssertEqual(seen, 1)
    }
    func testTaskCancellationDuringCallbackStopsNextDelivery() async throws {
        let folder = try fixtureDirectory(); let url = try await videoFixture(folder)
        let decoder = try await MediaAssetDecoder(url: url)
        let plan = try MediaSamplingPlan.make(duration: decoder.metadata.duration, preset: .balanced, modality: .video)
        let started = expectation(description: "first public frame")
        let task = Task {
            try await decoder.frames(plan: plan) { _ in
                started.fulfill()
                try await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        do { try await task.value; XCTFail("cancelled task succeeded") } catch { }
        do { try await decoder.frames(plan: plan) { _ in XCTFail("session not cancelled") }; XCTFail("reuse accepted") }
        catch { XCTAssertEqual(error as? MediaAssetDecoder.Failure, .cancelled) }
    }
    func testSeparatedAudioWindowsRetainActualTimestamps() async throws {
        let folder = try fixtureDirectory(); let url = try wavFixture(folder, seconds: 62)
        let decoder = try await MediaAssetDecoder(url: url)
        let plan = try MediaSamplingPlan.make(duration: 62, preset: .balanced, modality: .audio)
        var windows: [MediaAssetDecoder.AudioWindow] = []
        try await decoder.audio(plan: plan) { windows.append($0) }
        XCTAssertEqual(windows.count, 3)
        for (window, expected) in zip(windows, plan.segments) {
            XCTAssertGreaterThanOrEqual(window.start, expected.start)
            XCTAssertEqual(window.start, expected.start, accuracy: 1.0 / 16000)
            XCTAssertLessThanOrEqual(window.end, expected.end)
            XCTAssertEqual(window.end - window.start, Double(window.sampleCount) / 16000, accuracy: 1.0 / 16000)
        }
    }
    func testPartialAudioTrackSkipsAbsentWindowAndClipsFullTraversal() async throws {
        let folder = try fixtureDirectory()
        let video = AVURLAsset(url: try await videoFixture(folder))
        let audio = AVURLAsset(url: try wavFixture(folder))
        let vt = try await video.loadTracks(withMediaType: .video)[0]
        let at = try await audio.loadTracks(withMediaType: .audio)[0]
        let composition = AVMutableComposition()
        let videoTrack = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let two = CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 16000))
        try videoTrack.insertTimeRange(two, of: vt, at: .zero)
        try videoTrack.insertTimeRange(two, of: vt, at: CMTime(seconds: 2, preferredTimescale: 16000))
        let audioTrack = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 16000)), of: at, at: CMTime(seconds: 3, preferredTimescale: 16000))
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        let url = folder.appendingPathComponent("public-partial-audio.mov")
        exporter.outputURL = url; exporter.outputFileType = .mov
        await exporter.export(); XCTAssertEqual(exporter.status, .completed)
        let observed = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)[0]
        let observedRange = try await observed.load(.timeRange)
        print("PUBLIC_PARTIAL_RANGE", observedRange.start.seconds, observedRange.end.seconds)
        for segment in try await observed.load(.segments) {
            print("PUBLIC_PARTIAL_SEGMENT", segment.isEmpty, segment.timeMapping.target.start.seconds, segment.timeMapping.target.end.seconds)
        }
        let decoder = try await MediaAssetDecoder(url: url)
        XCTAssertEqual(decoder.metadata.duration, 4, accuracy: 0.01)
        var absent = 0
        try await decoder.audio(plan: MediaSamplingPlan.make(duration: 0.5, preset: .detailed, modality: .audio)) { _ in absent += 1 }
        XCTAssertEqual(absent, 0)
        var audioWindows: [MediaAssetDecoder.AudioWindow] = []
        try await decoder.audio(plan: MediaSamplingPlan.make(duration: 4, preset: .detailed, modality: .audio)) { audioWindows.append($0) }
        XCTAssertEqual(audioWindows.count, 1)
        let window = try XCTUnwrap(audioWindows.first)
        XCTAssertEqual(window.start, 3, accuracy: 1.0 / 16000)
        XCTAssertEqual(window.end, 4, accuracy: 1.0 / 16000)
        XCTAssertEqual(window.sampleCount, 16000)
        var frames = 0
        try await decoder.frames(plan: MediaSamplingPlan.make(duration: 4, preset: .balanced, modality: .video)) { _ in frames += 1 }
        XCTAssertEqual(frames, 3)
    }
    func testRemoteURLRejectedBeforeLoading() async {
        do {
            _ = try await MediaAssetDecoder(url: URL(string: "https://example.invalid/private.mov")!)
            XCTFail("remote URL accepted")
        } catch { XCTAssertEqual(error as? MediaAssetDecoder.Failure, .invalidFile) }
    }
    func testInvalidLimitsRejectedBeforeFileAccess() async {
        var limits = MediaAssetDecoder.Limits()
        limits.maximumDuration = .nan
        do {
            _ = try await MediaAssetDecoder(url: URL(fileURLWithPath: "/nonexistent"), limits: limits)
            XCTFail("invalid limits accepted")
        } catch { XCTAssertEqual(error as? MediaAssetDecoder.Failure, .invalidLimits) }
    }
}
