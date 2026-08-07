import XCTest
@testable import Cliphoard

/// The hardened light-learning suggestion gate (spec §3.10): margin-over-next,
/// evidence-before-centroid, and per-embedder floor calibration.
///
/// The failure these tests exist to prevent is the one the real-clip audit
/// found: an absolute cosine floor near 0.4 sits inside the flattening zone
/// where a 300M model separated labels no better than an 8.9M one, so an
/// absolute floor ALONE turns "which of your labels is this?" into a coin flip.
final class SuggestionGateTests: XCTestCase {
    private let signature = "gate-test-v1"

    /// A clip whose vector is `v` (L2-normalised), in `space`.
    private func clip(_ v: [Float], tags: [String] = [], space: String? = nil) -> ClipItem {
        let item = ClipItem(kind: .text, text: "clip \(UUID().uuidString.prefix(4))")
        item.userTags = ClipItem.normalizedUserTags(tags)
        item.embeddings[space ?? signature] =
            ModelEmbedding(vector: HashingEmbedder.normalize(v))
        return item
    }

    /// `n` members whose shared vector has exactly `cosine` with `[1, 0, 0]`.
    private func members(cosine c: Float, _ n: Int, space: String? = nil) -> [ClipItem] {
        let v: [Float] = [c, (1 - c * c).squareRoot(), 0]
        return (0..<n).map { _ in clip(v, space: space) }
    }

    private func suggest(for subject: ClipItem,
                         _ index: [String: [ClipItem]],
                         minApplies: Int = 4,
                         embedderRelevanceFloor: Float? = nil,
                         sigma: Float? = nil,
                         margin: Float = SemanticRanker.suggestionMargin,
                         space: String? = nil) -> [String] {
        SemanticRanker.suggestedUserTags(
            for: subject, userTagIndex: index, dismissed: [],
            embedderSignature: space ?? signature, minApplies: minApplies,
            embedderRelevanceFloor: embedderRelevanceFloor, sigma: sigma, margin: margin)
    }

    // MARK: - Margin over next-best

    /// THE core case: two centroids the model cannot tell apart. Both clear the
    /// absolute floor comfortably; neither is meaningfully closer. Blank is the
    /// only honest answer — and the old absolute-floor-only gate would have
    /// confidently offered the arbitrary winner of a 0.02 difference.
    func testNearTiedCentroidsProduceNoSuggestion() {
        let subject = clip([1, 0, 0])
        let index: [String: [ClipItem]] = [
            "invoices": members(cosine: 0.72, 4),
            "receipts": members(cosine: 0.70, 4),
        ]
        XCTAssertEqual(suggest(for: subject, index), [],
                       "a 0.02 gap is inside the margin — the pair is confusable, so nothing ships")
    }

    /// A confusable pair also poisons everything ranked below it: nothing under
    /// a coin flip is more trustworthy than the coin flip itself.
    func testConfusablePairAlsoSuppressesWeakerCandidatesBelowIt() {
        let subject = clip([1, 0, 0])
        let index: [String: [ClipItem]] = [
            "invoices": members(cosine: 0.90, 4),
            "receipts": members(cosine: 0.88, 4),
            "ledger":   members(cosine: 0.60, 4),   // clears the floor on its own
        ]
        XCTAssertEqual(suggest(for: subject, index), [])
    }

    /// The gate is not simply "off": a genuinely separated winner still ships,
    /// and so does a runner-up that is itself well separated.
    func testClearWinnerStillSuggests() {
        let subject = clip([1, 0, 0])
        let index: [String: [ClipItem]] = [
            "invoices": members(cosine: 0.95, 4),
            "recipes":  members(cosine: 0.60, 4),
        ]
        XCTAssertEqual(suggest(for: subject, index), ["invoices", "recipes"],
                       "0.35 apart: mutually distinguishable, both offered, strongest first")
    }

    /// Documented decision: the bottom-ranked candidate has no next-best to be
    /// confused with, so a single tag over the floor is suggested on the floor
    /// alone — the margin measures competition, and here there is none.
    func testSingleCandidateOverTheFloorStillSuggests() {
        let subject = clip([1, 0, 0])
        let index: [String: [ClipItem]] = [
            "invoices": members(cosine: 0.60, 4),
            "recipes":  members(cosine: 0.05, 4),   // nowhere near the floor: not a candidate
        ]
        XCTAssertEqual(suggest(for: subject, index), ["invoices"])
    }

