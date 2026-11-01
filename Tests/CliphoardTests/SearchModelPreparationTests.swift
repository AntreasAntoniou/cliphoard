import XCTest
@testable import Cliphoard

final class SearchModelPreparationTests: XCTestCase {
    func testMixedModelsRequireOnlySelectedBackends() {
        let choices = SearchCapabilities(text: true, images: true, audio: false, video: false, imageModel: .clip)
        XCTAssertEqual(SearchModelRequirement.selected(mode: .all, capabilities: choices, level: .normal, pro: true), [.text(.normal), .pictures])
        XCTAssertEqual(SearchModelRequirement.selected(mode: .text, capabilities: choices, level: .gemma2, pro: true), [.text(.gemma2)])
    }
    func testFreeNeverRequestsPaidModelPreparation() {
        let choices = SearchCapabilities(text: true, images: true, audio: true, video: true, imageModel: .gemma2)
        for mode in [SearchModality.images, .audio, .video] {
            XCTAssertTrue(SearchModelRequirement.selected(mode: mode, capabilities: choices, level: .normal, pro: false).isEmpty)
        }
        XCTAssertEqual(SearchModelRequirement.selected(mode: .all, capabilities: choices, level: .normal, pro: false), [.text(.normal)])
    }
    func testExplicitCategoryCanPrepareWithoutEnablingAllLane() {
        let choices = SearchCapabilities(text: false, images: false, audio: false, video: false, imageModel: .clip)
        XCTAssertEqual(SearchModelRequirement.selected(mode: .audio, capabilities: choices, level: .off, pro: true), [.media])
        XCTAssertTrue(SearchModelRequirement.selected(mode: .all, capabilities: choices, level: .off, pro: true).isEmpty)
    }
    func testMultipleMediaCategoriesDeduplicatePreparation() {
        let choices = SearchCapabilities(text: true, images: true, audio: true, video: true, imageModel: .gemma2)
        XCTAssertEqual(SearchModelRequirement.selected(mode: .all, capabilities: choices, level: .off, pro: true), [.media])
    }
    func testSpeechIsOptionalAndOnlyNeededForPaidAudioOrVideo() {
        let choices = SearchCapabilities(text: true, images: true, audio: true, video: true, imageModel: .clip)
        XCTAssertEqual(SearchModelRequirement.selected(mode: .video, capabilities: choices, level: .off, pro: true, speech: .turbo), [.media, .speech(.turbo)])
        XCTAssertEqual(SearchModelRequirement.selected(mode: .images, capabilities: choices, level: .off, pro: true, speech: .turbo), [.pictures])
        XCTAssertEqual(SearchModelRequirement.selected(mode: .all, capabilities: choices, level: .off, pro: false, speech: .turbo), [])
    }
    @MainActor func testFailedOrCancelledWorkCanBeRetriedButActiveTransferIsNotDuplicated() {
        XCTAssertTrue(SearchModelPreparationView.isWorking(.downloading("fixture", progress: 0.5)))
        XCTAssertTrue(SearchModelPreparationView.isWorking(.loading("fixture")))
        XCTAssertTrue(SearchModelPreparationView.isWorking(.installing("fixture")))
        XCTAssertFalse(SearchModelPreparationView.isWorking(.failed("fixture", message: "offline")))
        XCTAssertFalse(SearchModelPreparationView.isWorking(.notInstalled("fixture")))
        XCTAssertFalse(SearchModelPreparationView.isWorking(.ready(signature: "fixture")))
    }
    @MainActor func testDeferredTextModelStaysDormantOnStartupConfiguration() {
        let defaults = UserDefaults.standard
        let key = "deferredTextModelPreparation"
        let original = defaults.object(forKey: key)
        defer {
            if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        EmbedderProvider.deferPreparation(level: .normal)
        XCTAssertEqual(defaults.string(forKey: key), DeepSearchLevel.normal.rawValue)
        // This is the startup path, even when a model archive is cached locally.
        EmbedderProvider.configure(level: .normal)
        XCTAssertEqual(EmbedderState.shared.state, .notInstalled(DeepSearchLevel.normal.modelName!))
        XCTAssertTrue(EmbedderProvider.active is HashingEmbedder)
        XCTAssertFalse(SearchModelPreparationView.isWorking(EmbedderState.shared.state))
    }
}
