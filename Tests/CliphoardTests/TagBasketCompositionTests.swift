import XCTest
@testable import Cliphoard

// MARK: - Basket shape invariants (fixed-width axes + a topical tail)

@MainActor
final class TagBasketShapeTests: XCTestCase {
    override func tearDown() {
        TagBaskets.overlayID = nil
        super.tearDown()
    }

    /// The layout rule of the hybrid model: any axis a curated basket still
    /// carries is exactly `dimensionSize` wide, so tag-ids fall on predictable
    /// slices. Wave 4 dropped the *other* half of the old invariant — the
    /// obligation to carry axes at all — so General now legitimately has none and
    /// must still report as dimensional.
    func testEveryBuiltInDimensionHoldsExactlyEightTags() {
        XCTAssertEqual(TagBasket.dimensionSize, 8)
        for basket in TagBaskets.builtIn {
            for dim in basket.dimensions {
                XCTAssertEqual(dim.tags.count, TagBasket.dimensionSize,
                               "\(basket.id) / \(dim.name)")
            }
            XCTAssertTrue(basket.isDimensional, "\(basket.id) must be hybrid, not flat")
            // General legitimately owns NO tag space now (design §4); the
            // specialists keep theirs.
            if basket.id != "general" {
                XCTAssertFalse(basket.tags.isEmpty, "\(basket.id) must still own a tag space")
            }
        }
        XCTAssertTrue(TagBaskets.general.dimensions.isEmpty,
                      "General's four axes were retired, not replaced")
    }

    /// Axis ids and topical ids tile `0..<tags.count` exactly once each — no gap
    /// between the last axis and the topical tail, no overlap.
    func testTopicalRangePartitionsTheTagIdsWithNoGapOrOverlap() {
        for basket in TagBaskets.builtIn {
            let tags = basket.tags
            let range = basket.topicalRange
            let axisWidth = basket.dimensions.count * TagBasket.dimensionSize

            XCTAssertEqual(range.lowerBound, axisWidth, basket.id)
            XCTAssertEqual(range.upperBound, tags.count, basket.id)
            XCTAssertEqual(range.count, basket.topical.count, basket.id)
            // Head is the axes, in order; tail is the topical pool, in order.
            XCTAssertEqual(Array(tags[0..<range.lowerBound]),
                           basket.dimensions.flatMap { $0.tags }, basket.id)
            XCTAssertEqual(Array(tags[range]), basket.topical, basket.id)
            // Every id belongs to exactly one side.
            for id in 0..<tags.count {
                let onAxis = id < range.lowerBound
                XCTAssertNotEqual(onAxis, range.contains(id),
                                  "id \(id) of \(basket.id) is on both sides or neither")
            }
        }
    }

    func testFlatBasketHasAnEmptyTopicalRange() {
        let flat = TagBasket(id: "flat", name: "Flat", tags: ["a", "b", "c"])
        XCTAssertFalse(flat.isDimensional)
        XCTAssertTrue(flat.topicalRange.isEmpty)
        XCTAssertEqual(flat.topicalRange, 0..<0)
        XCTAssertEqual(flat.tags, ["a", "b", "c"])
    }

    /// The topical pool round-trips through Codable and an old payload written
    /// before `topical` existed still decodes (as an empty tail).
    func testTopicalSurvivesCodableAndOlderPayloadsStillDecode() throws {
        let round = try JSONDecoder().decode(
            TagBasket.self, from: try JSONEncoder().encode(TagBaskets.general))
        XCTAssertEqual(round, TagBaskets.general)
        XCTAssertEqual(round.topical, TagBaskets.general.topical)

        let legacy = Data(#"{"id":"old","name":"Old","tags":["x","y"]}"#.utf8)
        let decoded = try JSONDecoder().decode(TagBasket.self, from: legacy)
        XCTAssertEqual(decoded.tags, ["x", "y"])
        XCTAssertTrue(decoded.topical.isEmpty)
        XCTAssertTrue(decoded.topicalRange.isEmpty)
    }
}

// MARK: - Composition: General + one optional specialist overlay

@MainActor
final class TagBasketCompositionTests: XCTestCase {
    override func setUp() { super.setUp(); TagBaskets.overlayID = nil }
    override func tearDown() { TagBaskets.overlayID = nil; super.tearDown() }

    func testComposedIsGeneralWhenNoOverlayIsSelected() {
        XCTAssertNil(TagBaskets.overlayID)
        XCTAssertNil(TagBaskets.overlay)
        XCTAssertEqual(TagBaskets.composed, TagBaskets.general)
        XCTAssertEqual(TagBaskets.active, TagBaskets.general)
        XCTAssertEqual(TagBaskets.composed.id, "general")
    }

