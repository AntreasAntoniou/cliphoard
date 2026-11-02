import XCTest
@testable import Cliphoard

final class SearchModalitiesTests: XCTestCase {
    func testLegacyScopePreservesIntent() {
        XCTAssertEqual(SearchPreferences.initialModality(legacy: .image), .images)
        XCTAssertEqual(SearchPreferences.initialModality(legacy: .media), .all)
        XCTAssertEqual(SearchPreferences.initialModality(legacy: .smart), .all)
        XCTAssertEqual(SearchPreferences.initialModality(legacy: .exact), .text)
    }
    func testOgmaAndCLIPAllDoesNotRequireGemma() {
        let c = SearchCapabilities(text: true, images: true, audio: true, video: true, imageModel: .clip)
        XCTAssertEqual(c.readyLanes(mode: .all, pro: true, clipReady: true, gemmaReady: false), [.text, .images])
        XCTAssertEqual(c.readyLanes(mode: .all, pro: false, clipReady: true, gemmaReady: true), [.text])
    }
    func testDisabledAllLaneStillWorksWhenExplicitlyChosen() {
        let c = SearchCapabilities(text: true, images: false, audio: false, video: false, imageModel: .gemma2)
        XCTAssertEqual(c.readyLanes(mode: .all, pro: true, clipReady: true, gemmaReady: true), [.text])
        XCTAssertEqual(c.readyLanes(mode: .audio, pro: true, clipReady: true, gemmaReady: true), [.audio])
        XCTAssertEqual(c.readyLanes(mode: .audio, pro: false, clipReady: true, gemmaReady: true), [])
    }
    func testScopeSwitchChangesGemmaRequestEvenForSameQuery() {
        let c = SearchCapabilities(text: true, images: true, audio: true, video: true, imageModel: .gemma2)
        XCTAssertEqual(c.gemmaScopes(mode: .images, pro: true), [.images])
        XCTAssertEqual(c.gemmaScopes(mode: .audio, pro: true), [.audio])
        XCTAssertEqual(c.gemmaScopes(mode: .all, pro: true), [.images, .audio, .video])
        XCTAssertTrue(c.gemmaScopes(mode: .all, pro: false).isEmpty)
    }
    func testRankFusionIsStableDeduplicatedAndDoesNotCompareModelScores() {
        let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let c = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let one: [SearchModality:[UUID]] = [.text:[a,b], .images:[c,b,b]]
        let two: [SearchModality:[UUID]] = [.images:[c,b,b], .text:[a,b]]
        XCTAssertEqual(SearchPreferences.fuse(one), [b,a,c])
        XCTAssertEqual(SearchPreferences.fuse(one), SearchPreferences.fuse(two))
    }
    func testUnavailableSelectedPictureBackendDoesNotFallBackSilently() {
        let c = SearchCapabilities(text: true, images: true, audio: false, video: false, imageModel: .gemma2)
        XCTAssertEqual(c.readyLanes(mode: .images, pro: true, clipReady: true, gemmaReady: false), [])
        XCTAssertEqual(c.readyLanes(mode: .all, pro: true, clipReady: true, gemmaReady: false), [.text])
    }
}

extension SearchModalitiesTests {
    func testSyntheticTracksCannotLeakAcrossScopes() {
        for scope in SearchModality.allCases {
            XCTAssertEqual(MediaScopePolicy.includes(moment: .video, stillImage: true, scope: scope), scope == .images)
            XCTAssertFalse(MediaScopePolicy.includesSpeech(stillImage: true, hasVideo: true, scope: scope))
        }
        XCTAssertTrue(MediaScopePolicy.includes(moment: .audio, stillImage: false, scope: .audio))
        XCTAssertFalse(MediaScopePolicy.includes(moment: .video, stillImage: false, scope: .audio))
        XCTAssertTrue(MediaScopePolicy.includes(moment: .video, stillImage: false, scope: .video))
        XCTAssertFalse(MediaScopePolicy.includes(moment: .audio, stillImage: false, scope: .images))
        XCTAssertFalse(MediaScopePolicy.includesSpeech(stillImage: false, hasVideo: false, scope: .video))
        XCTAssertTrue(MediaScopePolicy.includesSpeech(stillImage: false, hasVideo: true, scope: .audio))
        XCTAssertTrue(MediaScopePolicy.includesSpeech(stillImage: false, hasVideo: true, scope: .video))
    }
}

