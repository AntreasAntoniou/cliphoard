import XCTest
@testable import Ditto

/// `ClipIndexer.refineKind` may use embedding tags to rescue a link the detector
/// missed — but ONLY when a real ogma model is active. Under the HashingEmbedder
/// fallback (the default until a model is bundled) its tags are unreliable, so
/// refineKind must be a no-op there, leaving deterministic detection authoritative.
@MainActor
final class RefineKindTests: XCTestCase {
    private var savedLevel: DeepSearchLevel!
    private var savedBasket: String!

    override func setUp() {
        super.setUp()
        savedLevel = DeepSearch.level
        savedBasket = TagBaskets.activeID
        // A tier is on (active = HashingEmbedder fallback in tests) and the General
        // basket is active so "url link" / "email address" exist.
        DeepSearch.level = .normal
        TagBaskets.activeID = "general"
    }

    override func tearDown() {
        DeepSearch.level = savedLevel
        TagBaskets.activeID = savedBasket
        super.tearDown()
    }

    private var sig: String { EmbedderProvider.active.signature }

    private func tagID(_ name: String) -> Int {
        let i = TagBaskets.general.tags.firstIndex(of: name)
        XCTAssertNotNil(i, "expected '\(name)' in the General basket")
        return i ?? 0
    }

    /// The fix: with the unreliable HashingEmbedder active, a url-ish clip carrying
    /// a "url link" tag is NOT promoted — random fallback tags must not override
    /// detection (this is what put ordinary words into the Links category).
    func testFallbackEmbedderDoesNotPromote() {
        XCTAssertFalse(sig.hasPrefix("ogma"), "tests run on the hashing fallback")
        let url = ClipItem(kind: .text, text: "bit.ly/xY9z")
        url.embeddings[sig] = ModelEmbedding(vector: [1, 0], tags: [tagID("url link"), 99])
        ClipIndexer.refineKind(url)
        XCTAssertEqual(url.kind, .text, "hashing tags must not promote to link")

        let email = ClipItem(kind: .text, text: "ada@example.com")
        email.embeddings[sig] = ModelEmbedding(vector: [1, 0], tags: [tagID("email address")])
        ClipIndexer.refineKind(email)
        XCTAssertEqual(email.kind, .text)
    }

    /// Even setting the gate aside, a plain word with no url-ish character is never
    /// link material — the secondary guard that stops "ordinary words → Links".
    func testPlainWordNeverPromoted() {
        let item = ClipItem(kind: .text, text: "Combined")
        item.embeddings[sig] = ModelEmbedding(vector: [1, 0], tags: [tagID("url link")])
        ClipIndexer.refineKind(item)
        XCTAssertEqual(item.kind, .text)
    }

    /// Multi-word prose is left alone regardless.
    func testLeavesMultiWordTextAlone() {
        let item = ClipItem(kind: .text, text: "visit our site at example dot com")
        item.embeddings[sig] = ModelEmbedding(vector: [1, 0], tags: [tagID("url link")])
        ClipIndexer.refineKind(item)
        XCTAssertEqual(item.kind, .text)
    }

    /// Never demotes a non-text kind, even with a link tag attached.
    func testDoesNotDemoteNonTextKinds() {
        let img = ClipItem(kind: .image, text: "screenshot.png")
        img.embeddings[sig] = ModelEmbedding(vector: [1, 0], tags: [tagID("url link")])
        ClipIndexer.refineKind(img)
        XCTAssertEqual(img.kind, .image)

        let color = ClipItem(kind: .color, text: "#FF8800")
        color.embeddings[sig] = ModelEmbedding(vector: [1, 0], tags: [tagID("url link")])
        ClipIndexer.refineKind(color)
        XCTAssertEqual(color.kind, .color)
    }
}
