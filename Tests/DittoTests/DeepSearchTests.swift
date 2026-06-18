import XCTest
@testable import Ditto

final class EmbeddingTests: XCTestCase {
    private let e = HashingEmbedder()

    func testDeterministicAcrossCalls() {
        XCTAssertEqual(e.embed("hello world"), e.embed("hello world"))
    }

    func testStableHashIsProcessIndependent() {
        // FNV-1a must be fixed so persisted vectors stay valid across launches.
        XCTAssertEqual(HashingEmbedder.fnv1a("ditto"), HashingEmbedder.fnv1a("ditto"))
        XCTAssertNotEqual(HashingEmbedder.fnv1a("a"), HashingEmbedder.fnv1a("b"))
    }

    func testL2Normalised() {
        let v = e.embed("some sample text here")
        let norm = (v.reduce(0) { $0 + $1 * $1 }).squareRoot()
        XCTAssertEqual(norm, 1, accuracy: 0.001)
    }

    func testCosineSelfIsOne() {
        let v = e.embed("python error stack trace")
        XCTAssertEqual(SemanticRanker.cosine(v, v), 1, accuracy: 0.001)
    }

    func testSimilarTextScoresHigher() {
        let a = e.embed("the quick brown fox jumps")
        let b = e.embed("the quick brown dog jumps")
        let c = e.embed("zzz totally different content")
        XCTAssertGreaterThan(SemanticRanker.cosine(a, b), SemanticRanker.cosine(a, c))
    }
}

@MainActor
final class TagSpaceTests: XCTestCase {
    private let e = HashingEmbedder()

    func testHasOneHundredTags() {
        XCTAssertEqual(TagSpace.count, 100)
        XCTAssertEqual(TagSpace.names.count, 100)
    }

    func testClassifyReturnsFiveValidTags() {
        let v = e.embed("def foo(): return 1   # some python code")
        let tags = TagSpace.classify(v, embedder: e, topK: 5)
        XCTAssertEqual(tags.count, 5)
        XCTAssertTrue(tags.allSatisfy { (0..<100).contains($0) })
        XCTAssertEqual(Set(tags).count, 5, "tags should be distinct")
    }

    func testNearestTagForQuery() {
        XCTAssertNotNil(TagSpace.nearestTag(toQuery: "https://example.com/page", embedder: e))
    }
}

final class EssenceRankingTests: XCTestCase {
    private let e = HashingEmbedder()

    func testSubstringMatchRanksFirst() {
        let hit = ClipItem(kind: .text, text: "banana smoothie recipe")
        let miss = ClipItem(kind: .text, text: "unrelated note about automobiles")
        let ranked = SemanticRanker.essence(query: "banana", items: [miss, hit], embedder: e)
        XCTAssertEqual(ranked.first?.text, "banana smoothie recipe")
    }
}

@MainActor
final class IngestIndexingTests: XCTestCase {
    override func setUp() { super.setUp(); Feedback.soundEnabled = false }

    private func tempStore() -> ClipStore {
        ClipStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoTests-deep-\(UUID().uuidString)"))
    }

    func testAddEmbedsAndTags() {
        let store = tempStore()
        let item = ClipItem(kind: .text, text: "select * from users where id = 1")
        store.add(item)
        XCTAssertNotNil(item.vector)
        XCTAssertEqual(item.tagIDs?.count, 5)
    }

    func testTagIndexLookupIsPopulated() {
        let store = tempStore()
        let item = ClipItem(kind: .text, text: "git commit -m fix the parser bug")
        store.add(item)
        let tag = try! XCTUnwrap(item.tagIDs?.first)
        XCTAssertTrue(store.items(taggedWith: tag).contains { $0.id == item.id })
    }

    func testAddStampsVectorModelAndIsNotStale() {
        let store = tempStore()
        let item = ClipItem(kind: .text, text: "hello there")
        store.add(item)
        XCTAssertEqual(item.vectorModel, EmbedderProvider.active.signature)
        XCTAssertFalse(ClipIndexer.isStale(item), "freshly indexed item must not be stale")
    }

    func testUnprocessedItemIsStale() {
        let fresh = ClipItem(kind: .text, text: "never embedded")
        XCTAssertTrue(ClipIndexer.isStale(fresh), "nil-vector item is stale")
        let wrongModel = ClipItem(kind: .text, text: "other model")
        wrongModel.vector = [0, 0]; wrongModel.vectorModel = "some-other-model-999"
        XCTAssertTrue(ClipIndexer.isStale(wrongModel), "different-model item is stale")
    }

    func testVectorModelPersists() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoTests-vm-\(UUID().uuidString)")
        do {
            let store = ClipStore(directory: dir)
            store.add(ClipItem(kind: .text, text: "remember my model"))
        }
        let reloaded = ClipStore(directory: dir)
        XCTAssertEqual(reloaded.items.first?.vectorModel, EmbedderProvider.active.signature)
        // Reload must not leave items stale (no redundant reprocessing needed).
        XCTAssertFalse(ClipIndexer.isStale(reloaded.items.first!))
    }

    func testVectorsPersistAndReload() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoTests-persist-\(UUID().uuidString)")
        do {
            let store = ClipStore(directory: dir)
            store.add(ClipItem(kind: .text, text: "persisted vector entry"))
        }
        let reloaded = ClipStore(directory: dir)
        XCTAssertNotNil(reloaded.items.first?.vector)
        XCTAssertEqual(reloaded.items.first?.tagIDs?.count, 5)
    }
}
