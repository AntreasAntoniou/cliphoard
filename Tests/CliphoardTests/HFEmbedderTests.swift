import XCTest
import CoreML
import Tokenizers
@testable import Cliphoard

/// End-to-end parity of the High/Max tier pipelines (swift-transformers
/// tokenizer + converted CoreML model) against PyTorch reference goldens
/// (generated alongside tools/convert_minilm.py / convert_gemma.py). Skips when
/// the model isn't restored (tools/restore-models.sh).
final class HFEmbedderParityTests: XCTestCase {
    private func modelsDir() -> URL {
        if let d = ProcessInfo.processInfo.environment["CLIPHOARD_OGMA_MODEL_DIR"], !d.isEmpty {
            return URL(fileURLWithPath: d)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools/models")
    }

    private func load(name: String) async throws -> (MLModel, Tokenizer)? {
        let dir = modelsDir()
        let pkg = dir.appendingPathComponent("\(name).mlpackage")
        let tokDir = dir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: pkg.path),
              FileManager.default.fileExists(atPath: tokDir.appendingPathComponent("tokenizer.json").path)
        else { return nil }
        let compiled = try await MLModel.compileModel(at: pkg)
        let model = try MLModel(contentsOf: compiled)
        let tokenizer = try await AutoTokenizer.from(modelFolder: tokDir)
        return (model, tokenizer)
    }

    func testMiniLMMatchesPyTorchGoldens() async throws {
        guard let (model, tokenizer) = try await load(name: "all-MiniLM-L6-v2") else {
            throw XCTSkip("all-MiniLM-L6-v2 not present — restore via tools/restore-models.sh")
        }
        // Goldens from the ST reference (fp32 PyTorch, tools env).
        let goldenIds: [Int] = [101, 1996, 4248, 2829, 4419, 102]
        let goldenHead: [Float] = [0.00277, 0.03327, -0.00068, 0.043, 0.03615, -0.03334]

        let ids = tokenizer.encode(text: "the quick brown fox")
        XCTAssertEqual(ids, goldenIds, "WordPiece ids diverged from the HF reference")

        let embedder = HFEmbedder(modelName: "all-MiniLM-L6-v2", model: model,
                                  tokenizer: tokenizer, dimension: 384)
        let v = embedder.embed("the quick brown fox")
        XCTAssertEqual(v.count, 384)
        for (i, g) in goldenHead.enumerated() {
            XCTAssertEqual(v[i], g, accuracy: 2e-3, "component \(i) parity mismatch")
        }
        let norm = (v.reduce(0) { $0 + $1 * $1 }).squareRoot()
        XCTAssertEqual(norm, 1, accuracy: 0.01, "output must be L2-normalised")
    }

    func testGemmaMatchesPyTorchGoldens() async throws {
        guard let (model, tokenizer) = try await load(name: "embeddinggemma-300m") else {
            throw XCTSkip("embeddinggemma-300m not present — restore via tools/restore-models.sh")
        }
        // Doc-prompt goldens from the ST reference (encode_document).
        let goldenHead: [Float] = [-0.09701, 0.03663, 0.04911, -0.0391, -0.05679, 0.00286]
        let embedder = HFEmbedder(modelName: "embeddinggemma-300m", model: model,
                                  tokenizer: tokenizer, dimension: 768,
                                  queryPrefix: DeepSearchLevel.max.queryPrefix,
                                  docPrefix: DeepSearchLevel.max.docPrefix)
        let v = embedder.embed("the quick brown fox")   // doc path applies the doc prompt
        XCTAssertEqual(v.count, 768)
        // 8-bit palettized weights: slightly looser per-component tolerance.
        for (i, g) in goldenHead.enumerated() {
            XCTAssertEqual(v[i], g, accuracy: 8e-3, "component \(i) parity mismatch")
        }
    }
}

/// Tier wiring for the new levels.
final class HFTierTests: XCTestCase {
    func testTierModelMapping() {
        XCTAssertEqual(DeepSearchLevel.high.modelName, "all-MiniLM-L6-v2")
        XCTAssertEqual(DeepSearchLevel.high.dimension, 384)
        XCTAssertFalse(DeepSearchLevel.high.isOgma)
        XCTAssertEqual(DeepSearchLevel.max.modelName, "embeddinggemma-300m")
        XCTAssertEqual(DeepSearchLevel.max.dimension, 768)
        XCTAssertFalse(DeepSearchLevel.max.isOgma)
        XCTAssertTrue(DeepSearchLevel.normal.isOgma)
    }

    func testGemmaPromptsAndSymmetricMiniLM() {
        XCTAssertEqual(DeepSearchLevel.max.queryPrefix, "task: search result | query: ")
        XCTAssertEqual(DeepSearchLevel.max.docPrefix, "title: none | text: ")
        XCTAssertEqual(DeepSearchLevel.high.queryPrefix, "")
        XCTAssertEqual(DeepSearchLevel.high.docPrefix, "")
    }

    func testCalibratedFloors() {
        XCTAssertEqual(DeepSearchLevel.high.hfRelevanceFloor, 0.20, accuracy: 0.001)
        XCTAssertEqual(DeepSearchLevel.max.hfRelevanceFloor, 0.30, accuracy: 0.001)
    }
}
