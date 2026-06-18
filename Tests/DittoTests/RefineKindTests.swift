import XCTest
@testable import Ditto

/// Audit BL-T5: `ClipIndexer.refineKind` uses the embedding's top tags to rescue a
/// link the regex/detector missed — but only conservatively (single-token text).
@MainActor
final class RefineKindTests: XCTestCase {
    private var savedLevel: DeepSearchLevel!
    private var savedBasket: String!

    override func setUp() {
        super.setUp()
        savedLevel = DeepSearch.level
        savedBasket = TagBaskets.activeID
        // A tier is on (active = HashingEmbedder fallback in tests) and the General
        // basket is active so "url link" / "email address" / "domain name" exist.
        DeepSearch.level = .normal
        TagBaskets.activeID = "general"
    }

    override func tearDown() {
        DeepSearch.level = savedLevel
        TagBaskets.activeID = savedBasket
        super.tearDown()
    }

    private var sig: String { EmbedderProvider.active.signature }

    /// Index of a known link-ish tag in the active basket.
    private func tagID(_ name: String) -> Int {
        let i = TagBaskets.general.tags.firstIndex(of: name)
        XCTAssertNotNil(i, "expected '\(name)' in the General basket")
        return i ?? 0
    }

    /// A whitespace-free text clip whose top tag is "url link" is promoted to .link.
    func testPromotesWhitespaceFreeTextWithLinkTag() {
        let item = ClipItem(kind: .text, text: "bit.ly/xY9z")
        item.embeddings[sig] = ModelEmbedding(vector: [1, 0], tags: [tagID("url link"), 99])
        ClipIndexer.refineKind(item)
        XCTAssertEqual(item.kind, .link, "single-token text with a link tag → link")
    }

    /// An email tag also promotes (it's in the link set).
    func testPromotesOnEmailTag() {
        let item = ClipItem(kind: .text, text: "ada@example.com")
        item.embeddings[sig] = ModelEmbedding(vector: [1, 0], tags: [tagID("email address")])
        ClipIndexer.refineKind(item)
        XCTAssertEqual(item.kind, .link)
    }

    /// Multi-word text is left alone even if it carries a link tag — the promotion
    /// only targets single-token content (an obfuscated URL), not prose.
    func testLeavesMultiWordTextAlone() {
        let item = ClipItem(kind: .text, text: "visit our site at example dot com")
        item.embeddings[sig] = ModelEmbedding(vector: [1, 0], tags: [tagID("url link")])
        ClipIndexer.refineKind(item)
        XCTAssertEqual(item.kind, .text, "whitespace present → not refined")
    }

    /// A non-link top tag leaves single-token text alone.
    func testLeavesNonLinkSingleTokenAlone() {
        let item = ClipItem(kind: .text, text: "deadbeefcafe")
        item.embeddings[sig] = ModelEmbedding(vector: [1, 0], tags: [tagID("hash digest")])
        ClipIndexer.refineKind(item)
        XCTAssertEqual(item.kind, .text)
    }

    /// Never demotes a non-text kind, even with a link tag attached.
    func testDoesNotDemoteNonTextKinds() {
        let img = ClipItem(kind: .image, text: "screenshot.png")
        img.embeddings[sig] = ModelEmbedding(vector: [1, 0], tags: [tagID("url link")])
        ClipIndexer.refineKind(img)
        XCTAssertEqual(img.kind, .image, "non-text kinds are untouched")

        let color = ClipItem(kind: .color, text: "#FF8800")
        color.embeddings[sig] = ModelEmbedding(vector: [1, 0], tags: [tagID("url link")])
        ClipIndexer.refineKind(color)
        XCTAssertEqual(color.kind, .color)
    }
}
