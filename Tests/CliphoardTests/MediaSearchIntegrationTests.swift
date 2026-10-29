import XCTest
@testable import Cliphoard

final class MediaSearchIntegrationTests: XCTestCase {
    func testMediaSelectionRequiresProAndOpensExistingUpsell() {
        XCTAssertFalse(SearchMode.available(.free(reason: nil)).contains(.media))
        XCTAssertTrue(GuidedSetupDraft.presentsPro(for: .media, entitlement: .free(reason: nil)))
        XCTAssertTrue(SearchMode.available(.pro(orderID: "public-test-only", issued: Date(timeIntervalSince1970: 0))).contains(.media))
    }
    func testUTF8PassagesRetainTextWithoutExceedingRuntimeLimit() async {
        await MainActor.run {
            let text = String(repeating: "🎬 café Ελληνικά ", count: 200)
            let chunks = MediaSearchController.textChunks(text)
            XCTAssertEqual(chunks.joined(), text)
            XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.utf8.count <= 1000 })
        }
    }
    @MainActor private func entry() -> MediaSearchController.Entry {
        var vector = Array(repeating: Float(0), count: 768); vector[0] = 1
        return .init(clipID: UUID(), fingerprint: "fixture", bookmark: Data([1]), path: "/tmp/public-fixture.mov", modified: Date(timeIntervalSince1970: 0), size: 100, stillImage: false, preset: "balanced", speech: "off", speechModel: "turbo",
            record: .init(identity: .init(contentSHA256: String(repeating: "a", count: 64), modelRevision: GemmaMediaAssets.signature, preprocessingRevision: "jpeg1024-pcm16mono16k-v1", samplingRevision: "v1-balanced"), duration: 30,
                vectors: [.init(modality: .video, start: 1, end: 1, vector: vector)]), passages: [])
    }
    func testCacheRejectsStaleModelPreprocessingAndMalformedTimeline() async throws {
        try await MainActor.run {
            let original = entry()
            XCTAssertNoThrow(try MediaSearchController.validate(original))
            var changed = original; changed.record.identity.modelRevision = "other-model"
            XCTAssertThrowsError(try MediaSearchController.validate(changed))
            changed = original; changed.record.identity.preprocessingRevision = "different-audio-rate"
            XCTAssertThrowsError(try MediaSearchController.validate(changed))
            changed = original; changed.record.vectors[0].start = .nan
            XCTAssertThrowsError(try MediaSearchController.validate(changed))
            changed = original; changed.record.vectors[0].vector[0] = 100
            XCTAssertThrowsError(try MediaSearchController.validate(changed))
            changed = original; changed.record.identity.samplingRevision = "v1-detailed"
            XCTAssertThrowsError(try MediaSearchController.validate(changed))
        }
    }
    func testTranscriptEnvelopeEnforcesBoundsAndSensitiveTextPolicy() async throws {
        try await MainActor.run {
            var value = entry()
            value.passages = [.init(start: 0, end: 31, text: "public sample", vector: value.record.vectors[0].vector)]
            XCTAssertThrowsError(try MediaSearchController.validate(value))
            value.passages[0].end = 2
            XCTAssertNoThrow(try MediaSearchController.validate(value))
            value.passages[0].text = String(repeating: "a", count: 1001)
            XCTAssertThrowsError(try MediaSearchController.validate(value))
        }
    }
    func testMissingSuffixBelowSymlinkIsRefusedBeforeCreation() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        try await MainActor.run {
            XCTAssertThrowsError(try MediaSearchController.checkAncestors(alias.appendingPathComponent("missing/child")))
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("missing").path))
        }
    }
    func testImageReadBoundsActualBytes() async throws {
        let file = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try Data(repeating: 0, count: GemmaMediaEmbedder.maximumImageBytes + 1).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await MainActor.run { XCTAssertThrowsError(try MediaSearchController.boundedImage(file)) }
    }
}
