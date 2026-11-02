import XCTest
@testable import Cliphoard

@MainActor
final class AllEnabledSearchFollowupTests: XCTestCase {
    func testEmptyAllKeepsMixedHistoryOrderInsteadOfDoubleBoostingPictures() {
        let recentText = ClipItem(kind: .text, text: "recent note")
        let oldPicture = ClipItem(kind: .image, text: "")
        let olderText = ClipItem(kind: .text, text: "older note")
        let scoped = [recentText, oldPicture, olderText]
        let lanes: [SearchModality: [UUID]] = [.text: scoped.map(\.id), .images: [oldPicture.id]]
        XCTAssertEqual(PanelViewModel.combineSearchResults(query: "", scoped: scoped, lanes: lanes).map(\.id), scoped.map(\.id))
    }

    func testSingleIndexedPictureRetainsCalibratedCollectionRequirement() {
        var vector = Array(repeating: Float(0), count: CLIPEmbedder.dimension)
        vector[0] = 1
        let picture = ClipItem(kind: .image, text: "")
        picture.embeddings[CLIPEmbedder.signature] = ModelEmbedding(vector: vector)
        XCTAssertTrue(ClipStore.rankImageMatches(queryVector: vector, items: [picture]).isEmpty,
                      "Do not apply the centred relevance floor to raw single-picture scores")
    }

    func testTypedAllDoesNotGiveEveryOCRPictureTwoCategoryVotes() {
        let text = ClipItem(kind: .text, text: "cat care")
        let pictures = (0..<30).map { ClipItem(kind: .image, text: "cat \($0)") }
        let pixelOnly = ClipItem(kind: .image, text: "")
        let ocrOnly = ClipItem(kind: .image, text: "cat label")
        let scoped = [text] + pictures + [pixelOnly, ocrOnly]
        let lanes: [SearchModality: [UUID]] = [
            .text: [text.id] + pictures.map(\.id) + [ocrOnly.id],
            .images: pictures.map(\.id) + [pixelOnly.id]
        ]
        let result = PanelViewModel.combineSearchResults(query: "cat", scoped: scoped, lanes: lanes,
                                                        balanceCLIPPictures: true).map(\.id)
        XCTAssertLessThanOrEqual(result.firstIndex(of: text.id)!, 1,
                                 "A top text match must compete with one image category, not thirty double votes")
        XCTAssertEqual(Set(result), Set(scoped.map(\.id)))
        XCTAssertEqual(result.count, scoped.count)
    }

    func testExplicitTextAndGemmaFusionRetainTheirExistingRankings() {
        let text = ClipItem(kind: .text, text: "cat")
        let picture = ClipItem(kind: .image, text: "cat OCR")
        let scoped = [text, picture]
        let textLane: [SearchModality: [UUID]] = [.text: [picture.id, text.id]]
        XCTAssertEqual(PanelViewModel.combineSearchResults(query: "cat", scoped: scoped, lanes: textLane).map(\.id), [picture.id, text.id])
        let gemmaLanes: [SearchModality: [UUID]] = [.text: [text.id, picture.id], .images: [picture.id]]
        XCTAssertEqual(PanelViewModel.combineSearchResults(query: "cat", scoped: scoped, lanes: gemmaLanes).map(\.id), SearchPreferences.fuse(gemmaLanes))
    }

    func testBrowseKeepsOnlyRequestedScopedItemsAndDoesNotInventMatches() {
        let text = ClipItem(kind: .text, text: "text")
        let image = ClipItem(kind: .image, text: "")
        let lanes: [SearchModality: [UUID]] = [.images: [image.id, image.id, UUID()]]
        XCTAssertEqual(PanelViewModel.combineSearchResults(query: " \n", scoped: [text, image], lanes: lanes).map(\.id), [image.id])
        XCTAssertTrue(PanelViewModel.combineSearchResults(query: "cat", scoped: [text, image], lanes: [:], balanceCLIPPictures: true).isEmpty)
    }

    func testPendingWrongDimensionAndUnrelatedSinglePictureAreNotMatches() {
        var vector = Array(repeating: Float(0), count: CLIPEmbedder.dimension)
        vector[0] = 1
        let picture = ClipItem(kind: .image, text: "")
        picture.embeddings[CLIPEmbedder.signature] = ModelEmbedding(vector: vector)
        XCTAssertTrue(ClipStore.rankImageMatches(queryVector: [], items: [picture]).isEmpty)
        XCTAssertTrue(ClipStore.rankImageMatches(queryVector: [1], items: [picture]).isEmpty)
        var unrelated = vector; unrelated[0] = 0; unrelated[1] = 1
        XCTAssertTrue(ClipStore.rankImageMatches(queryVector: unrelated, items: [picture]).isEmpty)
        XCTAssertTrue(ClipStore.rankImageMatches(queryVector: vector, items: [picture], limit: 0).isEmpty)
        picture.embeddings.removeAll()
        XCTAssertTrue(ClipStore.rankImageMatches(queryVector: vector, items: [picture]).isEmpty)
    }

    func testIndexStatusSeparatesPreparedModelFromIndexedPictures() {
        let empty = PictureIndexStatus(indexed: 0, eligible: 5, working: false)
        XCTAssertTrue(empty.message.contains("not indexed yet"))
        XCTAssertTrue(empty.canIndex)
        let busy = PictureIndexStatus(indexed: 2, eligible: 5, working: true)
        XCTAssertFalse(busy.canIndex)
        XCTAssertTrue(busy.message.contains("background"))
        XCTAssertEqual(busy.remaining, 3)
        XCTAssertFalse(PictureIndexStatus(indexed: 5, eligible: 5, working: false).canIndex)
        XCTAssertFalse(PictureIndexStatus(indexed: 0, eligible: 0, working: false).canIndex)
    }

    func testSinglePictureStatusExplainsDescriptionLimitAndRetainsBasicSearch() {
        for eligible in [1, 5] {
            let status = PictureIndexStatus(indexed: 1, eligible: eligible, working: false)
            XCTAssertTrue(status.message.contains("at least two indexed pictures"))
            XCTAssertTrue(status.message.contains("basic text and OCR matching remain available"))
            XCTAssertFalse(status.message.contains("searchable by description"))
            XCTAssertEqual(status.canIndex, eligible > 1)
        }
    }

    func testReferenceImageQueryKeepsSimilarityOrderWithoutTypedText() {
        let newest = ClipItem(kind: .image, text: "")
        let closest = ClipItem(kind: .image, text: "")
        XCTAssertEqual(PanelViewModel.combineSearchResults(query: "", scoped: [newest, closest],
            lanes: [.images: [closest.id, newest.id]], browseChronologically: false).map(\.id), [closest.id, newest.id])
    }
}
