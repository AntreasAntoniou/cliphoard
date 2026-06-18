import XCTest
@testable import Ditto

/// Audit BL-T6: `SemanticRanker.essence` ranking, thresholding and fallback.
/// All vectors come from the deterministic `HashingEmbedder`, so the cosine
/// magnitudes used in the threshold assertions are stable across runs.
final class SearchRankingTests: XCTestCase {
    private let e = HashingEmbedder()

    private func text(_ s: String) -> ClipItem { ClipItem(kind: .text, text: s) }

    /// A substring match (which gets a +1 bonus) ranks above a non-match.
    func testSubstringMatchOutranksNonMatch() {
        let hit = text("banana smoothie recipe")
        let miss = text("tax accounting ledger")
        let ranked = SemanticRanker.essence(query: "banana", items: [miss, hit], embedder: e)
        XCTAssertEqual(ranked.first?.text, "banana smoothie recipe")
    }

    /// An item that scores below the 0.12 threshold is dropped when at least one
    /// item clears it. ("tax accounting ledger" cosine vs "banana" ≈ 0.07, no
    /// substring → filtered; the substring hit stays.)
    func testBelowThresholdItemsAreFiltered() {
        let hit = text("banana smoothie recipe")
        let weak = text("tax accounting ledger")
        let ranked = SemanticRanker.essence(query: "banana", items: [hit, weak], embedder: e)
        XCTAssertEqual(ranked.map(\.text), ["banana smoothie recipe"],
                       "the sub-threshold non-match is filtered out")
    }

    /// When EVERY item is below threshold, essence falls back to the top-K best
    /// rather than returning nothing — search should never go suddenly empty.
    func testFallsBackToTopKWhenAllBelowThreshold() {
        // Query shares no tokens/tri-grams that push anything to/over 0.12, and no
        // item contains it as a substring → all scores are below threshold.
        let items = [
            text("weather forecast tomorrow"),
            text("the cat sat on a mat"),
            text("apple banana orange"),
        ]
        let ranked = SemanticRanker.essence(query: "zylophone quixotic", items: items, embedder: e)
        XCTAssertEqual(ranked.count, items.count,
                       "fallback returns the full (< 12) set rather than empty")
        XCTAssertEqual(Set(ranked.map(\.text)), Set(items.map(\.text)))
    }

    /// Fallback caps at 12 results even when many items are below threshold.
    func testFallbackCapsAtTwelve() {
        let items = (0..<20).map { text("unrelated filler item number \($0)") }
        let ranked = SemanticRanker.essence(query: "zzqqxx", items: items, embedder: e)
        XCTAssertEqual(ranked.count, 12, "fallback is capped at the top 12")
    }
}
