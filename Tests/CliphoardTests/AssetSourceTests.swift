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