    /// Raising the margin suppresses a tag that the default margin would offer —
    /// the knob genuinely controls the confusability bar.
    func testRaisingMarginSuppressesAPreviouslySuggestedTag() {
        let subject = clip([1, 0, 0])
        let index: [String: [ClipItem]] = [
            "invoices": members(cosine: 0.80, 4),
            "receipts": members(cosine: 0.70, 4),
        ]
        XCTAssertEqual(suggest(for: subject, index).first, "invoices",
                       "0.10 apart clears the default 0.05 margin")
        XCTAssertEqual(suggest(for: subject, index, margin: 0.20), [],
                       "a stricter margin calls the same pair confusable")
    }

    /// A zero or negative margin is the absolute-floor-only gate the audit
    /// condemned; it must not be a back door to that behaviour.
    func testNonPositiveMarginFallsBackToTheDefaultInsteadOfDisablingTheGate() {
        let subject = clip([1, 0, 0])
        let index: [String: [ClipItem]] = [
            "invoices": members(cosine: 0.70, 4),
            "receipts": members(cosine: 0.70, 4),   // exactly tied: the worst case
        ]
        XCTAssertEqual(suggest(for: subject, index, margin: 0), [])
        XCTAssertEqual(suggest(for: subject, index, margin: -1), [])
    }

    // MARK: - Evidence before centroid

    /// Three hand-applies is not a learned label, whatever its centroid says.
    func testThreeApplyTagNeverSuggests() {
        let subject = clip([1, 0, 0])
        let index: [String: [ClipItem]] = ["invoices": members(cosine: 1.0, 3)]
        XCTAssertEqual(suggest(for: subject, index), [],
                       "3 < minApplies 4 — a perfect cosine cannot buy the missing sample")
        XCTAssertEqual(suggest(for: subject, index, minApplies: 3), ["invoices"],
                       "…and the bar is the only thing stopping it")
    }

    /// The evidence bar counts votes that can actually be compared: four applies
    /// of which two live in another space is two samples HERE, not four.
    func testAppliesInAnotherSpaceDoNotCountTowardTheEvidenceBar() {
        let subject = clip([1, 0, 0])
        let here = members(cosine: 1.0, 2)
        let elsewhere = members(cosine: 1.0, 2, space: "some-other-space-v1")
        XCTAssertEqual(suggest(for: subject, ["invoices": here + elsewhere]), [],
                       "only 2 comparable vectors — no centroid forms")
        XCTAssertEqual(suggest(for: subject, ["invoices": here + members(cosine: 1.0, 2)]),
                       ["invoices"], "4 comparable vectors clear the same bar")
    }

    // MARK: - Per-embedder floor calibration

    /// The floor travels with the space. The same 0.62 cosine is a confident
    /// match in the 1024-d ogma head (noise p95 ≈ 0.40) and pure ambient
    /// similarity in the 384-d head (noise p95 ≈ 0.58) — which is exactly why a
    /// hard-coded 0.45 was wrong in both directions.
    func testFloorIsCalibratedPerEmbeddingSpace() {
        let full = "open-ogma-small-1024-v1"
        let compact = "open-ogma-micro-384-v1"
        XCTAssertEqual(SemanticRanker.calibratedRelevanceFloor(forSignature: full),
                       VectorDetail.full1024.relevanceFloor, accuracy: 0.001)
        XCTAssertEqual(SemanticRanker.calibratedRelevanceFloor(forSignature: compact),
                       VectorDetail.compact384.relevanceFloor, accuracy: 0.001)
        XCTAssertGreaterThan(SemanticRanker.suggestionFloor(relevanceFloor:
                                VectorDetail.compact384.relevanceFloor),
                             SemanticRanker.suggestionFloor(relevanceFloor:
                                VectorDetail.full1024.relevanceFloor))

        let subjectFull = clip([1, 0, 0], space: full)
        let subjectCompact = clip([1, 0, 0], space: compact)
        XCTAssertEqual(suggest(for: subjectFull,
                               ["invoices": members(cosine: 0.62, 4, space: full)], space: full),
                       ["invoices"], "0.62 is well clear of the 1024-d head's noise")
        XCTAssertEqual(suggest(for: subjectCompact,
                               ["invoices": members(cosine: 0.62, 4, space: compact)], space: compact),
                       [], "the same number is ambient similarity in the 384-d head")
    }

