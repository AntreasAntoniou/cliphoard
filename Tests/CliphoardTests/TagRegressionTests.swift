import XCTest
@testable import Cliphoard

/// Regressions for defects the Wave-1 adversary found in the shipped detector /
/// derived-tag modules. Each test below corresponds to a concrete false positive
/// or hot-path hazard that survived both implementers AND the verifier — they are
/// the reason the refutation stage exists, so they get permanent tests.
final class TagRegressionTests: XCTestCase {

    private func clip(_ text: String, kind: ClipKind = .text) -> ClipItem {
        ClipItem(kind: kind, text: text)
    }

    // MARK: Shape — hex identifiers are not colours

    /// `isColor` accepted an unhashed hex run containing a letter, so abbreviated
    /// git SHAs (`deadbeef`, `a1b2c3d4`, `cafebabe`) were tagged `color` — a chip
    /// whose glance-action ("this is a colour") is simply wrong.
    func testAbbreviatedGitShasAreNotColours() {
        for sha in ["deadbeef", "cafebabe", "a1b2c3d4", "fff000", "abc123"] {
            XCTAssertNotEqual(Detectors.scan(text: sha, kind: .text, sourceApp: nil).shape, "color",
                              "\(sha) is a hex identifier, not a colour")
        }
    }

    /// A real colour still classifies — the `#` is what makes the claim honest.
    func testHashedColoursStillClassify() {
        for colour in ["#fff", "#1a2b3c", "#AABBCCDD"] {
            XCTAssertEqual(Detectors.scan(text: colour, kind: .text, sourceApp: nil).shape, "color")
        }
    }

    // MARK: Hot path — the detector pass must stay linear

    /// The pass runs synchronously on every copy, BEFORE persistence, so a
    /// quadratic blow-up freezes the clipboard. The original phone/financial
    /// overlap check was O(runs x claimed); this asserts scaling, not wall-clock,
    /// so it cannot flake on a loaded machine: 4x the input must not cost ~16x.
    func testDetectorScanScalesLinearlyOnAdversarialInput() {
        func elapsed(cards: Int) -> Double {
            let text = Array(repeating: "4111 1111 1111 1111", count: cards).joined(separator: " ")
            let start = Date()
            _ = Detectors.scan(text: text, kind: .text, sourceApp: nil)
            return Date().timeIntervalSince(start)
        }
        _ = elapsed(cards: 50)                       // warm up
        let small = max(elapsed(cards: 250), 0.0005) // floor avoids divide-by-noise
        let large = elapsed(cards: 1000)             // 4x the input
        XCTAssertLessThan(large / small, 8.0,
                          "4x input cost \(large / small)x time — the pass is super-linear again")
    }

    // MARK: Link disposition — no citing a lookalike or a cache-buster

    /// A DOI-shaped cache-buster in a URL query (`app.min.js?v=10.1234/x`) was
    /// tagged `reference`, i.e. "go cite this minified asset".
    func testDoiInsideAUrlQueryIsNotAReference() {
        let item = clip("https://cdn.example.com/app.min.js?v=10.1234/x", kind: .link)
        XCTAssertNotEqual(DerivedTags.linkDisposition(item), "reference")
    }

    /// A genuine DOI still counts.
    func testRealDoiIsStillAReference() {
        let item = clip("https://doi.org/10.1038/nature12373", kind: .link)
        XCTAssertEqual(DerivedTags.linkDisposition(item), "reference")
    }

    /// Host matching must be on label boundaries: `pubmed.evil.com` is not PubMed.
    func testLookalikeReferenceHostsAreRejected() {
        for url in ["https://pubmed.evil.com/article",
                    "https://doi.org.evil.com/10.1038/x",
                    "https://arxiv.org.attacker.net/abs/1234"] {
            XCTAssertNotEqual(DerivedTags.linkDisposition(clip(url, kind: .link)), "reference",
                              "\(url) impersonates a reference host")
        }
    }

    // MARK: The veto must hold at SEARCH time, not just at capture

    /// Wave-2's worst defect: every ranker fell back to
    /// `embeddings[...] ?? embedder.embed(searchText(item))`. Because the veto
    /// REMOVES a secret's vector, that fallback inverted it — instead of the
    /// secret going through the model once at capture, it went through on EVERY
    /// query. A vetoed clip must never be embedded here.
    @MainActor
    func testSearchNeverEmbedsAVetoedClip() {
        /// Records any text it is asked to embed, so the test can prove the
        /// ranker never handed the secret to a model.
        final class SpyEmbedder: TextEmbedder {
            let dimension = 256
            let signature = "spy-256"
            let relevanceFloor: Float = 0
            var embedded: [String] = []
            func embed(_ text: String) -> [Float] {
                embedded.append(text)
                return HashingEmbedder().embed(text)
            }
        }
        let secretText = "AKIAIOSFODNN7EXAMPLE super secret credential"
        let secret = ClipItem(kind: .text, text: secretText)
        secret.flags = [.secret]
        XCTAssertTrue(secret.isIndexVetoed, "precondition: this clip is vetoed")
        let benign = ClipItem(kind: .text, text: "ordinary note about groceries")

        for mode in ["smart", "neural"] {
            let spy = SpyEmbedder()
            _ = mode == "smart"
                ? SemanticRanker.smart(query: "credential", items: [secret, benign], embedder: spy)
                : SemanticRanker.neural(query: "credential", items: [secret, benign], embedder: spy)
            XCTAssertFalse(spy.embedded.contains(secretText),
                           "\(mode) sent the vetoed clip's text through the model")
        }
    }

    // MARK: The invariant that must never regress

    /// Design principle 3: no detector may ever emit a positive safe/public
    /// label. Absence of a badge is the only honest signal, because nothing here
    /// can prove a clip is safe.
    func testNoPositiveSafeLabelExists() {
        let benign = Detectors.scan(text: "just some ordinary prose", kind: .text, sourceApp: nil)
        XCTAssertTrue(benign.flags.isEmpty, "nothing should fire on benign prose")
        for (name, _) in ClipFlags.allKnown {
            for banned in ["safe", "public", "clean", "benign", "trusted"] {
                XCTAssertFalse(name.contains(banned), "flag \(name) asserts safety, which cannot be proven")
            }
        }
    }
}