    func testComposedMergesOverlayOntoGeneralWithoutDuplicates() {
        let overlay = TagBaskets.developer
        TagBaskets.overlayID = overlay.id
        let general = TagBaskets.general
        let composed = TagBaskets.composed

        XCTAssertEqual(composed.id, "composed:dev")

        // No duplicate axis names and no duplicate topical tags — the point of the
        // dedupe merge (developer still reuses the topical terms url/path).
        let axisNames = composed.dimensions.map { $0.name }
        XCTAssertEqual(axisNames.count, Set(axisNames).count, "axis names must be unique")
        XCTAssertEqual(composed.topical.count, Set(composed.topical).count, "topical must be de-duped")

        // Since Wave 4 retired the four abstract axes, General contributes NO axis
        // at all, so the composed cube is exactly the overlay's surviving concrete
        // axes — nothing to override, and nothing of General's to preserve.
        XCTAssertTrue(general.dimensions.isEmpty, "General has no axes left to merge")
        XCTAssertEqual(composed.dimensions, overlay.dimensions)
        XCTAssertNotNil(composed.dimensions.first { $0.name == "Artifact" })
        XCTAssertNotNil(composed.dimensions.first { $0.name == "Language" })
        XCTAssertNil(composed.dimensions.first { $0.name == "Intent" },
                     "a retired axis must not reappear through composition")

        // Topical is the order-preserving union of General then overlay.
        var seen = Set<String>()
        let expectedTopical = (general.topical + overlay.topical).filter { seen.insert($0).inserted }
        XCTAssertEqual(composed.topical, expectedTopical)

        // Hybrid layout invariant still holds: axes first, one contiguous tail.
        XCTAssertEqual(composed.tags, composed.dimensions.flatMap { $0.tags } + composed.topical)
        XCTAssertEqual(composed.topicalRange.lowerBound, composed.dimensions.count * TagBasket.dimensionSize)
        XCTAssertEqual(composed.topicalRange.upperBound, composed.tags.count)
        XCTAssertEqual(Array(composed.tags[composed.topicalRange]), composed.topical)
        XCTAssertEqual(TagBaskets.active, composed)
    }

    func testFingerprintChangesWithTheOverlay() {
        let bare = TagBaskets.composed.fingerprint

        TagBaskets.overlayID = "dev"
        let dev = TagBaskets.composed.fingerprint
        TagBaskets.overlayID = "legal"
        let legal = TagBaskets.composed.fingerprint

        XCTAssertNotEqual(bare, dev)
        XCTAssertNotEqual(dev, legal, "a different overlay must invalidate cached tag vectors")

        TagBaskets.overlayID = nil
        XCTAssertEqual(TagBaskets.composed.fingerprint, bare, "clearing the overlay restores General")
    }

    func testUnknownOrSelfOverlayFallsBackToGeneral() {
        TagBaskets.overlayID = "no-such-basket"
        XCTAssertNil(TagBaskets.overlay)
        XCTAssertEqual(TagBaskets.composed, TagBaskets.general)

        TagBaskets.overlayID = "general"
        XCTAssertNil(TagBaskets.overlay, "General is the base, never its own overlay")
        XCTAssertEqual(TagBaskets.composed, TagBaskets.general)
    }

    /// Every specialist composes cleanly: still 8-wide axes, still one tail.
    func testEverySpecialistOverlayComposesIntoAValidHybridBasket() {
        for overlay in TagBaskets.builtIn where overlay.id != "general" {
            TagBaskets.overlayID = overlay.id
            let composed = TagBaskets.composed
            // Unique axis names, every axis still 8-wide.
            let names = composed.dimensions.map { $0.name }
            XCTAssertEqual(names.count, Set(names).count, overlay.id)
            XCTAssertTrue(composed.dimensions.allSatisfy { $0.tags.count == TagBasket.dimensionSize },
                          overlay.id)
            // De-duped topical, clean partition: axes first, one contiguous tail.
            XCTAssertEqual(composed.topical.count, Set(composed.topical).count, overlay.id)
            XCTAssertEqual(composed.topicalRange.lowerBound,
                           composed.dimensions.count * TagBasket.dimensionSize, overlay.id)
            XCTAssertEqual(composed.topicalRange.upperBound, composed.tags.count, overlay.id)
            XCTAssertEqual(Array(composed.tags[composed.topicalRange]), composed.topical, overlay.id)
        }
    }
}
