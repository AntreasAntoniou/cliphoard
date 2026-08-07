import XCTest
@testable import Cliphoard

/// Spec §5 — the τ confidence floor on automatic tag assignment, the topical
/// tail of the hybrid basket, and the light-learning user-tag suggestions.

/// Deterministic embedder over a KNOWN vocabulary: every listed string gets its
/// own basis vector (so cosine is exactly 1 with itself and exactly 0 with every
/// other tag), and anything unknown lands in a private slot orthogonal to all of
/// them. That makes the threshold assertions exact rather than approximate.
private struct BasisEmbedder: TextEmbedder {
    let vocabulary: [String]
    var dimension: Int { vocabulary.count + 1 }
    let signature = "basis-tags-v1"

    func embed(_ text: String) -> [Float] {
        var v = [Float](repeating: 0, count: dimension)
        v[vocabulary.firstIndex(of: text) ?? vocabulary.count] = 1
        return v
    }
}

@MainActor
final class TagTauTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TagBaskets.activeID = "general"
        // τ has to be exercised on a basket that still HAS axes. Wave 4 retired
        // General's four abstract ones (design §4), so the Developer overlay —
        // Artifact on ids 0..<8, Language on 8..<16 — supplies the axis leg while
        // General supplies the topical tail. The behaviour under test (the
        // confidence floor) is unchanged; only where the axes live moved.
        TagBaskets.overlayID = "dev"
        UserDefaults.standard.removeObject(forKey: "tagAssignmentThreshold")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "tagAssignmentThreshold")
        TagBaskets.overlayID = nil
        super.tearDown()
    }

    private func embedder() -> BasisEmbedder { BasisEmbedder(vocabulary: TagSpace.names) }

    /// The lowest id on axis `d` whose WORD occurs exactly once in the basket.
    /// `BasisEmbedder` keys on the word, so a word that also appears in the
    /// topical tail (e.g. "code") would give two ids the same vector and make the
    /// range-restriction assertions ambiguous rather than wrong.
    private func uniqueAxisTag(onDimension d: Int) -> Int {
        let counts = TagSpace.names.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return TagSpace.range(ofDimension: d).first { counts[TagSpace.names[$0]] == 1 }!
    }

    /// A vector orthogonal to the whole taxonomy earns NOTHING under τ — no axis
    /// argmax is manufactured, and no topical tag either.
    func testWeakVectorEarnsNoAxisOrTopicalTagsUnderTau() {
        let e = embedder()
        let weak = e.embed("a string that is in no basket")   // the private slot
        XCTAssertTrue(TagSpace.classifyDimensions(weak, embedder: e, tau: 0.5).isEmpty,
                      "an unconfident axis contributes no tag")
        XCTAssertTrue(TagSpace.classifyTopical(weak, embedder: e, topK: 3, tau: 0.5).isEmpty,
                      "an unconfident topical match contributes no tag")
        XCTAssertTrue(ClipIndexer.tags(for: weak, embedder: e).isEmpty,
                      "the assignment path leaves a meaningless clip untagged")
    }

    /// A vector that IS one of the axis tags clears τ and yields exactly that
    /// argmax — the other axes stay blank because it has no opinion there.
    func testStrongVectorYieldsTheArgmaxOnItsOwnAxis() {
        let e = embedder()
        let axisTag = uniqueAxisTag(onDimension: 1)
        let strong = e.embed(TagSpace.names[axisTag])
        XCTAssertEqual(TagSpace.classifyDimensions(strong, embedder: e, tau: 0.5), [axisTag])
    }

    /// The topical leg searches the topical tail ONLY, and gates it on τ.
    func testTopicalClassificationIsThresholdedAndRangeRestricted() {
        let e = embedder()
        let topicalTag = TagSpace.topicalRange.lowerBound
        let strong = e.embed(TagSpace.names[topicalTag])
        XCTAssertEqual(TagSpace.classifyTopical(strong, embedder: e, topK: 3, tau: 0.5), [topicalTag])

        // An AXIS word must never come back from the topical leg.
        let axisVector = e.embed(TagSpace.names[uniqueAxisTag(onDimension: 0)])
        XCTAssertTrue(TagSpace.classifyTopical(axisVector, embedder: e, topK: 3, tau: 0.5).isEmpty,
                      "axis vocabulary can't win a topical slot")
    }

    /// The assignment path carries thresholded AXIS tags plus thresholded
    /// TOPICAL tags — the two legs are merged, not one-or-the-other.
    func testAssignmentMergesAxisAndTopicalTags() {
        let e = embedder()
        let axisTag = uniqueAxisTag(onDimension: 0)
        let topicalTag = TagSpace.topicalRange.lowerBound
        // Halfway between one axis tag and one topical tag: cosine ≈ 0.707 with
        // each (comfortably over the 0.28 default τ), 0 with everything else.
        var mixed = [Float](repeating: 0, count: e.dimension)
        mixed[axisTag] = 1; mixed[topicalTag] = 1
        mixed = HashingEmbedder.normalize(mixed)

        let assigned = ClipIndexer.tags(for: mixed, embedder: e)
        XCTAssertTrue(assigned.contains(axisTag), "axis leg contributes")
        XCTAssertTrue(assigned.contains(topicalTag), "topical leg contributes")
        XCTAssertLessThanOrEqual(assigned.count, TagSpace.dimensionCount + 3)
    }

    /// Raising τ tightens assignment; the same vector that earned tags at the
    /// default earns none once τ sits above its cosine.
    func testRaisingTauSuppressesMarginalAssignments() {
        let e = embedder()
        let axisTag = uniqueAxisTag(onDimension: 0)
        let topicalTag = TagSpace.topicalRange.lowerBound
        var mixed = [Float](repeating: 0, count: e.dimension)
        mixed[axisTag] = 1; mixed[topicalTag] = 1
        mixed = HashingEmbedder.normalize(mixed)   // ≈0.707 to each

        XCTAssertFalse(ClipIndexer.tags(for: mixed, embedder: e).isEmpty)
        TagSpace.assignmentThreshold = 0.9
        XCTAssertTrue(ClipIndexer.tags(for: mixed, embedder: e).isEmpty,
                      "a floor above the clip's best cosine leaves it untagged")
    }

    /// A brutal confidence floor keeps only the perfect (cosine 1) match — both
    /// the query-side classify and the assignment path gate on the same knob.
    func testHighFloorKeepsOnlyThePerfectMatch() {
        let e = embedder()
        // A tag whose NAME is unique in the basket, so its basis vector belongs
        // to exactly one id (some vocabulary repeats across axes/topical).
        let counts = TagSpace.names.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        let id = TagSpace.names.firstIndex { counts[$0] == 1 }!
        let strong = e.embed(TagSpace.names[id])
        TagSpace.assignmentThreshold = 0.99          // brutal floor
        XCTAssertEqual(TagSpace.classify(strong, embedder: e, topK: 3), [id])
        XCTAssertEqual(Set(ClipIndexer.tags(for: strong, embedder: e)), [id])
    }
}

