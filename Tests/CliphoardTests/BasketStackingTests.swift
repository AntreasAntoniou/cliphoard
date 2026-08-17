import XCTest
@testable import Cliphoard

/// Ticking a second basket must never subtract from the first.
///
/// The first multi-basket implementation merged dimensions BY NAME with last-write-wins.
/// That reads as reasonable and is silently destructive, because three name collisions
/// already exist among the built-ins:
///
///     Artifact  -> Developer, DevOps
///     Asset     -> Designer,  Marketing
///     Doc       -> Finance,   Legal
///
/// So ticking Developer AND DevOps kept one Artifact axis and discarded the other's eight
/// tags. Nothing errored, the basket still looked well-formed, and the only visible symptom
/// would have been clips quietly failing to classify under labels the user had explicitly
/// asked for. A basket is a GROUP the user adds, not a namespace that overwrites.
@MainActor
final class BasketStackingTests: XCTestCase {

    private var savedIDs: [String] = []

    override func setUp() {
        super.setUp()
        savedIDs = TagBaskets.overlayIDs
    }

    override func tearDown() {
        TagBaskets.overlayIDs = savedIDs
        super.tearDown()
    }

    /// The precondition the whole file rests on. If the built-ins are ever renamed so that
    /// no two share a dimension name, this test suite stops proving anything — so assert
    /// the hazard still exists rather than silently testing a case that cannot occur.
    func testTheCollidingNamesThisGuardsAgainstStillExist() {
        var byName: [String: [String]] = [:]
        for basket in TagBaskets.builtIn {
            for dim in basket.dimensions { byName[dim.name, default: []].append(basket.id) }
        }
        let collisions = byName.filter { $0.value.count > 1 }
        XCTAssertFalse(collisions.isEmpty,
                       "no two built-in baskets share a dimension name any more, so the "
                       + "silent-overwrite hazard cannot be reproduced and these tests are "
                       + "vacuous. Either restore a collision or retire this file.")
    }

    /// The defect itself: stacking two colliding baskets must keep BOTH tag sets.
    func testStackingTwoBasketsThatShareADimensionNameKeepsBothTagSets() {
        TagBaskets.overlayIDs = ["dev", "devops"]
        let composed = TagBaskets.composed

        let devArtifact = Set(TagBaskets.developer.dimensions.first { $0.name == "Artifact" }!.tags)
        let opsArtifact = Set(TagBaskets.devops.dimensions.first { $0.name == "Artifact" }!.tags)
        XCTAssertNotEqual(devArtifact, opsArtifact, "precondition: the two axes differ")

        let all = Set(composed.tags)
        for tag in devArtifact {
            XCTAssertTrue(all.contains(tag),
                          "Developer's Artifact tag '\(tag)' vanished when DevOps was also "
                          + "ticked. Adding a basket must never remove another's tags.")
        }
        for tag in opsArtifact {
            XCTAssertTrue(all.contains(tag),
                          "DevOps' Artifact tag '\(tag)' is missing — the merge dropped the "
                          + "LATER basket instead of the earlier one, which is the same bug "
                          + "facing the other way")
        }
    }

    /// Both axes survive as SEPARATE groups, distinguishable in the UI. A union that merged
    /// the two tag lists into one axis would satisfy the test above while destroying the
    /// distinction the user ticked two baskets to get.
    func testCollidingDimensionsRemainSeparateAxesWithDistinctNames() {
        TagBaskets.overlayIDs = ["dev", "devops"]
        let artifactAxes = TagBaskets.composed.dimensions.filter { $0.name.hasPrefix("Artifact") }
        XCTAssertEqual(artifactAxes.count, 2,
                       "expected two distinct Artifact axes, found \(artifactAxes.count) — "
                       + "collapsing them into one loses the grouping")
        XCTAssertEqual(Set(artifactAxes.map(\.name)).count, 2,
                       "the two axes must have DIFFERENT names or the UI cannot label them; "
                       + "the collision suffix is what makes them addressable")
        for axis in artifactAxes {
            XCTAssertEqual(axis.tags.count, TagBasket.dimensionSize,
                           "\(axis.name) must stay 8 wide — the facet cube's id arithmetic "
                           + "depends on every axis being exactly dimensionSize")
        }
    }

    /// A single overlay must look EXACTLY as it did before stacking existed. The
    /// disambiguation suffix is applied only on collision, so the common case is untouched.
    func testASingleOverlayIsUnchangedByTheStackingMachinery() {
        TagBaskets.overlayIDs = ["dev"]
        let names = TagBaskets.composed.dimensions.map(\.name)
        XCTAssertTrue(names.contains("Artifact"),
                      "a lone Developer overlay must still show a plain 'Artifact' axis, not "
                      + "'Artifact (Developer)' — suffixing unconditionally would rename "
                      + "every existing user's chips for no reason")
        XCTAssertFalse(names.contains { $0.hasPrefix("Artifact (") })
    }

    /// Adding a basket only ever GROWS the tag space. Asserted across every pair rather than
    /// one example, because the collisions are the interesting cases and there are three.
    func testAddingAnyBasketNeverShrinksTheTagSpace() {
        let specialists = TagBaskets.builtIn.filter { $0.id != "general" && $0.isDimensional }
        for first in specialists {
            TagBaskets.overlayIDs = [first.id]
            let alone = Set(TagBaskets.composed.tags)
            for second in specialists where second.id != first.id {
                TagBaskets.overlayIDs = [first.id, second.id]
                let together = Set(TagBaskets.composed.tags)
                XCTAssertTrue(alone.isSubset(of: together),
                              "ticking \(second.id) removed tags contributed by \(first.id): "
                              + "\(alone.subtracting(together).sorted())")
            }
        }
    }

    /// Order must not change WHAT is present, only its arrangement. Under last-write-wins it
    /// changed which basket's tags survived, which is how the same two ticks produced two
    /// different tag spaces depending on click order.
    func testSelectionOrderDoesNotChangeTheTagSet() {
        TagBaskets.overlayIDs = ["design", "marketing"]
        let forward = Set(TagBaskets.composed.tags)
        TagBaskets.overlayIDs = ["marketing", "design"]
        let reverse = Set(TagBaskets.composed.tags)
        XCTAssertEqual(forward, reverse,
                       "the same two baskets produced different tag spaces depending on the "
                       + "order they were ticked in")
    }

    /// No overlays at all is still plain General — the stacking path must not manufacture a
    /// composed basket out of an empty selection.
    func testNoOverlaysIsPlainGeneral() {
        TagBaskets.overlayIDs = []
        XCTAssertEqual(TagBaskets.composed.id, TagBaskets.general.id)
    }
}
