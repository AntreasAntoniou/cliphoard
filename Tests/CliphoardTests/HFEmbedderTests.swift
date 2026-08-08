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

}

/// Tier wiring. The EmbeddingGemma parity + prompt tests were removed with the
/// `max` tier itself (see THIRD-PARTY-NOTICES.md) — they exercised a model this
/// project no longer ships or redistributes.
final class HFTierTests: XCTestCase {
    func testTierModelMapping() {
        XCTAssertEqual(DeepSearchLevel.high.modelName, "all-MiniLM-L6-v2")
        XCTAssertEqual(DeepSearchLevel.high.dimension, 384)
        XCTAssertFalse(DeepSearchLevel.high.isOgma)
        XCTAssertTrue(DeepSearchLevel.normal.isOgma)
    }

    /// Every shipped tier is permissively licensed. This is an assertion about the
    /// DISTRIBUTED ARTIFACT, not about search quality: re-adding a tier whose model
    /// carries use restrictions should fail the build, not pass review silently.
    func testEveryShippedTierIsPermissivelyLicensed() {
        let permitted: Set<String> = ["open-ogma-micro", "open-ogma-small", "all-MiniLM-L6-v2"]
        for level in DeepSearchLevel.allCases {
            guard let name = level.modelName else { continue }
            XCTAssertTrue(permitted.contains(name),
                          "tier \(level.rawValue) ships \(name), which is not on the "
                          + "permissive-licence allowlist — update THIRD-PARTY-NOTICES.md "
                          + "and this test deliberately, or drop the tier")
        }
        XCTAssertNil(DeepSearchLevel(rawValue: "max"), "the Gemma-licensed tier must stay retired")
    }

    /// Someone who deliberately chose the largest model lands on the next-largest,
    /// not on the `?? .normal` fallback two tiers down.
    func testRetiredMaxTierMigratesToHigh() {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: "deepSearchLevel")
        defer {
            if let previous { defaults.set(previous, forKey: "deepSearchLevel") }
            else { defaults.removeObject(forKey: "deepSearchLevel") }
        }
        defaults.set("max", forKey: "deepSearchLevel")
        XCTAssertEqual(DeepSearch.level, .high)
    }

    /// Rehomed from the deleted Gemma prompt test. These two compiled fine without
    /// the retired tier and were dropped with it by accident, leaving nothing in the
    /// suite asserting either property while `DeepSearch.swift` still feeds both into
    /// `HFEmbedder`. Near-tautological today — every shipped tier is symmetric, so
    /// both are unconditional `""` — which is exactly the point: if a future
    /// asymmetric tier sets a prefix, that has to be a deliberate edit here.
    func testShippedTiersAreSymmetricAndUsePrefixlessPrompts() {
        for level in DeepSearchLevel.allCases {
            XCTAssertEqual(level.queryPrefix, "", "\(level.rawValue) grew a query prefix")
            XCTAssertEqual(level.docPrefix, "", "\(level.rawValue) grew a doc prefix")
        }
    }

    func testCalibratedFloors() {
        XCTAssertEqual(DeepSearchLevel.high.hfRelevanceFloor, 0.20, accuracy: 0.001)
    }
}