@MainActor
final class SmartUserTagRankingTests: XCTestCase {
    private let e = HashingEmbedder()

    override func setUp() {
        super.setUp()
        TagBaskets.activeID = "general"
        TagBaskets.overlayID = nil
    }

    /// An explicit user label beats a perfect neural match, and the query is
    /// normalised the same way user tags are (trimmed + lowercased).
    func testUserTagBoostOutranksNeuralAndNormalisesTheQuery() {
        let query = "  Client-Acme  "
        let normalized = ClipItem.normalizedUserTags([query]).first!
        let labelled = ClipItem(kind: .text, text: "notes with no lexical overlap whatsoever")
        labelled.userTags = [normalized]
        labelled.embeddings[e.signature] =
            ModelEmbedding(vector: e.embed("entirely different prose"))

        let neuralOnly = ClipItem(kind: .text, text: "a semantically perfect but unlabelled clip")
        neuralOnly.embeddings[e.signature] =
            ModelEmbedding(vector: e.embed(query, query: true))

        let ranked = SemanticRanker.smart(query: query, items: [neuralOnly, labelled], embedder: e)
        XCTAssertEqual(ranked.first?.id, labelled.id,
                       "a hand-applied user tag is a stronger signal than cosine alone")
        XCTAssertTrue(ranked.contains { $0.id == neuralOnly.id },
                      "the neural match is still kept, just below")
    }

    /// The boost is specific: a clip carrying a DIFFERENT user tag gets nothing.
    func testUnrelatedUserTagIsNotBoosted() {
        let query = "client-acme"
        let other = ClipItem(kind: .text, text: "notes with no lexical overlap whatsoever")
        other.userTags = ["client-beta"]
        other.embeddings[e.signature] =
            ModelEmbedding(vector: e.embed("entirely different prose"))
        let neuralOnly = ClipItem(kind: .text, text: "client-acme mentioned verbatim")
        neuralOnly.embeddings[e.signature] =
            ModelEmbedding(vector: e.embed(query, query: true))

        let ranked = SemanticRanker.smart(query: query, items: [other, neuralOnly], embedder: e)
        XCTAssertEqual(ranked.first?.id, neuralOnly.id,
                       "a mismatched user tag earns no boost")
    }
}

final class SuggestedUserTagTests: XCTestCase {
    private let signature = "suggest-test-v1"

    /// A clip whose vector is `v`, plus optional user tags.
    private func clip(_ v: [Float], tags: [String] = []) -> ClipItem {
        let item = ClipItem(kind: .text, text: "clip \(UUID().uuidString.prefix(4))")
        item.userTags = ClipItem.normalizedUserTags(tags)
        item.embeddings[signature] = ModelEmbedding(vector: HashingEmbedder.normalize(v))
        return item
    }

