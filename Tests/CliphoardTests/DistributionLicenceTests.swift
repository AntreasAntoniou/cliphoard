import XCTest
@testable import Cliphoard

/// The licence artefacts, pinned to what actually ships.
///
/// Neither `LICENSE` nor `THIRD-PARTY-NOTICES.md` had a single test, and that is exactly
/// where the worst defect of the release survived: `LICENSE` told users the bundled ogma
/// models were CC-BY-NC-4.0 and that the MIT grant "including to sell" did not extend to
/// them. Both halves false — those models are MIT and were never bundled — and the file ships
/// inside the `.app` and at the DMG root. A source fix, a docs fix and a notices rewrite all
/// landed in one session without touching it, because nothing pointed at it. The docs greps
/// that felt exhaustive searched for the NC *repo URLs*; `LICENSE` states the restriction in
/// prose and contains no URL.
///
/// TWO RULES, both learned here the hard way:
///
///   1. **Derive, never restate.** A test that hardcodes a second copy of the answer passes
///      whenever the two copies agree and says nothing about the world. That is what
///      `testTheDigestsMatchThePublishedMITArtifacts` did — asserted `expectedSHA256["x"]`
///      equalled a literal copy of `expectedSHA256["x"]`. These tests read the build scripts
///      and `Package.resolved`, which are the things that actually decide.
///   2. **Anchor the parse.** `ForgetOrderingTests` documents the repo's recurring trap: a
///      source-text assertion matching the PROSE that explains why something is not done.
///      `deploy-local.sh` discusses at length which models are *not* bundled, so the bundle
///      list is read from the `BUNDLE_MODELS=` assignment, never by searching for names.
final class DistributionLicenceTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Lines with the comments removed. Load-bearing, not tidiness: these scripts spend two
    /// dozen comment lines discussing which models are *not* bundled, and `release.sh` has a
    /// comment about "licence + attribution" sitting directly above the `cp` lines. Every
    /// source-text assertion below would otherwise match the prose ABOUT the decision instead
    /// of the decision — the trap `ForgetOrderingTests` documents, which this repo has fallen
    /// into repeatedly.
    private func code(_ path: String) throws -> [String] {
        try read(path).split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
    }

    /// Every `BUNDLE_MODELS="…"` assignment in a script, as sets of model names.
    ///
    /// Returns all of them and the caller asserts the count, because a parser that silently
    /// finds nothing turns every assertion built on it into a no-op that reports success.
    private func bundleAssignments(_ path: String) throws -> [Set<String>] {
        try code(path).compactMap { line -> Set<String>? in
            guard let r = line.range(of: "BUNDLE_MODELS=\"") else { return nil }
            let rest = line[r.upperBound...]
            guard let close = rest.firstIndex(of: "\"") else { return nil }
            var body = String(rest[..<close])
            // build-app.sh writes the default as ${BUNDLE_MODELS:-a b}; take the default.
            if body.hasPrefix("${"), let d = body.range(of: ":-") {
                body = String(body[d.upperBound...]).replacingOccurrences(of: "}", with: "")
            }
            // `BUNDLE_MODELS="$BUNDLE_MODELS"` is a pass-through, not a declaration.
            if body.hasPrefix("$") { return nil }
            let names = body.split(separator: " ").map(String.init)
            return names.isEmpty ? nil : Set(names)
        }
    }

    private func bundledModels() throws -> Set<String> {
        let a = try bundleAssignments("Scripts/deploy-local.sh")
        XCTAssertEqual(a.count, 1, "expected exactly one BUNDLE_MODELS assignment in "
                       + "deploy-local.sh, found \(a.count) — the parse is unreliable, so "
                       + "every test built on it is unreliable too")
        return a.first ?? []
    }

    /// The `**How it reaches you:**` line of a model's section, and only that line.
    ///
    /// Reading the whole section would be wrong in a way that is easy to miss: the OpenVision
    /// entry's Attribution bullet contains the words "described as bundled" while describing
    /// the exact opposite, and the file opens with a correction paragraph naming every model.
    /// The claim lives on one line; assert on that line.
    private func reachesYouLine(for name: String, in notices: String) -> String? {
        for section in notices.components(separatedBy: "\n### ") {
            let heading = String(section.prefix(while: { $0 != "\n" })).lowercased()
            guard heading.contains(name.lowercased()) else { continue }
            return section.split(separator: "\n").map(String.init)
                .first(where: { $0.contains("**How it reaches you:**") })
        }
        return nil
    }

    // MARK: - LICENSE

    /// `LICENSE` must be unmodified MIT. Appending to it made GitHub report the repository as
    /// `NOASSERTION` — "Other" in the sidebar — while the README badge and the site both said
    /// MIT. An MIT project that machine-reads as unlicensed is a real misstatement, and it is
    /// the same defect class as the one being fixed, pointing the other way.
    func testTheLicenceIsUnmodifiedMIT() throws {
        let licence = try read("LICENSE")
        XCTAssertTrue(licence.contains("MIT License"), "LICENSE is not MIT any more")
        XCTAssertTrue(licence.trimmingCharacters(in: .whitespacesAndNewlines)
                        .hasSuffix("DEALINGS IN THE\nSOFTWARE."),
                      "something is appended after the MIT text. Automated licence detection "
                      + "fails on a modified body, so the repo reads as NOASSERTION. Third-"
                      + "party facts belong in THIRD-PARTY-NOTICES.md, which is their one home.")
        for name in try bundledModels().union(DeepSearchLevel.allCases.compactMap(\.modelName)) {
            XCTAssertFalse(licence.contains(name),
                           "LICENSE mentions '\(name)'. A second copy of a fact that lives in "
                           + "THIRD-PARTY-NOTICES.md is exactly how the two drifted apart: the "
                           + "notices were rewritten and LICENSE kept asserting the models were "
                           + "NonCommercial, inside the .app and the DMG.")
        }
    }

    // MARK: - what ships vs what is claimed

    /// Both build paths must bundle the same set, or the DMG and a local build disagree about
    /// what the shipped notices are describing.
    func testTheThreeBuildEntrypointsBundleTheSameModels() throws {
        // build-app.sh's DEFAULT matters as much as the two callers: `make app` inherits it,
        // and a glob-everything default is what once produced a 409 MB .app.
        var seen: [(String, Set<String>)] = []
        for script in ["Scripts/build-app.sh", "Scripts/deploy-local.sh", "Scripts/release.sh"] {
            let assignments = try bundleAssignments(script)
            XCTAssertFalse(assignments.isEmpty,
                           "\(script) declares no BUNDLE_MODELS — either it stopped deciding "
                           + "what to bundle, or this parse is broken and silently passing")
            for a in assignments { seen.append((script, a)) }
        }
        guard let first = seen.first else { return XCTFail("nothing parsed") }
        for (script, set) in seen {
            XCTAssertEqual(set, first.1,
                           "\(script) bundles \(set.sorted()) but \(first.0) bundles "
                           + "\(first.1.sorted()). At most one of them can match what "
                           + "THIRD-PARTY-NOTICES.md says ships.")
        }
    }

    /// Every model actually bundled must be attributed as bundled. This is the obligation
    /// OpenVision failed: it was the only bundled model and the notices omitted it entirely
    /// while crediting two absent models as present.
    func testEveryBundledModelIsAttributed() throws {
        let notices = try read("THIRD-PARTY-NOTICES.md")
        let models = try bundledModels()
        XCTAssertFalse(models.isEmpty, "the bundle list parsed empty — the parse is wrong")
        for model in models {
            // Match the upstream family: two towers are correctly credited by one entry.
            let family = model.split(separator: "-").prefix(2).joined(separator: "-")
            guard let line = reachesYouLine(for: family, in: notices) else {
                XCTFail("'\(model)' is bundled into the .app but THIRD-PARTY-NOTICES.md has no "
                        + "section for '\(family)' with a 'How it reaches you' line. Shipping "
                        + "a third-party model with no attribution is the breach this file "
                        + "exists to prevent.")
                continue
            }
            XCTAssertTrue(line.contains("**BUNDLED.**"),
                          "'\(model)' ships inside the .app, but its notices entry says: "
                          + "\(line.trimmingCharacters(in: .whitespaces))")
        }
    }

    /// A downloaded model must not be described as bundled.
    func testDownloadedModelsAreNotClaimedAsBundled() throws {
        let notices = try read("THIRD-PARTY-NOTICES.md")
        let bundled = Set(try bundledModels().map { $0.lowercased() })
        // Derived from the tiers that actually reach the loader, not a hand-kept list.
        let downloads = DeepSearchLevel.allCases.compactMap(\.modelName)
            .filter { !bundled.contains($0.lowercased()) }
        XCTAssertFalse(downloads.isEmpty, "no downloading tier — the derivation is broken")
        for absent in downloads {
            guard let line = reachesYouLine(for: absent, in: notices) else {
                XCTFail("'\(absent)' is a tier users can select but has no 'How it reaches "
                        + "you' line in THIRD-PARTY-NOTICES.md")
                continue
            }
            XCTAssertFalse(line.contains("**BUNDLED.**"),
                           "'\(absent)' is downloaded after install, not bundled, but the "
                           + "notices credit it as bundled. That is the half of the original "
                           + "defect that made the file look complete while OpenVision — the "
                           + "only model actually inside the .app — went uncredited.")
            XCTAssertTrue(line.contains("NOT bundled"),
                          "'\(absent)' should be stated as NOT bundled: \(line)")
        }
    }

    // MARK: - linked libraries

    /// Apache-2.0 §4(a) requires recipients receive a copy of the licence, and both build
    /// paths must actually put it there.
    func testTheApacheTextExistsAndBothBuildPathsShipIt() throws {
        let text = try read("LICENSE-Apache-2.0.txt")
        // A truncated or placeholder paste would still "contain Apache License" while
        // discharging nothing, so check the structural landmarks and the size.
        for marker in ["Apache License", "Version 2.0, January 2004", "4. Redistribution.",
                       "TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION",
                       "APPENDIX: How to apply the Apache License to your work."] {
            XCTAssertTrue(text.contains(marker),
                          "LICENSE-Apache-2.0.txt is missing '\(marker)' — it is not the "
                          + "complete licence, so it does not satisfy §4(a)")
        }
        XCTAssertGreaterThan(text.utf8.count, 9_000,
                             "LICENSE-Apache-2.0.txt is too short to be the real text")
        for script in ["Scripts/build-app.sh", "Scripts/release.sh"] {
            XCTAssertTrue(try read(script).contains("LICENSE-Apache-2.0.txt"),
                          "\(script) does not ship LICENSE-Apache-2.0.txt, so a recipient gets "
                          + "Apache-2.0 components without their licence text")
        }
    }

    /// Every package resolved into the build must be classified in the notices manifest —
    /// linked (and attributed) or explicitly not linked. Adding a dependency turns this red
    /// until a human decides, which is the point: Jinja was compiled into the binary for
    /// months with its required MIT copyright notice appearing nowhere a user could see.
    func testEveryResolvedDependencyIsClassified() throws {
        struct Resolved: Decodable {
            struct Pin: Decodable { let location: String? ; let repositoryURL: String? }
            struct V2: Decodable { let pins: [Pin] }
            let pins: [Pin]?
        }
        let data = try Data(contentsOf: root.appendingPathComponent("Package.resolved"))
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pins = obj["pins"] as? [[String: Any]] else {
            return XCTFail("Package.resolved has no `pins` array — the format changed")
        }
        let manifest = try read("THIRD-PARTY-NOTICES.md")
        XCTAssertTrue(manifest.contains("distribution-manifest"),
                      "the distribution-manifest block is gone; nothing classifies dependencies")
        for pin in pins {
            let url = (pin["location"] as? String) ?? (pin["repositoryURL"] as? String) ?? ""
            guard !url.isEmpty else { continue }
            let name = url.split(separator: "/").last.map(String.init)?
                          .replacingOccurrences(of: ".git", with: "") ?? url
            XCTAssertTrue(manifest.contains(url) || manifest.contains(name),
                          "'\(name)' is resolved into the build but the distribution-manifest "
                          + "in THIRD-PARTY-NOTICES.md neither lists it as `linked:` (with its "
                          + "licence and copyright) nor as `not-linked:` with a reason. Every "
                          + "linked package is redistributed inside the binary.")
        }
    }

    /// The notices must carry the upstream copyright line for each MIT-licensed linked
    /// package, verbatim. MIT's condition is the notice itself, not a mention of the licence.
    func testLinkedMITPackagesCarryTheirUpstreamCopyright() throws {
        let notices = try read("THIRD-PARTY-NOTICES.md")
        let checkouts = root.appendingPathComponent(".build/checkouts")
        var checked = 0
        for line in try read("THIRD-PARTY-NOTICES.md").split(separator: "\n")
                where line.hasPrefix("linked:") && line.contains("licence: MIT") {
            guard let url = line.split(separator: "|").first?
                    .replacingOccurrences(of: "linked:", with: "")
                    .trimmingCharacters(in: .whitespaces),
                  let name = url.split(separator: "/").last.map(String.init)
            else { continue }
            let upstream = checkouts.appendingPathComponent("\(name)/LICENSE")
            guard let text = try? String(contentsOf: upstream, encoding: .utf8) else {
                // `swift test` resolves and checks out dependencies before running, so an
                // absent checkout is not a state this can legitimately be in. A skip here is
                // how this whole defect class hides, so fail instead.
                XCTFail("\(name) is declared linked but .build/checkouts/\(name)/LICENSE is "
                        + "unreadable — cannot confirm its notice is reproduced")
                continue
            }
            guard let copyright = text.split(separator: "\n")
                    .first(where: { $0.hasPrefix("Copyright") }) else { continue }
            XCTAssertTrue(notices.contains(copyright),
                          "\(name) is MIT and linked into the binary, but its upstream "
                          + "copyright line '\(copyright)' does not appear in THIRD-PARTY-"
                          + "NOTICES.md. MIT requires the notice travel with every copy.")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0,
                             "no linked MIT package was checked — the manifest parse is broken, "
                             + "so this test would pass while attributing nothing")
    }
}
