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

    /// Wave 4 retired General's four abstract axes AND (design §4) its topical
    /// word tags, which duplicated deterministic detectors. General therefore has
    /// an EMPTY model vocabulary: an empty vocabulary cannot mis-tag anything.
    func testGeneralHasNoModelVocabulary() {
        XCTAssertEqual(TagSpace.count, 0)
        XCTAssertTrue(TagSpace.names.isEmpty)
        XCTAssertTrue(TagBaskets.general.topical.isEmpty)
    }

    func testClassifyReturnsFiveValidTags() {
        let v = e.embed("def foo(): return 1   # some python code")
        let tags = TagSpace.classify(v, embedder: e, topK: 5)
        XCTAssertLessThanOrEqual(tags.count, 5)
        XCTAssertTrue(tags.allSatisfy { (0..<TagSpace.count).contains($0) })
        XCTAssertEqual(Set(tags).count, tags.count, "tags should be distinct")
    }

    func testNearestTagForQuery() {
        struct URLAlignedEmbedder: TextEmbedder {
            let dimension = 2
            let signature = "url-aligned-v1"
            func embed(_ text: String) -> [Float] {
                text == "url" || text.contains("example.com") ? [1, 0] : [0, 1]
            }
        }
        let embedder = URLAlignedEmbedder()
        // With General's vocabulary empty there is no preset tag to be nearest TO,
        // so tag-mode search correctly yields nothing rather than a wrong bucket.
        XCTAssertNil(TagSpace.nearestTag(toQuery: "https://example.com/page", embedder: embedder))
        // Under a specialist overlay the mechanism still works.
        TagBaskets.overlayID = "dev"
        defer { TagBaskets.overlayID = nil }
        XCTAssertNotNil(TagSpace.nearestTag(toQuery: "git rebase --onto main", embedder: HashingEmbedder()))
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
        // General is hybrid → 0–4 axis tags plus at most 3 topical tags.
        XCTAssertLessThanOrEqual(item.embeddings[sig]?.tags.count ?? .max, 7)
    }

    func testTagIndexLookupIsPopulated() {
        let store = tempStore()
        let item = ClipItem(kind: .text, text: "git commit -m fix the parser bug")
        var vector = [Float](repeating: 0, count: EmbedderProvider.active.dimension)
        vector[0] = 1
        item.embeddings[EmbedderProvider.active.signature] =
            ModelEmbedding(vector: vector, tags: [0])
        store.add(item)
        XCTAssertTrue(store.items(taggedWith: 0).contains { $0.id == item.id })
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
        XCTAssertLessThanOrEqual(reloaded.items.first?.embeddings[sig]?.tags.count ?? .max, 7)
        XCTAssertFalse(ClipIndexer.isStale(reloaded.items.first!), "reload shouldn't need reprocessing")
    }
}

@MainActor
final class UserTagModeTests: XCTestCase {
    func testTagModeResolvesExactUserTagBeforeAutomaticCategories() {
        let oldMode = DeepSearch.mode
        let oldLevel = DeepSearch.level
        defer { DeepSearch.mode = oldMode; DeepSearch.level = oldLevel }
        DeepSearch.mode = .tag
        DeepSearch.level = .off
        Feedback.soundEnabled = false

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoTests-user-tag-mode-\(UUID().uuidString)")
        let store = ClipStore(directory: dir)
        let item = ClipItem(kind: .text, text: "customer follow-up")
        item.userTags = ["client-acme"]
        store.add(item)
        let model = PanelViewModel(store: store)
        model.query = "CLIENT-ACME"

        XCTAssertEqual(model.results.map(\.id), [item.id])
    }

    func testInspectorIntentTracksClipAndTagFocus() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoTests-inspector-\(UUID().uuidString)")
        let store = ClipStore(directory: dir)
        let item = ClipItem(kind: .text, text: "inspect me")
        store.add(item)
        let model = PanelViewModel(store: store)

        model.inspect(item, focusTags: true)
        XCTAssertEqual(model.inspectedItem?.id, item.id)
        XCTAssertTrue(model.inspectorFocusTags)
        model.closeInspector()
        XCTAssertNil(model.inspectedItem)
    }
}

final class LengthConfidenceTests: XCTestCase {
    private let e = HashingEmbedder()

    func testRampsToFullTrustAtTwelveChars() {
        XCTAssertEqual(SemanticRanker.lengthConfidence(ClipItem(kind: .text, text: "c")),
                       1.0 / 12.0, accuracy: 0.001)
        XCTAssertEqual(SemanticRanker.lengthConfidence(ClipItem(kind: .text, text: "styled")),
                       0.5, accuracy: 0.001)
        XCTAssertEqual(SemanticRanker.lengthConfidence(ClipItem(kind: .text, text: "a dozen chars or more")),
                       1.0, accuracy: 0.001)
    }

    /// The "fun" bug: a hub-like short clip whose stored vector happens to sit
    /// near the query must NOT clear the neural floor, while a longer clip with
    /// the same cosine must. Vectors are pinned to the query's own embedding
    /// (cosine 1.0) to isolate the confidence weighting.
    func testShortHubClipIsSuppressedInNeural() {
        let qv = e.embed("fun", query: true)
        let hub = ClipItem(kind: .text, text: "c")
        let real = ClipItem(kind: .text, text: "board game night with friends")
        for item in [hub, real] {
            item.embeddings[e.signature] = ModelEmbedding(vector: qv, tags: [])
        }
        let ranked = SemanticRanker.neural(query: "fun", items: [hub, real], embedder: e)
        // real: cos 1.0 × conf 1.0 = 1.0 ≥ floor → kept, and ranks first.
        // hub:  cos 1.0 × conf 1/12 ≈ 0.083 < floor → only reachable via fallback.
        XCTAssertEqual(ranked.first?.text, "board game night with friends")
        XCTAssertEqual(ranked.count, 1, "suppressed hub must not pad a list that has a real hit")
    }

    /// When nothing clears the floor, the top-K fallback still surfaces the
    /// closest clips — a short TRUE hit is shown rather than an empty strip.
    func testFallbackStillShowsShortClipsWhenNothingElseMatches() {
        let hub = ClipItem(kind: .text, text: "c")
        hub.embeddings[e.signature] = ModelEmbedding(vector: e.embed("fun", query: true), tags: [])
        let ranked = SemanticRanker.neural(query: "fun", items: [hub], embedder: e)
        XCTAssertEqual(ranked.count, 1, "top-K fallback keeps the strip populated")
    }
}
