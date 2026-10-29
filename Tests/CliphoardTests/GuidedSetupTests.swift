import XCTest
@testable import Cliphoard

final class GuidedSetupTests: XCTestCase {
    func testNavigationDoesNotProducePreferenceChanges() {
        var draft = GuidedSetupDraft(overlays: ["developer"], level: .normal, historyLimit: 500)
        draft.next(); draft.next(); draft.back()
        XCTAssertEqual(draft.overlays, ["developer"])
        XCTAssertEqual(draft.level, .normal)
        XCTAssertEqual(draft.historyLimit, 500)
        XCTAssertNil(draft.changes?.historyLimit)
        XCTAssertNil(draft.changes?.level)
        XCTAssertNil(draft.changes?.overlays)
        XCTAssertFalse(draft.canFinish(unpinnedCount: 800, selectedModelAvailable: true))
    }
    func testRetentionNeedsExactCurrentRemovalConsentOnlyAtFinish() {
        var draft = GuidedSetupDraft(overlays: [], level: .normal, historyLimit: 0)
        draft.historyLimit = 100
        draft.step = .finish
        XCTAssertEqual(draft.removalCount(unpinnedCount: 150), 50)
        XCTAssertFalse(draft.canFinish(unpinnedCount: 150, selectedModelAvailable: true))
        draft.confirmedRemovalCount = 50
        XCTAssertTrue(draft.canFinish(unpinnedCount: 150, selectedModelAvailable: true))
        XCTAssertFalse(draft.canFinish(unpinnedCount: 151, selectedModelAvailable: true))
        draft.historyLimit = 200
        XCTAssertNil(draft.confirmedRemovalCount)
        XCTAssertTrue(draft.canFinish(unpinnedCount: 150, selectedModelAvailable: true))
    }
    func testUnavailableModelCannotBeNewlyApplied() {
        var draft = GuidedSetupDraft(overlays: [], level: .normal, historyLimit: 200)
        draft.step = .finish
        XCTAssertTrue(draft.canFinish(unpinnedCount: 0, selectedModelAvailable: false), "preserve unchanged preference")
        draft.level = .high
        XCTAssertFalse(draft.canFinish(unpinnedCount: 0, selectedModelAvailable: false))
        XCTAssertTrue(draft.canFinish(unpinnedCount: 0, selectedModelAvailable: true))
    }
    func testFreeImagePresentsProWithoutSelectingOrPurchasing() {
        let free = Entitlement.free(reason: nil)
        XCTAssertTrue(GuidedSetupDraft.presentsPro(for: .image, entitlement: free))
        XCTAssertFalse(GuidedSetupDraft.presentsPro(for: .exact, entitlement: free))
        XCTAssertFalse(GuidedSetupDraft.presentsPro(for: .image, entitlement: .pro(orderID: "public-fixture", issued: Date(timeIntervalSince1970: 0))))
    }
}
