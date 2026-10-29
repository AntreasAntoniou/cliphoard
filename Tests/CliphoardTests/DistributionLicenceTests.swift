import XCTest
import CryptoKit
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

    /// The `**How it reaches you:**` line of a model's section, and only that line.
    ///
    /// Reading the whole section would be wrong in a way that is easy to miss: the OpenVision
    /// entry's Attribution bullet contains the words "described as bundled" while describing
    /// the exact opposite, and the file opens with a correction paragraph naming every model.
    /// The claim lives on one line; assert on that line.
    ///
    /// Sections are looked up in the VISIBLE text: a `### ` heading plus a BUNDLED line planted
    /// inside the distribution-manifest comment is not a notice a reader can see, and on the
    /// raw text that passed 8/8 with the visible OpenVision section deleted.
    private func reachesYouLine(for name: String, in notices: String) -> String? {
        for section in visible(notices).components(separatedBy: "\n### ") {
            let heading = String(section.prefix(while: { $0 != "\n" })).lowercased()
            guard heading.contains(name.lowercased()) else { continue }
            return section.split(separator: "\n").map(String.init)
                .first(where: { $0.contains("**How it reaches you:**") })
        }
        return nil
    }

    // MARK: - LICENSE

    /// `LICENSE` must be canonical MIT, byte for byte, with only the holder line ours.
    /// Anchoring one end let a withdrawn NC appendix pass when prepended ABOVE "MIT License";
    /// a hash of the body with line 3 masked catches an edit anywhere, and the same constant
    /// is pinned in Scripts/verify-bundle.sh, the only guard on the CI release path.
    /// Appending to it made GitHub report the repository as `NOASSERTION` — "Other" in the
    /// sidebar — while the README badge and the site both said MIT.
    static let mitBodySHA256 = "ac483bb6267e16aac1620af5d09a1ccd94c3bbab762ac1b3ee391fe18021deae"

    func testTheLicenceIsUnmodifiedMIT() throws {
        let licence = try read("LICENSE")
        XCTAssertTrue(licence.hasPrefix("MIT License\n\nCopyright (c) "),
                      "LICENSE does not START with the MIT header — something was prepended")
        XCTAssertTrue(licence.hasSuffix("DEALINGS IN THE\nSOFTWARE.\n"),
                      "something is appended after the MIT text")
        var lines = licence.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 22,
                       "canonical MIT is 21 lines plus a trailing newline, got \(lines.count - 1) lines")
        XCTAssertEqual(licence.utf8.count, 1073,
                       "canonical MIT with our holder line is 1073 bytes, got \(licence.utf8.count)")
        guard lines.count > 3 else { return XCTFail("LICENSE is too short to be MIT") }
        XCTAssertNotNil(lines[2].range(of: #"^Copyright \(c\) \d{4} Antreas Antoniou$"#,
                                       options: .regularExpression),
                        "line 3 is not the plain single-year copyright line: '\(lines[2])' — a "
                        + "range would break the 1073-byte pin above; Scripts/verify-bundle.sh "
                        + "enforces the same rule")
        lines[2] = "@HOLDER@"
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, Self.mitBodySHA256,
                       "LICENSE body is not canonical MIT (masked-holder sha256 \(digest)). "
                       + "Third-party facts belong in THIRD-PARTY-NOTICES.md, which is their "
                       + "one home; a modified body also makes GitHub read the repo as "
                       + "NOASSERTION. Compare: diff LICENSE .build/checkouts/Jinja/LICENSE")
        for name in DeepSearchLevel.allCases.compactMap(\.modelName) {
            XCTAssertFalse(licence.contains(name),
                           "LICENSE mentions '\(name)'. A second copy of a fact that lives in "
                           + "THIRD-PARTY-NOTICES.md is exactly how the two drifted apart: the "
                           + "notices were rewritten and LICENSE kept asserting the models were "
                           + "NonCommercial, inside the .app and the DMG.")
        }
    }

    // MARK: - what ships vs what is claimed

    /// Future builds cannot restore, compile or embed weights from a developer cache.
    func testBuildEntrypointsRequireModelWeightFreeBundles() throws {
        for script in ["Scripts/build-app.sh", "Scripts/build-mas.sh"] {
            let executable = try code(script).joined(separator: "\n")
            XCTAssertTrue(executable.contains("audit-no-models.py"))
            XCTAssertTrue(executable.contains("--check-environment"))
            XCTAssertFalse(executable.contains("coremlcompiler"))
            XCTAssertFalse(executable.contains("embed-media-model.sh"))
            XCTAssertFalse(executable.contains("tools/models"))
        }
        for script in ["Scripts/release.sh", "Scripts/deploy-local.sh"] {
            let executable = try code(script).joined(separator: "\n")
            XCTAssertFalse(executable.contains("restore-models.sh"))
            XCTAssertFalse(executable.contains("BUNDLE_MODELS="))
            XCTAssertTrue(executable.contains("build-app.sh"))
        }
        XCTAssertTrue(try code("Scripts/verify-bundle.sh").joined(separator: "\n")
            .contains("audit-no-models.py"))
    }

    /// A downloaded model must not be described as bundled.
    func testDownloadedModelsAreNotClaimedAsBundled() throws {
        let notices = try read("THIRD-PARTY-NOTICES.md")
        // Derived from the tiers that actually reach the loader, not a hand-kept list.
        let downloads = DeepSearchLevel.allCases.compactMap(\.modelName)
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

    /// The canonical apache.org LICENSE-2.0.txt, byte for byte; Scripts/verify-bundle.sh pins
    /// the same constant (APACHE_SHA256) on the CI path, where this test never runs.
    static let apacheSHA256 = "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"

    private func sha256hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
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
        XCTAssertEqual(sha256hex(text), Self.apacheSHA256,
                       "LICENSE-Apache-2.0.txt is not the canonical apache.org LICENSE-2.0.txt "
                       + "(sha256 \(sha256hex(text))) — a reflowed or edited copy is not the licence")
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
        // Only the `linked:` / `not-linked:` lines INSIDE the distribution-manifest comment
        // classify anything. Matching the whole file let a deleted manifest line pass because
        // the package's name (and URL) still appeared in its visible `### ` section.
        let classified = Set(manifestLines(in: manifest).map { normalisedURL(manifestURL($0)) })
        XCTAssertFalse(classified.isEmpty,
                       "the distribution-manifest comment parsed no linked:/not-linked: lines — "
                       + "the block is gone or the parse is broken, so nothing classifies dependencies")
        for pin in pins {
            let url = (pin["location"] as? String) ?? (pin["repositoryURL"] as? String) ?? ""
            guard !url.isEmpty else { continue }
            XCTAssertTrue(classified.contains(normalisedURL(url)),
                          "'\(url)' is resolved into the build but no `linked:` / `not-linked:` line "
                          + "INSIDE the distribution-manifest comment of THIRD-PARTY-NOTICES.md names "
                          + "it — a mention in a visible heading is not a classification. Every "
                          + "linked package is redistributed inside the binary.")
        }
    }

    /// What a READER sees: the notices with HTML comments removed. The distribution manifest
    /// lives inside one and carries the same copyright lines as the visible sections, so a
    /// raw `contains` on the whole file stayed green with an entire visible section deleted.
    private func visible(_ markdown: String) -> String {
        markdown.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "",
                                      options: .regularExpression)
    }

    /// The `linked:` / `not-linked:` lines INSIDE `<!-- distribution-manifest … -->`, and only
    /// those. Matching names anywhere in the file is how deleting Jinja's manifest line stayed
    /// green: "Jinja" still appeared in its visible heading.
    private func manifestLines(in markdown: String) -> [String] {
        guard let open = markdown.range(of: "<!-- distribution-manifest"),
              let close = markdown.range(of: "-->", range: open.upperBound..<markdown.endIndex)
        else { return [] }
        return markdown[open.upperBound..<close.lowerBound].split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("linked:") || $0.hasPrefix("not-linked:") }
    }

    /// The URL of a manifest line: between the first `:` and the first `|`.
    private func manifestURL(_ line: String) -> String {
        let afterKey = line.drop(while: { $0 != ":" }).dropFirst()
        let url = afterKey.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return String(url).trimmingCharacters(in: .whitespaces)
    }

    /// Package.resolved and the manifest may differ by `.git`, a trailing slash, or case only.
    private func normalisedURL(_ url: String) -> String {
        var u = url.trimmingCharacters(in: .whitespaces).lowercased()
        while u.hasSuffix("/") { u.removeLast() }
        if u.hasSuffix(".git") { u.removeLast(4) }
        return u
    }

    /// The visible `### <name>` section body: from its heading to the next `##`/`###` heading.
    private func visibleSection(named name: String, in markdown: String) -> String? {
        for part in visible(markdown).components(separatedBy: "\n### ").dropFirst() {
            let heading = String(part.prefix(while: { $0 != "\n" }))
            guard heading.lowercased().contains(name.lowercased()) else { continue }
            return part.components(separatedBy: "\n## ").first ?? part
        }
        return nil
    }

    /// Each MIT-licensed linked package must have its upstream LICENSE reproduced verbatim in
    /// the VISIBLE part of the notices, inside its own section. MIT's condition is the
    /// copyright notice AND the permission notice, not a mention of the licence.
    func testLinkedMITPackagesReproduceTheirUpstreamLicenceVisibly() throws {
        let notices = try read("THIRD-PARTY-NOTICES.md")   // manifest lines are INSIDE the comment: parse the raw file
        let checkouts = root.appendingPathComponent(".build/checkouts")
        var checked = 0
        for line in notices.split(separator: "\n")
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
            guard let section = visibleSection(named: name, in: notices) else {
                XCTFail("\(name) is MIT and linked into the binary, but THIRD-PARTY-NOTICES.md "
                        + "has no VISIBLE '### \(name)' section — a line inside the manifest "
                        + "HTML comment is not a notice a reader can see")
                continue
            }
            XCTAssertTrue(section.contains(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                          "\(name)'s visible section does not reproduce its upstream LICENSE "
                          + "verbatim (copyright line, permission paragraph and warranty). MIT "
                          + "requires the notice travel with every copy.")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0,
                             "no linked MIT package was checked — the manifest parse is broken, "
                             + "so this test would pass while attributing nothing")
    }

    func testReleaseDoesNotRestoreModelWeights() throws {
        for script in ["Scripts/release.sh", ".github/workflows/release.yml"] {
            let executable = try code(script).joined(separator: "\n")
            XCTAssertFalse(executable.contains("restore-models.sh"))
            XCTAssertFalse(executable.contains("tools/models"))
        }
    }

    // MARK: - CLIPTextMean provenance

    /// `CLIPTextMean.vector` is a transcription of `text_mean` in the OpenVision manifest that
    /// ships inside the pinned openvision-tiny-p8.zip. The generator that produced it was never
    /// committed, so the manifest is its only provenance; if the two ever disagree, the wrong
    /// mean is being subtracted from every query — and that is worse than none.
    func testCLIPTextMeanIsTheManifestTextMean() throws {
        let url = root.appendingPathComponent("tools/models/openvision-tiny-p8-manifest.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("tools/models/openvision-tiny-p8-manifest.json is absent (gitignored); "
                          + "restore it with: MODELS=\"openvision-tiny-p8-text\" bash tools/restore-models.sh")
        }
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        guard let mean = obj?["text_mean"] as? [Double] else {
            return XCTFail("the manifest has no numeric `text_mean` array")
        }
        XCTAssertEqual(mean.count, 192, "the manifest's text_mean is not 192-d")
        XCTAssertEqual(CLIPTextMean.vector.count, mean.count)
        for (i, pair) in zip(mean, CLIPTextMean.vector).enumerated() {
            XCTAssertEqual(Float(pair.0), pair.1, accuracy: 1e-7,
                           "CLIPTextMean.vector[\(i)] = \(pair.1) but the manifest's text_mean[\(i)] = "
                           + "\(pair.0) — the constant no longer matches the weights it was measured on")
        }
    }

    /// The shipped tokenizer config.json says `vocab_size: 32000` while the WordPiece vocab has
    /// 30,522 entries — recorded and deferred (fixing it re-pins the zip). That is harmless
    /// ONLY while nothing reads the field. swift-transformers 0.1.24 does not; a bump that
    /// starts to must turn this red so the deferral is revisited, not silently inherited.
    func testSwiftTransformersNeverReadsVocabSize() throws {
        let sources = root.appendingPathComponent(".build/checkouts/swift-transformers/Sources")
        guard let e = FileManager.default.enumerator(atPath: sources.path) else {
            return XCTFail("\(sources.path) is unreadable — swift test resolves checkouts first, "
                           + "so this is not a legitimate state")
        }
        var swiftFiles = 0
        var hits: [String] = []
        for case let rel as String in e where rel.hasSuffix(".swift") {
            swiftFiles += 1
            let text = try String(contentsOf: sources.appendingPathComponent(rel), encoding: .utf8)
            if text.contains("vocab_size") || text.contains("vocabSize") { hits.append(rel) }
        }
        XCTAssertGreaterThan(swiftFiles, 10,
                             "too few Swift files under swift-transformers/Sources — the checkout is "
                             + "absent or the layout moved, so this test proves nothing")
        XCTAssertTrue(hits.isEmpty,
                      "swift-transformers now reads vocab_size in \(hits) — re-convert OpenVision with "
                      + "vocab_size 30522 (tools/convert_openvision.py), re-pack, re-upload, and re-pin "
                      + "OPENVISION_ZIP_SHA256 + TOKENIZER_CONFIG_SHA256")
    }
}