    private func members(_ v: [Float], _ n: Int) -> [ClipItem] { (0..<n).map { _ in clip(v) } }

    func testSuggestsTagWhoseMemberCentroidIsNearTheClip() {
        let subject = clip([1, 0, 0])
        let index: [String: [ClipItem]] = [
            "near": members([1, 0, 0], 4),      // centroid == the clip → cosine 1
            "far":  members([0, 1, 0], 4),      // orthogonal → cosine 0
        ]
        let suggested = SemanticRanker.suggestedUserTags(
            for: subject, userTagIndex: index, dismissed: [], embedderSignature: signature)
        XCTAssertEqual(suggested, ["near"], "only the nearby centroid is suggested")
    }

    func testRanksByCosineAndCapsAtThree() {
        let subject = clip([1, 0, 0])
        let index: [String: [ClipItem]] = [
            "best":   members([1, 0, 0], 4),          // 1.00
            "second": members([0.9, 0.44, 0], 4),     // ≈0.90
            "third":  members([0.75, 0.66, 0], 4),    // ≈0.75
            "fourth": members([0.6, 0.8, 0], 4),      // 0.60 — still over sigma
        ]
        let suggested = SemanticRanker.suggestedUserTags(
            for: subject, userTagIndex: index, dismissed: [], embedderSignature: signature)
        XCTAssertEqual(suggested, ["best", "second", "third"],
                       "strongest first, capped at three")
    }

    func testOmitsUnderAppliedDismissedAndAlreadyCarriedTags() {
        let subject = clip([1, 0, 0], tags: ["carried"])
        let index: [String: [ClipItem]] = [
            "near":      members([1, 0, 0], 4),
            "rare":      members([1, 0, 0], 3),   // under minApplies
            // Deliberately NOT co-located with "near": a dismissed tag vetoes a
            // near-twin by design (see SuggestionGateTests), and this test is
            // about the exclusion rules, not confusability.
            "dismissed": members([0.5, 0.87, 0], 4),
            "carried":   members([1, 0, 0], 4),   // already on the clip
        ]
        let dismissed: Set<String> = [
            SemanticRanker.dismissalKey(tag: "dismissed", clipID: subject.id)
        ]
        let suggested = SemanticRanker.suggestedUserTags(
            for: subject, userTagIndex: index, dismissed: dismissed, embedderSignature: signature)
        XCTAssertEqual(suggested, ["near"])
    }

    /// A dismissal is per (tag, clip): it must not suppress the tag elsewhere.
    func testDismissalIsScopedToItsOwnClip() {
        let a = clip([1, 0, 0])
        let b = clip([1, 0, 0])
        let index: [String: [ClipItem]] = ["near": members([1, 0, 0], 4)]
        let dismissed: Set<String> = [SemanticRanker.dismissalKey(tag: "near", clipID: a.id)]
        XCTAssertTrue(SemanticRanker.suggestedUserTags(
            for: a, userTagIndex: index, dismissed: dismissed, embedderSignature: signature).isEmpty)
        XCTAssertEqual(SemanticRanker.suggestedUserTags(
            for: b, userTagIndex: index, dismissed: dismissed, embedderSignature: signature), ["near"])
    }

    /// Members lacking a vector in this space are skipped, and a clip with no
    /// vector of its own gets no suggestions at all.
    func testIgnoresMembersAndClipsWithoutAVectorInThisSpace() {
        let subject = clip([1, 0, 0])
        let strays = (0..<2).map { i in ClipItem(kind: .text, text: "unembedded \(i)") }
        let index: [String: [ClipItem]] = ["near": members([1, 0, 0], 4) + strays]
        XCTAssertEqual(SemanticRanker.suggestedUserTags(
            for: subject, userTagIndex: index, dismissed: [], embedderSignature: signature), ["near"],
            "unembedded members simply don't vote")

        let unembedded = ClipItem(kind: .text, text: "no vector here")
        XCTAssertTrue(SemanticRanker.suggestedUserTags(
            for: unembedded, userTagIndex: index, dismissed: [], embedderSignature: signature).isEmpty)
    }

    func testSigmaAndMinAppliesAreTunable() {
        let subject = clip([1, 0, 0])
        let index: [String: [ClipItem]] = ["mid": members([0.6, 0.8, 0], 3)]   // cosine 0.6, 3 applies
        XCTAssertTrue(SemanticRanker.suggestedUserTags(
            for: subject, userTagIndex: index, dismissed: [], embedderSignature: signature).isEmpty,
            "3 applies is under the default minimum of 4")
        XCTAssertEqual(SemanticRanker.suggestedUserTags(
            for: subject, userTagIndex: index, dismissed: [], embedderSignature: signature,
            minApplies: 3), ["mid"])
        XCTAssertTrue(SemanticRanker.suggestedUserTags(
            for: subject, userTagIndex: index, dismissed: [], embedderSignature: signature,
            minApplies: 3, sigma: 0.7).isEmpty, "a stricter sigma rejects it")
    }
}
