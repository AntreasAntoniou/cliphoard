import XCTest
@testable import Cliphoard

/// Where each model tier is fetched from, and why the HuggingFace path has an extra request.
///
/// The ogma models are ours, published at `axiotic/ogma-*`. Serving them from a GitHub
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
                       "https://huggingface.co/axiotic/ogma-small/resolve/main/coreml/open-ogma-small.zip",
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
