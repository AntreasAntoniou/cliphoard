import XCTest
@testable import Cliphoard

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
    override func setUp() {
        super.setUp()
        Feedback.soundEnabled = false
        DeepSearch.level = .normal // a tier is selected so ingest embeds (active = hashing fallback here)
    }
    override func tearDown() { DeepSearch.level = .off; super.tearDown() }

    private func tempStore() -> ClipStore {
        ClipStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoTests-deep-\(UUID().uuidString)"))
    }

    func testAddEmbedsAndTags() {
        let store = tempStore()
        let item = ClipItem(kind: .text, text: "select * from users where id = 1")
        store.add(item)
        let sig = EmbedderProvider.active.signature
        XCTAssertNotNil(item.embeddings[sig]?.vector)
        // General is a facet cube → one tag per dimension (not a flat top-5).
        XCTAssertEqual(item.embeddings[sig]?.tags.count, TagSpace.dimensionCount)
    }

    func testTagIndexLookupIsPopulated() {
        let store = tempStore()
        let item = ClipItem(kind: .text, text: "git commit -m fix the parser bug")
        store.add(item)
        let tag = try! XCTUnwrap(item.embeddings[EmbedderProvider.active.signature]?.tags.first)
        XCTAssertTrue(store.items(taggedWith: tag).contains { $0.id == item.id })
    }

    func testAddCachesForActiveModelAndIsNotStale() {
        let store = tempStore()
        let item = ClipItem(kind: .text, text: "hello there")
        store.add(item)
        XCTAssertTrue(item.isEmbedded(by: EmbedderProvider.active.signature))
        XCTAssertFalse(ClipIndexer.isStale(item), "freshly indexed item must not be stale")
    }

    func testDegenerateEmbeddingIsStale() {
        let sig = EmbedderProvider.active.signature   // hashing-256
        let dim = EmbedderProvider.active.dimension

        let zero = ClipItem(kind: .text, text: "zero")
        zero.embeddings[sig] = ModelEmbedding(vector: [Float](repeating: 0, count: dim), tags: [])
        XCTAssertTrue(ClipIndexer.isStale(zero), "all-zero vector is degenerate -> stale (retry)")

        let wrongLen = ClipItem(kind: .text, text: "wrong")
        wrongLen.embeddings[sig] = ModelEmbedding(vector: [1, 2, 3], tags: [])
        XCTAssertTrue(ClipIndexer.isStale(wrongLen), "wrong-length vector -> stale")

        let ok = ClipItem(kind: .text, text: "ok")
        var v = [Float](repeating: 0, count: dim); v[5] = 0.5
        ok.embeddings[sig] = ModelEmbedding(vector: v, tags: [1])
        XCTAssertFalse(ClipIndexer.isStale(ok), "right-length non-zero vector -> not stale")
    }

    func testUnprocessedItemIsStale() {
        let fresh = ClipItem(kind: .text, text: "never embedded")
        XCTAssertTrue(ClipIndexer.isStale(fresh), "no embedding for active model → stale")
        let otherModel = ClipItem(kind: .text, text: "other model only")
        otherModel.embeddings["some-other-model-999"] = ModelEmbedding(vector: [0, 0], tags: [])
        XCTAssertTrue(ClipIndexer.isStale(otherModel), "embedded only by a different model → stale")
    }

    func testPerModelCacheIsKeptAcrossModels() {
        let item = ClipItem(kind: .text, text: "cached by two models")
        item.embeddings["ogma-small-256"] = ModelEmbedding(vector: [1, 0], tags: [3])
        item.embeddings["ogma-micro-128"] = ModelEmbedding(vector: [0, 1], tags: [7])
        XCTAssertTrue(item.isEmbedded(by: "ogma-small-256"))
        XCTAssertTrue(item.isEmbedded(by: "ogma-micro-128"))   // round-trip switch is free
        XCTAssertEqual(item.embeddings.count, 2)
    }

    func testVectorsPersistAndReload() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoTests-persist-\(UUID().uuidString)")
        do {
            let store = ClipStore(directory: dir)
            store.add(ClipItem(kind: .text, text: "persisted vector entry"))
        }
        let reloaded = ClipStore(directory: dir)
        let sig = EmbedderProvider.active.signature
        XCTAssertNotNil(reloaded.items.first?.embeddings[sig]?.vector)
        XCTAssertEqual(reloaded.items.first?.embeddings[sig]?.tags.count, TagSpace.dimensionCount)
        XCTAssertFalse(ClipIndexer.isStale(reloaded.items.first!), "reload shouldn't need reprocessing")
    }
}
