import XCTest
@testable import Cliphoard

/// Where each model tier is fetched from, and why the HuggingFace path has an extra request.
///
/// The ogma models are ours, published at `axiotic/open-ogma-*` (MIT). Serving them from a GitHub
/// release made real adoption of a model we released invisible on the platform people
/// actually look at to judge whether a model is used. Moving them to HuggingFace fixes that
/// — but only if the install path touches the file HuggingFace COUNTS.
///
/// It does not count file requests generally. Per the Hub's own documentation, downloads are
/// counted from a per-library "query file", and for a repository with no declared library
/// that file is `config.json`. A request for `coreml/<name>.zip` therefore registers as ZERO
/// downloads. Without the companion request the number would stay at whatever it is now
/// while every Cliphoard user in the world installed the model.
///
/// That companion request is the thing most likely to be deleted by someone tidying up, so
/// it is pinned here with the reason attached.
final class AssetSourceTests: XCTestCase {

    // MARK: - Routing

    func testTheOgmaTiersAreServedFromHuggingFace() {
        for name in ["open-ogma-micro", "open-ogma-small"] {
            guard case .huggingFace(let repo) = ModelAssets.source(for: name) else {
                return XCTFail("\(name) is no longer served from HuggingFace — its download "
                               + "statistics will stop reflecting real usage, which is the "
                               + "entire reason it was moved off the GitHub release")
            }
            XCTAssertTrue(repo.hasPrefix("axiotic/"),
                          "\(name) points at '\(repo)', which is not one of our repositories")
        }
    }

    /// MiniLM must NOT be redirected to HuggingFace. The CoreML conversion is ours, but
    /// `sentence-transformers/all-MiniLM-L6-v2` is not our repository — attributing our
    /// conversion's downloads there would misreport SOMEONE ELSE'S numbers to improve ours.
    func testMiniLMStaysOnOurOwnRelease() {
        guard case .githubRelease = ModelAssets.source(for: "all-MiniLM-L6-v2") else {
            return XCTFail("MiniLM must be served from our GitHub release. Publishing our "
                           + "CoreML conversion into the upstream repo, or counting our "
                           + "downloads against it, misreports their model's usage.")
        }
    }

    /// An unknown tier falls back to the release rather than constructing a HuggingFace URL
    /// for a repository that may not exist.
    func testAnUnknownTierFallsBackToTheGitHubRelease() {
        guard case .githubRelease = ModelAssets.source(for: "some-future-tier") else {
            return XCTFail("an unregistered tier must default to the GitHub release")
        }
    }

    // MARK: - URLs

    func testHuggingFaceURLsPointAtTheCoreMLArtifact() {
        let url = ModelAssets.assetURL(for: "open-ogma-small")
        XCTAssertEqual(url.absoluteString,
                       "https://huggingface.co/axiotic/open-ogma-small/resolve/main/coreml/open-ogma-small.zip",
                       "the resolve path must match where the artifact was actually uploaded; "
                       + "a wrong path is a 404 on first run for every new user")
        XCTAssertEqual(url.scheme, "https", "model downloads must never be plaintext")
    }

    func testGitHubURLsAreUnchangedForTiersThatStayThere() {
        XCTAssertEqual(ModelAssets.assetURL(for: "all-MiniLM-L6-v2").absoluteString,
                       ModelAssets.releaseBase.appendingPathComponent("all-MiniLM-L6-v2.zip")
                           .absoluteString)
    }

    // MARK: - The counting request

    /// The companion `config.json` request must still exist on the install path, and must
    /// still be conditional on the source being HuggingFace — issuing it for a GitHub tier
    /// would be a pointless request to a third party.
    func testTheDownloadCountingRequestIsStillOnTheInstallPath() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Cliphoard/Search/ModelAssets.swift"),
            encoding: .utf8)

        XCTAssertTrue(source.contains("private static func recordDownload(repo:"),
                      "recordDownload was removed. HuggingFace counts downloads from "
                      + "config.json, not from the artifact, so without it every install is "
                      + "invisible on the model page — which is the whole point of hosting "
                      + "there. If it looked like dead code, read its doc comment.")
        XCTAssertTrue(source.contains("await recordDownload(repo: repo)"),
                      "recordDownload exists but is no longer CALLED — the statistic silently "
                      + "stops accruing while everything still works")
        XCTAssertTrue(source.contains("if case .huggingFace(let repo) = source(for: name)"),
                      "the counting request must fire only for HuggingFace-hosted tiers")
        XCTAssertTrue(source.contains("config.json"),
                      "the counted query file must remain config.json — the Hub's default "
                      + "for a repo with no declared library. Any other file counts nothing.")
    }

    /// It must stay best-effort. A statistic is our concern; the model is the user's, and an
    /// install must never fail because a metrics request did.
    func testTheCountingRequestCannotBlockAnInstall() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Cliphoard/Search/ModelAssets.swift"),
            encoding: .utf8)
        guard let start = source.range(of: "private static func recordDownload(repo:") else {
            return XCTFail("recordDownload was renamed or removed")
        }
        let body = String(source[start.upperBound...].prefix(600))
        XCTAssertTrue(body.contains("_ = try? await"),
                      "the counting request must swallow its errors — `try` without `?` would "
                      + "let a metrics failure abort a model install")
        XCTAssertTrue(body.contains("timeoutInterval"),
                      "it must carry a timeout, or a hanging metrics request stalls the "
                      + "install it is supposed to be incidental to")
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

    /// The open must prefer `mode=ro`, which reads the WAL, and use `immutable=1` only as a
    /// fallback — not the other way round.
    func testTheReadOnlyOpenPrefersWALAwareMode() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Cliphoard/Support/ClipImporters.swift"),
            encoding: .utf8)
        guard let start = source.range(of: "static func openReadOnly(") else {
            return XCTFail("openReadOnly was renamed — move this test with it")
        }
        let body = String(source[start.upperBound...].prefix(1200))
        guard let ro = body.range(of: "?mode=ro\""),
              let immutable = body.range(of: "immutable=1") else {
            return XCTFail("expected both a WAL-aware attempt and an immutable fallback")
        }
        XCTAssertLessThan(ro.lowerBound, immutable.lowerBound,
                          "immutable=1 is tried FIRST, so a live app's WAL is ignored and the "
                          + "import silently under-reports — the exact defect this exists to "
                          + "prevent")
    }

    /// Falling back must be announced. An incomplete import that reports a confident total
    /// is worse than one that says it might be missing recent clips.
    func testTheImmutableFallbackIsAnnounced() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Cliphoard/Support/ClipImporters.swift"),
            encoding: .utf8)
        guard let start = source.range(of: "static func openReadOnly(") else { return }
        let body = String(source[start.upperBound...].prefix(1200))
        XCTAssertTrue(body.contains("NSLog"),
                      "the fallback is silent; a user would get an undercount with nothing "
                      + "indicating the WAL was skipped")
        XCTAssertTrue(body.lowercased().contains("may be missing"),
                      "the warning must say what the consequence IS, not merely that a "
                      + "fallback happened")
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
            let expected = file.hasSuffix("ClipImporters.swift") ? 2 : 0
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