    /// The HF tiers calibrate differently again, and an unknown signature keeps
    /// the historical hashing calibration rather than silently going dark.
    func testKnownHFTiersAndUnknownSignaturesResolveSensibly() {
        XCTAssertEqual(SemanticRanker.calibratedRelevanceFloor(forSignature: "all-MiniLM-L6-v2-384-v1"),
                       DeepSearchLevel.high.hfRelevanceFloor, accuracy: 0.001)
        XCTAssertEqual(SemanticRanker.calibratedRelevanceFloor(forSignature: "embeddinggemma-300m-768-v1"),
                       DeepSearchLevel.max.hfRelevanceFloor, accuracy: 0.001)
        XCTAssertEqual(SemanticRanker.calibratedRelevanceFloor(forSignature: "hashing-256"),
                       0.20, accuracy: 0.001)
        XCTAssertEqual(SemanticRanker.calibratedRelevanceFloor(forSignature: "who-knows"),
                       0.20, accuracy: 0.001)
        // …and that legacy calibration still lands on the historical 0.45-ish floor.
        XCTAssertEqual(SemanticRanker.suggestionFloor(relevanceFloor: 0.20), 0.44, accuracy: 0.01)
    }

    /// A caller holding a live embedder passes its floor directly; an explicit
    /// sigma still overrides everything.
    func testExplicitFloorAndSigmaOverrideTheCalibration() {
        let subject = clip([1, 0, 0])
        let index: [String: [ClipItem]] = ["invoices": members(cosine: 0.60, 4)]
        XCTAssertEqual(suggest(for: subject, index), ["invoices"])
        XCTAssertEqual(suggest(for: subject, index, embedderRelevanceFloor: 0.58), [],
                       "a stricter space's floor rejects the same cosine")
        XCTAssertEqual(suggest(for: subject, index, embedderRelevanceFloor: 0.58, sigma: 0.5),
                       ["invoices"], "an explicit sigma wins over the derived floor")
    }

    // MARK: - Preserved behaviour

    /// Everything the gate protected before: cap at 3, dismissals, tags already
    /// on the clip, and no auto-apply (the function only ever returns names).
    func testPreservesCapDismissalsAndCarriedTags() {
        let subject = clip([1, 0, 0], tags: ["carried"])
        let index: [String: [ClipItem]] = [
            "a":         members(cosine: 0.98, 4),
            "b":         members(cosine: 0.88, 4),
            "c":         members(cosine: 0.78, 4),
            "d":         members(cosine: 0.68, 4),   // over the floor, past the cap
            "carried":   members(cosine: 1.0, 4),
            // Well clear of every offerable tag, so this exercises the exclusion
            // rule rather than the confusability rule (which owns its own test).
            "dismissed": members(cosine: 0.50, 4),
        ]
        let dismissed: Set<String> = [
            SemanticRanker.dismissalKey(tag: "dismissed", clipID: subject.id)
        ]
        let suggested = SemanticRanker.suggestedUserTags(
            for: subject, userTagIndex: index, dismissed: dismissed,
            embedderSignature: signature)
        XCTAssertEqual(suggested, ["a", "b", "c"],
                       "strongest first, capped at 3, carried + dismissed excluded")
        XCTAssertEqual(subject.userTags, ["carried"], "suggestions are never auto-applied")
    }

    /// A dismissal is a judgement about the CONCEPT, so it must veto a near-twin.
    /// Otherwise "no, not `invoices`" silently becomes "how about `receipts`?" —
    /// the leak the Wave-2 adversary proved against the first implementation,
    /// which filtered dismissed tags out before the margin was ever measured.
    func testDismissingATagAlsoSuppressesItsNearTwin() {
        let subject = clip([1, 0, 0])
        let index: [String: [ClipItem]] = [
            "invoices": members(cosine: 0.92, 4),
            "receipts": members(cosine: 0.90, 4),   // within the 0.05 margin
        ]
        let dismissed: Set<String> = [
            SemanticRanker.dismissalKey(tag: "invoices", clipID: subject.id)
        ]
        XCTAssertEqual(SemanticRanker.suggestedUserTags(
            for: subject, userTagIndex: index, dismissed: dismissed,
            embedderSignature: signature), [],
            "the dismissed tag's twin must not be promoted in its place")
    }

    /// A tag already on the clip is NOT confusability evidence: the user resolved
    /// that label, and a second related label is extra information, not a near-tie.
    func testACarriedTagDoesNotSuppressRelatedSuggestions() {
        let subject = clip([1, 0, 0], tags: ["carried"])
        let index: [String: [ClipItem]] = [
            "carried": members(cosine: 1.0, 4),
            "related": members(cosine: 0.97, 4),   // would be a "tie" with carried
        ]
        XCTAssertEqual(SemanticRanker.suggestedUserTags(
            for: subject, userTagIndex: index, dismissed: [],
            embedderSignature: signature), ["related"])
    }
}
