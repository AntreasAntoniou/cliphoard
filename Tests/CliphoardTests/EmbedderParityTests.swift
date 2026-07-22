import XCTest
import CoreML
@testable import Cliphoard

/// CoreML golden-vector parity for the real ogma embedder (promotes the DEBUG
/// `AppDelegate.embedSelfTest` logic into a proper XCTest).
///
/// The converted `.mlpackage` models are NOT checked in (`tools/models/` and
/// `*.mlpackage` are gitignored), so this test SKIPS cleanly in a fresh clone and
/// `swift test` stays GREEN. When a real model is present it loads it exactly the
/// way `EmbedderProvider.configure` does (CoreML model + `OgmaTokenizer`), embeds a
/// fixed string, and asserts the leading vector components and the tokenizer token
/// ids match checked-in golden values from `tools/reference.json`.
///
/// MODEL DETECTION (first that resolves wins):
///   1. `$CLIPHOARD_OGMA_MODEL_DIR` — a directory containing `<name>.mlpackage` and a
///      sibling `<name>/` tokenizer folder (the exact layout produced by
///      `tools/restore-models.sh`), OR a directory that is itself a `.mlpackage`
///      with a sibling tokenizer folder.
///   2. `<repo>/tools/models/open-ogma-small.mlpackage` + `<repo>/tools/models/open-ogma-small/`.
/// If neither resolves, `XCTSkip` is thrown with a clear message.
///
/// REGENERATING THE GOLDENS (from the real PyTorch model — single source of truth):
///   # 1. Restore + convert the model (writes tools/models/open-ogma-small.mlpackage,
///   #    prints parity_cosine vs the CoreML output — see tools/convert_ogma.py):
///   MODELS="open-ogma-small" tools/restore-models.sh
///   # 2. Recompute the PyTorch reference goldens (writes tools/reference.json):
///   cd tools && python3 reference.py
///   # 3. Copy the "the quick brown fox" / task "doc" entry's `ids` and `vec_head`
///   #    from tools/reference.json into `goldenIds` / `goldenHead` below. The
///   #    values here are kept byte-identical to that entry.
///   # 4. (optional) run this XCTest against the real model end-to-end:
///   CLIPHOARD_OGMA_MODEL_DIR="$PWD/tools/models" swift test --filter EmbedderParityTests
final class EmbedderParityTests: XCTestCase {

    /// The fixed probe string — same constant `AppDelegate.embedSelfTest` uses, and
    /// the first sample in `tools/reference.py`.
    private let probe = "the quick brown fox"

    /// Golden tokenizer ids for `probe` (task=doc), from tools/reference.json[0].ids.
    private let goldenIds: [Int32] = [2, 264, 2963, 2442, 14556, 3]

    /// Golden leading embedding components for `probe` (task=doc), from
    /// tools/reference.json[0].vec_head (first 6 dims of the L2-normalised vector).
    private let goldenHead: [Float] = [-0.07704, -0.0528, 0.00029, -0.00834, 0.04225, -0.0167]

    /// Per-component tolerance: PyTorch reference vs CoreML Float16 inference. The
    /// converter's parity_cosine (tools/convert_ogma_libre.py) confirms agreement at the
    /// vector level; ~1e-3 absorbs Float16 rounding on individual components.
    private let tolerance: Float = 1e-3

    // MARK: Model resolution

    /// A resolved model: the `.mlpackage` URL and its matching tokenizer folder.
    private struct ResolvedModel {
        let name: String
        let mlpackage: URL
        let tokenizerFolder: URL
    }

    /// Default model used when `$CLIPHOARD_OGMA_MODEL_DIR` is unset. The checked-in
    /// goldens were produced from open-ogma-small (384-dim head) — see tools/reference.py.
    private let defaultModelName = "open-ogma-small"

