import XCTest
import SQLite3
@testable import Cliphoard

/// Downloads use reviewed immutable Hugging Face artifacts in both distribution channels.
final class AssetSourceTests: XCTestCase {
    func testPublishedSourcesArePinnedHuggingFaceOnly() {
        for name in ["open-ogma-micro", "open-ogma-small"] {
            let item = ModelAssets.catalog[name]!
            XCTAssertEqual(item.repository, "axiotic/\(name)")
            XCTAssertEqual(item.revision?.count, 40)
            XCTAssertEqual(item.url?.host, "huggingface.co")
            XCTAssertFalse(item.url!.absoluteString.contains("/main/"))
        }
    }
    func testConvertedModelsUseVerifiedPublicRevisionAndUnknownStaysUnavailable() {
        for name in ["all-MiniLM-L6-v2", "openvision-tiny-p8"] {
            XCTAssertEqual(ModelAssets.assetURL(for: name)?.absoluteString,
                "https://huggingface.co/axiotic/cliphoard-coreml-models/resolve/735cf3ec9bcaff2a46dd0f41997d0ab10bf068b4/coreml/\(name).zip")
        }
        XCTAssertNil(ModelAssets.assetURL(for: "unknown"))
        XCTAssertFalse(ModelAssets.canPrepareLocally("unknown"))
    }
    func testSameSizeCorruptArchiveIsRefusedWithoutChangingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let physical = URL(fileURLWithPath: root.path.hasPrefix("/var/") ? "/private" + root.path : root.path)
        let file = physical.appendingPathComponent("asset.zip")
        let bytes = Data("bad".utf8); try bytes.write(to: file)
        let item = ModelAssets.Artifact(repository: nil, revision: nil, path: "asset.zip", bytes: 3,
            sha256: String(repeating: "0", count: 64), models: [], tokenizer: "")
        XCTAssertThrowsError(try ModelAssets.verifyArchive(file, artifact: item))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testUnknownNameCannotReturnBundledOrLegacyAssets() async {
        XCTAssertNil(ModelAssets.locate("unknown"))
        do { _ = try await ModelAssets.ensure("unknown", allowDownload: false); XCTFail("accepted unknown") }
        catch { XCTAssertTrue(error is ModelAssets.Failure) }
    }
}

/// Reading another app's live database means reading its WAL.
///
/// The Maccy adapter returned ZERO clips from a database holding seven. Not a crash, not an
/// error — a successful query over an empty result set, reported as "0 clips to import".
/// The shared open used `immutable=1`, which tells SQLite the file cannot change and so to
/// ignore the -wal sidecar entirely. Maccy's WAL held 296KB: everything.
///
/// The flag arrived by copy from the Paste importer, where it is genuinely correct — that
/// source is a frozen export with no live writer. A justification true of one input, applied
/// to every input.
///
/// This is the THIRD time WAL handling has produced a confident wrong answer in this project
/// (a corpus count, an archive that would not open, and now an import), which is why the
/// rule now lives in one function instead of at each call site.
final class WALHandlingTests: XCTestCase {

    func testReadOnlyImportActuallySeesACommittedRowThatExistsOnlyInWAL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliphoard-wal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("Storage.sqlite").path

        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; "
                                    + "CREATE TABLE clips(value TEXT); PRAGMA wal_checkpoint(TRUNCATE);",
                                    nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(writer, "INSERT INTO clips VALUES ('from-live-wal');",
                                    nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "-wal"))
        XCTAssertNil(ClipImporters.liveSQLiteReadError(path))

        var values: [String] = []
        ClipImporters.forEachRow(path, "SELECT value FROM clips;") { statement in
            if let text = sqlite3_column_text(statement, 0) {
                values.append(String(cString: text))
            }
        }
        XCTAssertEqual(values, ["from-live-wal"],
                       "a preview that misses committed WAL rows is a silent data-loss report")
    }

    func testStoreDirectoryResolutionRejectsASymlinkEscape() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliphoard-scope-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString).sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: outside.path, contents: Data())
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Storage.sqlite"), withDestinationURL: outside)
        let maccy = try XCTUnwrap(ClipImporters.all.first { $0.id == "maccy" })
        XCTAssertNil(ClipImporters.storeURL(for: maccy, in: root),
                     "a Powerbox directory grant must not authorize a symlink target outside it")
    }

    /// No adapter may re-introduce a hardcoded immutable open. This is the copy-paste that
    /// caused the bug, and it is the copy-paste most likely to happen again.
    func testNoAdapterOpensAStoreDirectly() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Sources/Cliphoard/Support/ClipImporters.swift",
                     "Sources/Cliphoard/Support/PasteImport.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            // sqlite3_open_v2 belongs ONLY inside openReadOnly.
            let opens = source.components(separatedBy: "sqlite3_open_v2(").count - 1
            let expected = file.hasSuffix("ClipImporters.swift") ? 3 : 0
            XCTAssertEqual(opens, expected,
                           "\(file) calls sqlite3_open_v2 \(opens) time(s); expected "
                           + "\(expected). Every store must be opened through openReadOnly, "
                           + "or the WAL rule has to be remembered per call site — which is "
                           + "how a live database came back empty.")
        }
    }
}

