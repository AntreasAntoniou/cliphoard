import XCTest
import Combine
@testable import Yank

/// TP-11: concurrency safety of the two background (re)indexing passes,
/// `ClipStore.reindexStale` and `ClipStore.reclassifyAllTags`.
///
/// Both passes publish progress through the `@Published` `indexing` state on the
/// main actor and run a cancellable `Task`; starting a new pass cancels the
/// previous one so overlapping model/basket changes coalesce instead of running
/// two passes that fight over the published state. These tests pin, without
/// editing the source:
///   1. published `IndexingProgress` is monotonic (`done` never decreases, with a
///      fixed `total`) within a pass and the publisher returns to `nil` exactly
///      once for a clean single pass; overlapping calls coalesce to a single
///      idle end-state with a rebuild-correct index (no two live passes);
///   2. an `add()` interleaved *during* a reindex leaves `tagIndex` byte-for-byte
///      identical to a full rebuild — no stale snapshot is written (mirrors the
///      BL-08 equality check in `IncrementalIndexTests`).
///
/// The store runs entirely through the deterministic `HashingEmbedder` (no
/// CoreML model is bundled in the test target), so results are reproducible and
/// no CoreML is needed.
@MainActor
final class ReindexConcurrencyTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        Feedback.soundEnabled = false
        DeepSearch.level = .normal   // ingest embeds + tags via HashingEmbedder
    }

    override func tearDown() {
        cancellables.removeAll()
        DeepSearch.level = .off
        super.tearDown()
    }

    private func tempStore() -> ClipStore {
        ClipStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoTests-reidx-\(UUID().uuidString)"))
    }

    // MARK: tagIndex equality helpers (mirror IncrementalIndexTests / BL-08)

    /// The index a full `rebuildTagIndex()` would produce: for each active-model
    /// tag, the items carrying it in `items` order, with no empty buckets.
    private func expectedIndex(_ store: ClipStore) -> [Int: [UUID]] {
        let sig = EmbedderProvider.active.signature
        var index: [Int: [UUID]] = [:]
        for item in store.items {
            for tag in item.embeddings[sig]?.tags ?? [] {
                index[tag, default: []].append(item.id)
            }
        }
        return index
    }

    /// The live, incrementally maintained index reconstructed from `tagIndex`.
    private func actualIndex(_ store: ClipStore) -> [Int: [UUID]] {
        let sig = EmbedderProvider.active.signature
        var ids: [Int: [UUID]] = [:]
        for tag in Set(store.items.flatMap { $0.embeddings[sig]?.tags ?? [] }) {
            ids[tag] = store.items(taggedWith: tag).map { $0.id }
        }
        return ids
    }

    /// Add `texts` while the embedder is bypassed so each clip is left *stale*
    /// (no active-signature embedding) — the population `reindexStale` works on.
    private func addStale(_ texts: [String], to store: ClipStore) {
        let prior = DeepSearch.level
        DeepSearch.level = .off          // `add()` skips ClipIndexer.index at .off
        for t in texts { store.add(ClipItem(kind: .text, text: t)) }
        DeepSearch.level = prior
    }

    /// Subscribe to the published `indexing` state and record every emission
    /// (oldest first) until it returns to `nil` *after* a pass has started — the
    /// completion seam the passes already expose. The leading idle `nil` that
    /// `@Published` replays to a fresh subscriber is recorded but does not satisfy
    /// the wait.
    private func recordUntilIdle(_ store: ClipStore) async -> [ClipStore.IndexingProgress?] {
        var log: [ClipStore.IndexingProgress?] = []
        let idle = XCTestExpectation(description: "indexing returns to nil")
        var sawWork = false
        var fulfilled = false
        store.$indexing
            .sink { progress in
                log.append(progress)
                if progress != nil {
                    sawWork = true
                } else if sawWork && !fulfilled {
                    fulfilled = true
                    idle.fulfill()
                }
            }
            .store(in: &cancellables)
        await fulfillment(of: [idle], timeout: 5)
        return log
    }

    /// Assert that a recorded emission stream is well-formed: every maximal run of
    /// non-`nil` emissions (one pass segment) has a fixed `total`, a non-decreasing
    /// `done`, and `done <= total` throughout.
    private func assertSegmentsMonotonic(_ log: [ClipStore.IndexingProgress?],
                                         file: StaticString = #filePath, line: UInt = #line) {
        var segmentTotal: Int?
        var lastDone = -1
        for entry in log {
            guard let p = entry else { segmentTotal = nil; lastDone = -1; continue }
            if let t = segmentTotal {
                XCTAssertEqual(p.total, t, "total must stay fixed within a pass", file: file, line: line)
            } else {
                segmentTotal = p.total
                lastDone = -1
            }
            XCTAssertGreaterThanOrEqual(p.done, lastDone, "done must never decrease within a pass", file: file, line: line)
            XCTAssertLessThanOrEqual(p.done, p.total, "done must never exceed total", file: file, line: line)
            lastDone = p.done
        }
    }

    /// Count the maximal non-`nil` segments that actually ran to completion
    /// (`done == total`, `total > 0`). A pass that was cancelled by a later pass
    /// breaks at its first `Task.isCancelled` check and so NEVER publishes a
    /// `done == total` emission — only the surviving (coalesced) pass does. Two
    /// independent passes both running to completion would each contribute one.
    private func completedSegmentCount(_ log: [ClipStore.IndexingProgress?]) -> Int {
        var completed = 0
        var segmentDidComplete = false
        for entry in log {
            guard let p = entry else {
                if segmentDidComplete { completed += 1 }
                segmentDidComplete = false
                continue
            }
            if p.total > 0 && p.done == p.total { segmentDidComplete = true }
        }
        if segmentDidComplete { completed += 1 }
        return completed
    }

    // MARK: 1 — overlapping passes coalesce to a single idle, rebuild-correct end

    func testOverlappingReindexAndReclassifyCoalesceToSinglePass() async {
        let store = tempStore()

        // A pool of already-embedded items → real work for `reclassifyAllTags`.
        for i in 0..<20 {
            store.add(ClipItem(kind: .text, text: "embedded sample number \(i) lorem ipsum"))
        }
        // A pool of stale items → real work for `reindexStale`, simultaneously.
        addStale((0..<20).map { "stale sample number \($0) dolor sit amet" }, to: store)

        var log: [ClipStore.IndexingProgress?] = []
        let idle = XCTestExpectation(description: "indexing settles to nil")
        var sawWork = false
        var fulfilled = false
        store.$indexing
            .sink { progress in
                log.append(progress)
                if progress != nil {
                    sawWork = true
                } else if sawWork && !fulfilled {
                    fulfilled = true
                    idle.fulfill()
                }
            }
            .store(in: &cancellables)

        // Fire both back-to-back on the main actor: the second call cancels the
        // first's task, so the two passes coalesce rather than running two live
        // passes that fight over the published `indexing` state.
        store.reclassifyAllTags()
        store.reindexStale()

        await fulfillment(of: [idle], timeout: 5)
        // Let any cancelled-pass tail drain so the end-state is stable.
        for _ in 0..<200 { await Task.yield() }

        // Coalescing safety: every published progress segment is monotonic with a
        // fixed total (no pass ever publishes a decreasing `done`).
        assertSegmentsMonotonic(log)

        // The overlap settles to a single idle end-state…
        XCTAssertNil(store.indexing, "the coalesced overlap must settle back to idle")
        XCTAssertGreaterThanOrEqual(log.contains { $0 != nil } ? 1 : 0, 1,
                                    "at least one pass must have published progress")

        // Coalescing, asserted directly: the second call cancels the first's task,
        // so the cancelled pass breaks at its first `Task.isCancelled` check and
        // NEVER reaches `done == total`. Exactly ONE pass runs to completion. A
        // non-cancelling implementation that ran both passes fully and sequentially
        // would record TWO completed segments here and fail this assertion.
        XCTAssertEqual(completedSegmentCount(log), 1,
                       "overlapping passes must coalesce: exactly one pass runs to done == total")

        // …and the tag index it leaves behind is byte-identical to a full rebuild
        // over `items` — no pass wrote (or left behind) a stale snapshot.
        XCTAssertEqual(actualIndex(store), expectedIndex(store),
                       "tagIndex must equal a full rebuild after the coalesced overlap")
    }

    // MARK: 2 — an add() during a reindex never persists a stale snapshot

    func testConcurrentAddDuringReindexDoesNotWriteStaleSnapshot() async {
        let store = tempStore()

        // A larger stale pool so the reindex spans several yield points, giving
        // the interleaved add a window to land mid-pass.
        addStale((0..<24).map { "concurrent stale entry \($0) the quick brown fox" }, to: store)

        // Interleave exactly one add the first time we observe the pass in flight.
        var didAdd = false
        let added = XCTestExpectation(description: "interleaved add committed")
        let idle = XCTestExpectation(description: "reindex returns to nil")
        var sawWork = false
        var fulfilled = false
        store.$indexing
            .sink { progress in
                if progress != nil {
                    sawWork = true
                    if !didAdd {
                        didAdd = true
                        // Embedded add (level is .normal) → exercises the
                        // incremental tagIndex path concurrently with the pass's
                        // own rebuildTagIndex() calls.
                        store.add(ClipItem(kind: .text, text: "interleaved live add during reindex"))
                        added.fulfill()
                    }
                } else if sawWork && !fulfilled {
                    fulfilled = true
                    idle.fulfill()
                }
            }
            .store(in: &cancellables)

        store.reindexStale()

        await fulfillment(of: [added, idle], timeout: 5)
        // Let the pass fully drain past the interleaved add.
        for _ in 0..<200 { await Task.yield() }
        XCTAssertTrue(didAdd, "the add must have been interleaved during the pass")

        // Once the dust settles, the incrementally maintained index must be
        // byte-identical to a full rebuild — no stale snapshot survived.
        XCTAssertEqual(actualIndex(store), expectedIndex(store),
                       "tagIndex must equal a full rebuild after an add interleaved with reindex")

        // The pass plus the eager add must have embedded everything for the
        // active model — nothing is left stale. (merged from variant B)
        for item in store.items {
            XCTAssertFalse(ClipIndexer.isStale(item),
                           "every item must be embedded for the active model after the pass")
        }
    }

    // MARK: 1b — a single reindex pass alone is monotonic and ends exactly once

    func testSingleReindexPassIsMonotonicAndEndsExactlyOnce() async {
        let store = tempStore()
        addStale((0..<24).map { "single pass stale \($0) sample text here" }, to: store)

        store.reindexStale()
        let log = await recordUntilIdle(store)

        // A clean (non-overlapped) pass returns to nil exactly once — counting
        // only emissions from the moment work began (the leading idle replay is
        // excluded).
        let firstWork = log.firstIndex(where: { $0 != nil }) ?? log.count
        let nilCount = log[firstWork...].filter { $0 == nil }.count
        XCTAssertEqual(nilCount, 1, "a single pass returns to nil exactly once")

        assertSegmentsMonotonic(log)

        let progresses = log.compactMap { $0 }
        XCTAssertFalse(progresses.isEmpty, "the pass must publish progress")
        XCTAssertEqual(progresses.last!.done, progresses.last!.total, "pass ends at done == total")
        XCTAssertEqual(actualIndex(store), expectedIndex(store),
                       "tagIndex equals a full rebuild after the pass")
    }

    // MARK: 1c — a single reclassify pass alone is monotonic and ends exactly once

    func testSingleReclassifyPassIsMonotonicAndEndsExactlyOnce() async {
        let store = tempStore()
        for i in 0..<24 {
            store.add(ClipItem(kind: .text, text: "reclassify sample \(i) the lazy dog jumps"))
        }

        store.reclassifyAllTags()
        let log = await recordUntilIdle(store)

        let firstWork = log.firstIndex(where: { $0 != nil }) ?? log.count
        let nilCount = log[firstWork...].filter { $0 == nil }.count
        XCTAssertEqual(nilCount, 1, "a single reclassify pass returns to nil exactly once")

        assertSegmentsMonotonic(log)

        let progresses = log.compactMap { $0 }
        XCTAssertFalse(progresses.isEmpty, "the pass must publish progress")
        XCTAssertEqual(progresses.last!.done, progresses.last!.total, "pass ends at done == total")
        XCTAssertEqual(actualIndex(store), expectedIndex(store),
                       "tagIndex equals a full rebuild after reclassify")
    }
}