    /// `<repo>/tools/models` relative to this source file (…/Tests/CliphoardTests/…).
    private var defaultModelsDir: URL {
        URL(fileURLWithPath: #filePath)            // …/Tests/CliphoardTests/EmbedderParityTests.swift
            .deletingLastPathComponent()           // …/Tests/CliphoardTests
            .deletingLastPathComponent()           // …/Tests
            .deletingLastPathComponent()           // …/<repo>
            .appendingPathComponent("tools/models")
    }

    /// Resolve a model from the env var (preferred) or the default tools/models
    /// path. Returns nil when nothing usable is present (→ skip).
    private func resolveModel() -> ResolvedModel? {
        let fm = FileManager.default

        // 1. Env override. May point at a directory holding <name>.mlpackage +
        //    <name>/ tokenizer, or directly at a <name>.mlpackage.
        if let dir = ProcessInfo.processInfo.environment["CLIPHOARD_OGMA_MODEL_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir)
            if url.pathExtension == "mlpackage" {
                if let m = model(at: url) { return m }
            }
            if let m = firstModel(in: url) { return m }
        }

        // 2. Default: <repo>/tools/models/open-ogma-small.mlpackage (+ tokenizer folder),
        //    falling back to any other .mlpackage with a matching tokenizer folder.
        let preferred = defaultModelsDir.appendingPathComponent("\(defaultModelName).mlpackage")
        if let m = model(at: preferred) { return m }
        guard fm.fileExists(atPath: defaultModelsDir.path) else { return nil }
        return firstModel(in: defaultModelsDir)
    }

    /// First `<name>.mlpackage` in `dir` that has a sibling `<name>/` tokenizer
    /// folder (lexicographically, for determinism).
    private func firstModel(in dir: URL) -> ResolvedModel? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return nil
        }
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where url.pathExtension == "mlpackage" {
            if let m = model(at: url) { return m }
        }
        return nil
    }

    /// Validate a specific `.mlpackage` and locate its tokenizer folder (the
    /// sibling `<name>/` directory containing tokenizer.json, per restore-models.sh).
    private func model(at mlpackage: URL) -> ResolvedModel? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: mlpackage.path), mlpackage.pathExtension == "mlpackage" else {
            return nil
        }
        let name = mlpackage.deletingPathExtension().lastPathComponent
        let tokFolder = mlpackage.deletingLastPathComponent().appendingPathComponent(name)
        guard fm.fileExists(atPath: tokFolder.appendingPathComponent("tokenizer.json").path) else {
            return nil
        }
        return ResolvedModel(name: name, mlpackage: mlpackage, tokenizerFolder: tokFolder)
    }

    /// Load the resolved `.mlpackage` directly. The app bundles a precompiled
    /// `.mlmodelc` (see Scripts/build-app.sh) so `EmbedderProvider.configure` reads
    /// that; here we have the raw `.mlpackage`, so compile it first when CoreML
    /// can't load it directly.
    private func loadModel(_ url: URL) throws -> MLModel {
        if let m = try? MLModel(contentsOf: url) { return m }
        let compiled = try MLModel.compileModel(at: url)
        return try MLModel(contentsOf: compiled)
    }

    // MARK: Test

    @MainActor
    func testEmbedderGoldenVectorParity() throws {
        guard let resolved = resolveModel() else {
            throw XCTSkip("""
                No ogma CoreML model found — skipping golden-vector parity. \
                The .mlpackage models are gitignored; restore one with \
                `MODELS="\(defaultModelName)" tools/restore-models.sh`, or point \
                $CLIPHOARD_OGMA_MODEL_DIR at a directory containing <name>.mlpackage + a \
                sibling <name>/ tokenizer folder.
                """)
        }

        let model = try loadModel(resolved.mlpackage)
        let tokenizer = try XCTUnwrap(
            OgmaTokenizer(folder: resolved.tokenizerFolder),
            "tokenizer folder \(resolved.tokenizerFolder.path) should load")

        // (b) Tokenizer ids match the checked-in golden ids.
        let ids = tokenizer.encode(probe).map { Int32($0) }
        XCTAssertEqual(ids, goldenIds,
                       "tokenizer ids for \"\(probe)\" diverged from tools/reference.json")

        // Construct the embedder exactly as EmbedderProvider.configure does. The
        // goldens were produced from open-ogma-small (384-dim head); the embedder only checks
        // the vector length matches `dimension`, so use that model's dimension.
        let embedder = OgmaEmbedder(modelName: resolved.name, model: model,
                                    tokenizer: tokenizer, dimension: DeepSearchLevel.normal.dimension)
        let vec = embedder.embed(probe)   // doc task — same as embedSelfTest / reference.py

        XCTAssertFalse(vec.isEmpty, "embedder returned an empty vector (prediction failed)")
        XCTAssertGreaterThanOrEqual(vec.count, goldenHead.count,
                                    "vector shorter than the \(goldenHead.count) golden components")

        // The converted forward already L2-normalises (reference.json norm == 1.0);
        // confirm so a parity mismatch can't hide behind an unnormalised vector.
        let norm = (vec.reduce(0) { $0 + $1 * $1 }).squareRoot()
        XCTAssertEqual(norm, 1.0, accuracy: 1e-2, "embedding should be L2-normalised")

        // (a) Leading components match the checked-in golden floats within tolerance.
        for i in 0..<goldenHead.count {
            XCTAssertEqual(vec[i], goldenHead[i], accuracy: tolerance,
                           "component \(i) parity mismatch: got \(vec[i]), golden \(goldenHead[i])")
        }
    }
}
