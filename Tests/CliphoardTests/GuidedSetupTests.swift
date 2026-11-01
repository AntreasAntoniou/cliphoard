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
    func testDeferredDownloadDoesNotWaiveRetentionConsent() {
        var draft = GuidedSetupDraft(overlays: [], level: .normal, historyLimit: 500)
        draft.level = .high; draft.historyLimit = 100; draft.step = .finish
        XCTAssertFalse(draft.canFinish(unpinnedCount: 200, selectedModelAvailable: false, allowDeferredModel: true))
        draft.confirmedRemovalCount = 100
        XCTAssertTrue(draft.canFinish(unpinnedCount: 200, selectedModelAvailable: false, allowDeferredModel: true))
        XCTAssertFalse(draft.canFinish(unpinnedCount: 200, selectedModelAvailable: false))
    }
    func testFreeImagePresentsProWithoutSelectingOrPurchasing() {
        let free = Entitlement.free(reason: nil)
        XCTAssertTrue(GuidedSetupDraft.presentsPro(for: .image, entitlement: free))
        XCTAssertFalse(GuidedSetupDraft.presentsPro(for: .exact, entitlement: free))
        XCTAssertFalse(GuidedSetupDraft.presentsPro(for: .image, entitlement: .pro(orderID: "public-fixture", issued: Date(timeIntervalSince1970: 0))))
    }
    func testNewMediaStepsKeepChoicesDraftOnlyUntilFinish() {
        let original = GuidedSetupDraft.MediaChoices(text: true, images: true, audio: false, video: false,
            imageModel: .clip, sampling: .balanced, speech: .off, speechModel: .turbo)
        var draft = GuidedSetupDraft(overlays: [], level: .normal, historyLimit: 500, media: original)
        draft.step = .pictures
        draft.media.imageModel = .gemma2
        draft.next()
        XCTAssertEqual(draft.step, .media)
        draft.media.audio = true; draft.media.video = true
        draft.media.sampling = .detailed; draft.media.speech = .sampled
        draft.media.speechModel = .small
        XCTAssertNil(draft.changes, "Closing setup here must leave every preference unchanged")
        XCTAssertEqual(original.imageModel, .clip)
        XCTAssertEqual(original.sampling, .balanced)
        draft.step = .finish
        XCTAssertEqual(draft.changes?.media.imageModel, .gemma2)
        XCTAssertEqual(draft.changes?.media.audio, true)
        XCTAssertEqual(draft.changes?.media.video, true)
        XCTAssertEqual(draft.changes?.media.sampling, .detailed)
        XCTAssertEqual(draft.changes?.media.speech, .sampled)
        XCTAssertEqual(draft.changes?.media.speechModel, .small)
        XCTAssertNil(draft.changes?.media.text)
        XCTAssertNil(draft.changes?.media.images)
    }
    func testRevisitingOnboardingPreservesNondefaultMediaPreferences() {
        let current = GuidedSetupDraft.MediaChoices(text: false, images: false, audio: true, video: true,
            imageModel: .gemma2, sampling: .lightweight, speech: .full, speechModel: .largeV3)
        var draft = GuidedSetupDraft(overlays: ["developer"], level: .gemma2, historyLimit: 0, media: current)
        while draft.step != .finish { draft.next() }
        XCTAssertEqual(draft.media, current)
        XCTAssertEqual(draft.changes?.media.isEmpty, true)
        draft.media.imageModel = .clip; draft.media.imageModel = .gemma2
        XCTAssertEqual(draft.changes?.media.isEmpty, true, "Returning to the original choice must not overwrite a concurrent settings change")
    }
    func testMediaChoicesDoNotWaiveRetentionConsent() {
        var draft = GuidedSetupDraft(overlays: [], level: .normal, historyLimit: 500)
        XCTAssertEqual(draft.media.sampling, .balanced)
        XCTAssertEqual(draft.media.speech, .off)
        draft.media.video = true; draft.media.speech = .full; draft.historyLimit = 100; draft.step = .finish
        XCTAssertFalse(draft.canFinish(unpinnedCount: 200, selectedModelAvailable: true, allowDeferredModel: true))
        draft.confirmedRemovalCount = 100
        XCTAssertTrue(draft.canFinish(unpinnedCount: 200, selectedModelAvailable: true, allowDeferredModel: true))
    }
}
