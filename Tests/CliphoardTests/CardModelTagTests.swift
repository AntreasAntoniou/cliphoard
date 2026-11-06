import XCTest
import CoreML
import Tokenizers
@testable import Cliphoard

@MainActor
final class CardModelTagTests: XCTestCase {
    private struct Basis: TextEmbedder {
        let signature: String
        let names: [String]
        var dimension: Int { 384 }
        var relevanceFloor: Float { 0.20 }
        func embed(_ text: String) -> [Float] {
            var v = [Float](repeating: 0, count: dimension)
            v[names.firstIndex(of: text) ?? 383] = 1
            return v
        }
    }
    private func developerFixture() -> (ClipItem, Basis) {
        let item = ClipItem(kind: .text, text: "python")
        let model = Basis(signature: "card-tag-test-minilm-384-v1", names: TagSpace.names)
        item.embeddings[model.signature] = ModelEmbedding(vector: model.embed("python"))
        return (item, model)
    }
    private func withDeveloper(_ body: () throws -> Void) rethrows {
        let active = TagBaskets.activeID, overlays = TagBaskets.overlayIDs
        let threshold = TagSpace.assignmentThreshold
        defer { TagBaskets.activeID = active; TagBaskets.overlayIDs = overlays; TagSpace.assignmentThreshold = threshold }
        TagBaskets.activeID = "general"; TagBaskets.overlayIDs = ["dev"]
        TagSpace.assignmentThreshold = 0.28
        try body()
    }
    func testCurrentModelTagReachesCardAndOldModelOrBasketDoesNot() throws {
        withDeveloper {
            let (item, model) = developerFixture()
            let labels = ClipCardTags.modelLabels(for: item, embedder: model)
            XCTAssertEqual(labels, ["python"])
            XCTAssertEqual(ClipCardTags.row(for: item, modelTags: labels).shown.first, .model("python"))
            let other = Basis(signature: "different-model", names: model.names)
            XCTAssertTrue(ClipCardTags.modelLabels(for: item, embedder: other).isEmpty)
            TagBaskets.overlayIDs = []
            XCTAssertTrue(ClipCardTags.modelLabels(for: item, embedder: model).isEmpty)
        }
    }
    func testProtectionVetoAndWarningsTakePriorityOverModelTags() throws {
        withDeveloper {
            let (item, model) = developerFixture()
            item.flags = [.secret]
            XCTAssertTrue(ClipCardTags.modelLabels(for: item, embedder: model).isEmpty)
            let protected = ClipCardTags.row(for: item, modelTags: ["python", "code"])
            XCTAssertEqual(protected.shown.first, .signal(.flag(.secret)))
            XCTAssertFalse(protected.shown.contains(.model("python")))
            item.flags = [.pii]
            let warned = ClipCardTags.row(for: item, modelTags: ["python", "code", "python"])
            XCTAssertEqual(warned.shown.first, .signal(.flag(.pii)))
            XCTAssertLessThanOrEqual(warned.shown.count + (warned.overflow > 0 ? 1 : 0), 3)
        }
    }
    func testMatchingChoicesRetainAllFreeTextSearchModes() {
        XCTAssertEqual(SearchControlLabels.matchingModes, [.exact, .tag, .neural, .smart])
        for mode in SearchControlLabels.matchingModes { XCTAssertTrue(SearchMode.available(.free(reason: nil)).contains(mode)) }
    }
    func testInstalledMiniLMProducesVisibleDeveloperTag() async throws {
        guard let path = ProcessInfo.processInfo.environment["CLIPHOARD_TEST_MINILM_PREPARED"] else {
            throw XCTSkip("Requires an explicit existing MiniLM model directory; no download")
        }
        let root = URL(fileURLWithPath: path)
        let model = try await MLModel.load(contentsOf: root.appendingPathComponent("all-MiniLM-L6-v2.mlmodelc"), configuration: MLModelConfiguration())
        let tokenizer = try await AutoTokenizer.from(modelFolder: root.appendingPathComponent("all-MiniLM-L6-v2-tokenizer"))
        let backend = HFEmbedder(modelName: "all-MiniLM-L6-v2", model: model, tokenizer: tokenizer, dimension: 384)
        let fox = backend.embed("the quick brown fox")
        XCTAssertEqual(fox.count, 384)
        let golden: [Float] = [0.00277, 0.03327, -0.00068, 0.043, 0.03615, -0.03334]
        for (i, v) in golden.enumerated() { XCTAssertEqual(fox[i], v, accuracy: 0.002) }
        withDeveloper {
            let item = ClipItem(kind: .text, text: "python")
            item.embeddings[backend.signature] = ModelEmbedding(vector: backend.embed(item.text))
            let labels = ClipCardTags.modelLabels(for: item, embedder: backend)
            XCTAssertTrue(labels.contains("python"))
            XCTAssertTrue(ClipCardTags.row(for: item, modelTags: labels).shown.contains(.model("python")))
            print("MINILM synthetic python card labels=\(labels)")
        }
    }
}
