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
/// MODEL RESOLUTION (open-ogma-small only, because it produced these goldens):
///   1. A nonempty `$CLIPHOARD_OGMA_MODEL_DIR` must name a directory containing
///      `open-ogma-small.mlpackage` and `open-ogma-small/tokenizer.json`, OR that
///      exact `.mlpackage` with its sibling tokenizer folder. An incompatible,
///      missing or incomplete override throws an error; it never falls back.
///   2. With an unset or empty override, only `<repo>/tools/models/open-ogma-small.mlpackage`
///      and its sibling tokenizer are considered. Missing default fixtures cause `XCTSkip`.
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
    private let goldenHead: [Float] = [-0.00076, -0.00118, 0.02593, -0.02741, -0.05632, -0.01341]

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
    /// goldens were produced from open-ogma-small (1024-d proj_large head, the default) — see tools/reference.py.
    private let defaultModelName = "open-ogma-small"

    /// `<repo>/tools/models` relative to this source file (…/Tests/CliphoardTests/…).
    private var defaultModelsDir: URL {
        URL(fileURLWithPath: #filePath)            // …/Tests/CliphoardTests/EmbedderParityTests.swift
            .deletingLastPathComponent()           // …/Tests/CliphoardTests
            .deletingLastPathComponent()           // …/Tests
            .deletingLastPathComponent()           // …/<repo>
            .appendingPathComponent("tools/models")
    }

    /// Only this wrapper reads process state; the resolver below takes both locations
    /// explicitly so filesystem fixtures can exercise precedence without mutating the env.
    private func resolveModel() throws -> ResolvedModel? {
        try resolveModel(override: ProcessInfo.processInfo.environment["CLIPHOARD_OGMA_MODEL_DIR"],
                         defaultModelsDir: defaultModelsDir)
    }

    private struct InvalidModelOverride: LocalizedError {
        let path: String
        let expectedModelName: String

        var errorDescription: String? {
            "Invalid CLIPHOARD_OGMA_MODEL_DIR '\(path)': expected \(expectedModelName).mlpackage "
                + "with a sibling \(expectedModelName)/tokenizer.json, or a directory containing both. "
                + "The override is missing, incomplete or incompatible with these golden vectors."
        }
    }

    /// An absent optional default skips; an explicitly selected invalid fixture fails.
    /// A different model cannot be a substitute for the one that produced the goldens.
    private func resolveModel(override: String?, defaultModelsDir: URL) throws -> ResolvedModel? {
        guard let override, !override.isEmpty else {
            return model(at: defaultModelsDir.appendingPathComponent("\(defaultModelName).mlpackage"))
        }
        let location = URL(fileURLWithPath: override)
        let package = location.pathExtension == "mlpackage"
            ? location
            : location.appendingPathComponent("\(defaultModelName).mlpackage")
        guard let resolved = model(at: package) else {
            throw InvalidModelOverride(path: override, expectedModelName: defaultModelName)
        }
        return resolved
    }

    /// Require the exact package directory and a tokenizer file beside it. Do not infer
    /// compatibility from a `.mlpackage` suffix or accept another model's tokenizer.
    private func model(at mlpackage: URL) -> ResolvedModel? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard mlpackage.lastPathComponent == "\(defaultModelName).mlpackage",
              fm.fileExists(atPath: mlpackage.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        let tokenizerFolder = mlpackage.deletingLastPathComponent().appendingPathComponent(defaultModelName)
        guard fm.fileExists(atPath: tokenizerFolder.appendingPathComponent("tokenizer.json").path,
                            isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return ResolvedModel(name: defaultModelName, mlpackage: mlpackage,
                             tokenizerFolder: tokenizerFolder)
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
        guard let resolved = try resolveModel() else {
            throw XCTSkip("""
                No complete \(defaultModelName) CoreML fixture found at \(defaultModelsDir.path) — \
                skipping golden-vector parity. The gitignored fixture must contain \
                \(defaultModelName).mlpackage and \(defaultModelName)/tokenizer.json. Restore it with \
                `MODELS="\(defaultModelName)" tools/restore-models.sh`, or set \
                $CLIPHOARD_OGMA_MODEL_DIR to that exact package or a directory containing it. \
                Other models cannot be compared with these goldens.
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
        // goldens were produced from open-ogma-small (1024-d proj_large head, the default); the embedder only checks
        // the vector length matches `dimension`, so use that model's dimension.
        let embedder = OgmaEmbedder(modelName: resolved.name, model: model,
                                    tokenizer: tokenizer, dimension: VectorDetail.full1024.dimension,
                                    outputName: VectorDetail.full1024.outputName)
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
    // MARK: Filesystem-only resolver regressions

    private func withResolverFixtures(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CliphoardOgmaResolver-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @discardableResult
    private func fixtureModel(_ name: String, in directory: URL,
                              withTokenizer: Bool = true) throws -> URL {
        let package = directory.appendingPathComponent("\(name).mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        if withTokenizer {
            let tokenizer = directory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: tokenizer, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: tokenizer.appendingPathComponent("tokenizer.json"))
        }
        return package
    }

    private func assertRejectedOverride(_ path: URL, defaultModelsDir: URL,
                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try resolveModel(override: path.path, defaultModelsDir: defaultModelsDir),
                             file: file, line: line) { error in
            XCTAssertTrue(error.localizedDescription.contains(self.defaultModelName),
                          "the error must name the model required by the goldens", file: file, line: line)
            XCTAssertTrue(error.localizedDescription.contains(path.path),
                          "the error must identify the rejected override", file: file, line: line)
        }
    }

    func testResolverSkipsAnOpenVisionOnlyDefault() throws {
        try withResolverFixtures { root in
            try fixtureModel("openvision-tiny-p8-text", in: root)
            XCTAssertNil(try resolveModel(override: nil, defaultModelsDir: root))
        }
    }

    func testResolverSkipsAMissingDefaultDirectory() throws {
        try withResolverFixtures { root in
            XCTAssertNil(try resolveModel(override: nil, defaultModelsDir: root.appendingPathComponent("absent")))
        }
    }

    func testResolverUsesTheExactDefaultModel() throws {
        try withResolverFixtures { root in
            let expected = try fixtureModel(defaultModelName, in: root)
            let resolved = try XCTUnwrap(resolveModel(override: nil, defaultModelsDir: root))
            XCTAssertEqual(resolved.mlpackage, expected)
            XCTAssertEqual(resolved.name, defaultModelName)
        }
    }

    func testResolverChoosesTheExpectedModelFromAMixedOverride() throws {
        try withResolverFixtures { root in
            try fixtureModel("all-MiniLM-L6-v2", in: root)
            try fixtureModel("openvision-tiny-p8-text", in: root)
            let expected = try fixtureModel(defaultModelName, in: root)
            let resolved = try XCTUnwrap(resolveModel(override: root.path,
                                                       defaultModelsDir: root.appendingPathComponent("absent")))
            XCTAssertEqual(resolved.mlpackage, expected)
        }
    }

    func testResolverAcceptsTheExactDirectPackageOverride() throws {
        try withResolverFixtures { root in
            let expected = try fixtureModel(defaultModelName, in: root)
            let resolved = try XCTUnwrap(resolveModel(override: expected.path,
                                                       defaultModelsDir: root.appendingPathComponent("absent")))
            XCTAssertEqual(resolved.mlpackage, expected)
        }
    }

    func testResolverRejectsAWrongDirectModelEvenWithAValidDefault() throws {
        try withResolverFixtures { root in
            let defaults = root.appendingPathComponent("defaults")
            try fixtureModel(defaultModelName, in: defaults)
            let wrong = try fixtureModel("openvision-tiny-p8-text", in: root.appendingPathComponent("override"))
            assertRejectedOverride(wrong, defaultModelsDir: defaults)
        }
    }

    func testResolverRejectsMissingOrIncompleteOverridesInsteadOfFallingBack() throws {
        try withResolverFixtures { root in
            let defaults = root.appendingPathComponent("defaults")
            try fixtureModel(defaultModelName, in: defaults)
            assertRejectedOverride(root.appendingPathComponent("absent"), defaultModelsDir: defaults)
            let incomplete = root.appendingPathComponent("incomplete")
            try fixtureModel(defaultModelName, in: incomplete, withTokenizer: false)
            assertRejectedOverride(incomplete, defaultModelsDir: defaults)
            let incompatible = root.appendingPathComponent("incompatible")
            try fixtureModel("openvision-tiny-p8-text", in: incompatible)
            assertRejectedOverride(incompatible, defaultModelsDir: defaults)
        }
    }

    func testResolverSkipsADefaultWithoutItsTokenizer() throws {
        try withResolverFixtures { root in
            try fixtureModel(defaultModelName, in: root, withTokenizer: false)
            XCTAssertNil(try resolveModel(override: nil, defaultModelsDir: root))
        }
    }

    func testResolverTreatsAnEmptyOverrideAsUnset() throws {
        try withResolverFixtures { root in
            let expected = try fixtureModel(defaultModelName, in: root)
            let resolved = try XCTUnwrap(resolveModel(override: "", defaultModelsDir: root))
            XCTAssertEqual(resolved.mlpackage, expected)
        }
    }

}