extension SearchModalitiesTests {
    func testLegacyMediaWithoutTextPreferenceKeepsBasicTextInAll() {
        let suite = "SearchModalities-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let previousMode = DeepSearch.mode
        defer {
            DeepSearch.mode = previousMode
            defaults.removePersistentDomain(forName: suite)
        }
        DeepSearch.mode = .media
        let capabilities = SearchPreferences.capabilities(defaults)
        XCTAssertTrue(capabilities.text, "An old media search style is not consent to disable text in All")
        XCTAssertEqual(capabilities.readyLanes(mode: .all, pro: true, clipReady: false, gemmaReady: false), [.text])
        defaults.set(false, forKey: "searchTextEnabled")
        XCTAssertFalse(SearchPreferences.capabilities(defaults).text, "An explicit disabled preference remains authoritative")
    }
}

extension SearchModalitiesTests {
    @MainActor
    func testAllAfterImageFilterFusesTextAndImageWithoutPreparedTextModel() {
        let text = ClipItem(kind: .text, text: "banana smoothie recipe")
        let image = ClipItem(kind: .image, text: "")
        let unrelated = ClipItem(kind: .text, text: "quarterly ledger")
        let kind = SearchPreferences.kindFilter(afterSelecting: .all, current: .image)
        let scoped = [text, image, unrelated].filter { kind == nil || $0.kind == kind }
        let choices = SearchCapabilities(text: true, images: true, audio: true, video: true, imageModel: .clip)
        let ready = choices.readyLanes(mode: .all, pro: true, clipReady: true, gemmaReady: false)
        var lanes: [SearchModality: [UUID]] = [:]
        // The actual fallback ranker and fusion are exercised, with no model or DB.
        if ready.contains(.text) {
            lanes[.text] = SemanticRanker.smart(query: "banana", items: scoped, embedder: HashingEmbedder()).map(\.id)
        }
        if ready.contains(.images) { lanes[.images] = [image.id] }
        let result = SearchPreferences.fuse(lanes)
        XCTAssertTrue(result.contains(text.id))
        XCTAssertTrue(result.contains(image.id))
        XCTAssertFalse(result.contains(unrelated.id))
        XCTAssertEqual(result.count, 2)
    }

    @MainActor
    func testUnavailableMediaBackendStillReturnsMatchingTextInAll() {
        let text = ClipItem(kind: .text, text: "banana recipe")
        let choices = SearchCapabilities(text: true, images: true, audio: true, video: true, imageModel: .gemma2)
        let ready = choices.readyLanes(mode: .all, pro: true, clipReady: true, gemmaReady: false)
        XCTAssertEqual(ready, [.text])
        let textIDs = SemanticRanker.smart(query: "banana", items: [text], embedder: HashingEmbedder()).map(\.id)
        XCTAssertEqual(SearchPreferences.fuse([.text: textIDs]), [text.id])
    }

    func testCategorySelectionClearsContradictoryKindWithoutChangingMatchingKind() {
        XCTAssertNil(SearchPreferences.kindFilter(afterSelecting: .all, current: .image))
        XCTAssertNil(SearchPreferences.kindFilter(afterSelecting: .images, current: .text))
        XCTAssertNil(SearchPreferences.kindFilter(afterSelecting: .text, current: .image))
        XCTAssertNil(SearchPreferences.kindFilter(afterSelecting: .audio, current: .image))
        XCTAssertEqual(SearchPreferences.kindFilter(afterSelecting: .images, current: .image), .image)
        XCTAssertEqual(SearchPreferences.kindFilter(afterSelecting: .video, current: .file), .file)
        XCTAssertEqual(SearchPreferences.kindFilter(afterSelecting: .text, current: .link), .link)
    }
}