/// The shipped weights must come from the repos whose licence we advertise.
///
/// This is the test that was missing when it mattered. The tiers named `open-ogma-*` were
/// fetched from `axiotic/ogma-micro` and `axiotic/ogma-small`, which declare **CC-BY-NC-4.0**,
/// while every document — the site, the README, THIRD-PARTY-NOTICES, and this file's own
/// header — said MIT. Nothing caught it: the code built, the tests passed, the markup
/// validated. The only place the two names differed was one dictionary.
///
/// WHAT THE DEFECT ACTUALLY WAS, since the first version of this comment got it wrong and a
/// verifier caught it: NOT that NonCommercial weights shipped. The `coreml/` artifact inside
/// the NC-declared repos was ALREADY the permissive model — byte-identical `weight.bin`
/// (`c4a35d6d…` for small), `model_type: "ogma-libre"`. The defect was PROVENANCE: an MIT app
/// fetching from a repo whose declared licence said NonCommercial. What a downloader is
/// entitled to rely on is the licence the source repo declares, so that is the thing this
/// pins. The claim "a CoreML build was missing" was also false — one had been live since
/// 2026-08-17.
///
#if !APP_STORE
@MainActor
final class OgmaLicenceSourceTests: XCTestCase {

    /// The ogma tiers must resolve to the `open-ogma-*` repos. The bare `ogma-*` repos are
    /// CC-BY-NC and must never be the source for an MIT app.
    func testTheOgmaTiersComeFromThePermissiveRepos() {
        for tier in ["open-ogma-micro", "open-ogma-small"] {
            guard case .huggingFace(let repo) = ModelAssets.source(for: tier) else {
                return XCTFail("\(tier) is no longer served from HuggingFace")
            }
            XCTAssertEqual(repo, "axiotic/\(tier)",
                           "\(tier) resolves to '\(repo)'. The repos named axiotic/ogma-micro "
                           + "and axiotic/ogma-small declare CC-BY-NC-4.0 — pointing an "
                           + "MIT-licensed app at them ships NonCommercial weights under a "
                           + "permissive banner, which is exactly the defect this pins.")
            XCTAssertFalse(repo == "axiotic/ogma-micro" || repo == "axiotic/ogma-small",
                           "the NonCommercial repo is back")
        }
    }

    /// Every model that can reach `ensure` must have a pinned digest.
    ///
    /// This replaces a test that asserted `expectedSHA256["open-ogma-micro"]` equalled a
    /// hardcoded copy of that same literal. Two copies of an answer agreeing tells you nothing
    /// about the world: it would have passed just as green with both copies wrong. Derive from
    /// the set of names that actually reach the loader instead.
    ///
    /// `DeepSearchLevel.allCases`, NOT `ModelAssets.sources.keys` — `all-MiniLM-L6-v2` is not
    /// in `sources` (it falls through to `.githubRelease`), so keying off `sources` would
    /// leave the MiniLM pin unguarded, which is exactly the gap that lets an unpinned tier
    /// exist in the first place.
    func testEveryReachableTierIsPinned() {
        let reachable = DeepSearchLevel.allCases.compactMap(\.modelName)
        XCTAssertFalse(reachable.isEmpty, "no tier names — the enum changed shape")
        for name in reachable {
            XCTAssertNotNil(ModelAssets.expectedSHA256[name],
                            "'\(name)' can be requested by DeepSearch but has no pinned "
                            + "SHA-256. `ensure` now refuses to install an unpinned model, so "
                            + "this tier would fail at runtime rather than silently accept "
                            + "whatever the network returned — but it must not ship at all.")
            XCTAssertEqual(ModelAssets.expectedSHA256[name]?.count, 64,
                           "'\(name)' has a digest that is not a 64-char SHA-256 hex string")
        }
    }

    /// The file's own prose must not point at the NonCommercial repos either — the header
    /// claiming the bare CC-BY-NC repo pattern is what made the wrong mapping look intentional.
    func testTheDocCommentDoesNotAdvertiseTheNonCommercialRepos() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // Built from two halves so this file's own source cannot satisfy its own check.
        let needle = "`axiotic/" + "ogma-*`"
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Cliphoard/Search/ModelAssets.swift"),
            encoding: .utf8)
        XCTAssertFalse(source.contains(needle),
                       "the header still advertises the CC-BY-NC repos as ours-and-permissive")
        let thisFile = try String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)
        XCTAssertFalse(thisFile.contains(needle),
                       "this test file's own header still says the models are published at the CC-BY-NC repos")
    }
}
#endif
