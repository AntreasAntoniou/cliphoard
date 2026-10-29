import XCTest
@testable import Cliphoard

final class MediaSpeechTranscriberTests: XCTestCase {
    actor Fake: MediaSpeechBackend {
        var preparations: [Bool] = []
        var calls = 0
        var output: [MediaSpeechSegment] = [.init(start: 0, end: 0.5, text: " spoken words ")]
        var suspend = false
        var continuation: CheckedContinuation<Void, Never>?
        var started: CheckedContinuation<Void, Never>?
        func prepare(model: MediaSpeechModel, root: URL, allowDownload: Bool, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
            preparations.append(allowDownload)
        }
        func transcribe(samples: [Float], language: String?, shouldContinue: @escaping @Sendable () -> Bool) async throws -> [MediaSpeechSegment] {
            calls += 1
            started?.resume(); started = nil
            if suspend { await withCheckedContinuation { continuation = $0 } }
            guard shouldContinue() else { throw CancellationError() }
            return output
        }
        func unload() async {}
        func configure(_ output: [MediaSpeechSegment]) { self.output = output }
        func pause() { suspend = true }
        func waitUntilStarted() async {
            if calls == 0 { await withCheckedContinuation { started = $0 } }
        }
        func resume() { continuation?.resume(); continuation = nil }
    }
    func subject(_ backend: Fake) -> MediaSpeechTranscriber {
        MediaSpeechTranscriber(modelsRoot: URL(fileURLWithPath: "/unused-speech-tests"), backend: backend)
    }
    static func wav(_ samples: [Int16]) -> Data {
        var d = Data("RIFF".utf8)
        func u32(_ n: UInt32) { var x = n.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ n: UInt16) { var x = n.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        u32(UInt32(36 + samples.count * 2)); d.append(Data("WAVEfmt ".utf8)); u32(16)
        u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(UInt32(samples.count * 2))
        for s in samples { u16(UInt16(bitPattern: s)) }; return d
    }
    func testExplicitPreparationAndTimestampMapping() async throws {
        XCTAssertEqual(MediaSpeechModel.defaultModel, .turbo)
        let b = Fake(), s = subject(b)
        let wav = Self.wav(Array(repeating: 120, count: 16000))
        do { _ = try await s.transcribe(wav: wav, start: 12, end: 13); XCTFail() }
        catch { XCTAssertEqual(error as? MediaSpeechTranscriber.Failure, .notPrepared) }
        let count = await b.calls; XCTAssertEqual(count, 0)
        try await s.prepare(model: .turbo)
        let flags = await b.preparations; XCTAssertEqual(flags, [false])
        let output = try await s.transcribe(wav: wav, start: 12, end: 13)
        XCTAssertEqual(output, [.init(start: 12, end: 12.5, text: "spoken words")])
    }
    func testWAVContractRejectsMalformedOversizedAndMismatchedAudio() throws {
        let valid = Self.wav([-32768, 0, 32767])
        XCTAssertEqual(try MediaSpeechTranscriber.samples(from: valid), [-1, 0, Float(32767) / 32768])
        for offset in [0, 4, 8, 12, 16, 20, 22, 24, 28, 32, 34, 36, 40] {
            var corrupt = valid; corrupt[offset] ^= 0x80
            XCTAssertThrowsError(try MediaSpeechTranscriber.samples(from: corrupt))
        }
        XCTAssertThrowsError(try MediaSpeechTranscriber.samples(from: Self.wav([])))
        XCTAssertThrowsError(try MediaSpeechTranscriber.samples(from: Self.wav(Array(repeating: 0, count: 480001))))
        var trailing = valid; trailing.append(0); XCTAssertThrowsError(try MediaSpeechTranscriber.samples(from: trailing))
    }
    func testInvalidInputAndBackendOutputFailClosed() async throws {
        let b = Fake(), s = subject(b); try await s.prepare()
        let wav = Self.wav(Array(repeating: 0, count: 16000))
        for (start, end) in [(Double.nan, 1.0), (-1, 0), (0, Double.infinity), (1, 1), (0, 2)] {
            do { _ = try await s.transcribe(wav: wav, start: start, end: end); XCTFail() } catch {}
        }
        for segment in [MediaSpeechSegment(start: -.infinity, end: 1, text: "bad"),
                        .init(start: 0, end: 100, text: "bad"),
                        .init(start: 0, end: 1, text: String(repeating: "x", count: 32769))] {
            await b.configure([segment])
            do { _ = try await s.transcribe(wav: wav, start: 0, end: 1); XCTFail() } catch {}
        }
    }
    func testCancellationAndSingleFlightDiscardSuspendedResult() async throws {
        let b = Fake(), s = subject(b); try await s.prepare(); await b.pause()
        let wav = Self.wav(Array(repeating: 0, count: 16000))
        let task = Task { try await s.transcribe(wav: wav, start: 0, end: 1) }
        await b.waitUntilStarted()
        let calls = await b.calls; XCTAssertEqual(calls, 1)
        do { try await s.prepare(); XCTFail() }
        catch { XCTAssertEqual(error as? MediaSpeechTranscriber.Failure, .busy) }
        await s.cancel(); await b.resume()
        do { _ = try await task.value; XCTFail() } catch {}
    }
    func testFullSpeechPlanIsContinuousAndRejectsLongerFiles() throws {
        for duration in [0.01, 29.999, 30, 30.001, 60, 3599.9, 3600] {
            let p = try MediaSpeechTranscriber.fullTranscriptionPlan(duration: duration)
            XCTAssertLessThanOrEqual(p.segments.count, 120)
            XCTAssertEqual(p.segments.first?.start, 0)
            XCTAssertEqual(p.segments.last?.end, duration)
            for (a,b) in zip(p.segments, p.segments.dropFirst()) { XCTAssertEqual(a.end, b.start) }
        }
        for duration in [0, -1, Double.nan, .infinity, 3600.1] {
            XCTAssertThrowsError(try MediaSpeechTranscriber.fullTranscriptionPlan(duration: duration))
        }
    }
}
