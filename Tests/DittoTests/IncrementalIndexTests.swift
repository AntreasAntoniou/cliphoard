import XCTest
@testable import Ditto

/// BL-08: the incrementally maintained `tagIndex` (updated on add/delete) must
/// stay byte-for-byte identical to a full rebuild over `items`.
@MainActor
final class IncrementalIndexTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Feedback.soundEnabled = false
        DeepSearch.level = .normal   // ensure ingest embeds + tags
    }
    override func tearDown() { DeepSearch.level = .off; super.tearDown() }

    private func tempStore() -> ClipStore {
        ClipStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoTests-incr-\(UUID().uuidString)"))
    }

    /// The index a full `rebuildTagIndex()` would produce for the current items:
    /// for each tag, the items carrying it, in `items` order, no empty buckets.
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

    private func actualIndex(_ store: ClipStore) -> [Int: [UUID]] {
        // Reconstruct id ordering from the published tagIndex.
        let sig = EmbedderProvider.active.signature
        var ids: [Int: [UUID]] = [:]
        for tag in Set(store.items.flatMap { $0.embeddings[sig]?.tags ?? [] }) {
            ids[tag] = store.items(taggedWith: tag).map { $0.id }
        }
        return ids
    }

    func testTagIndexMatchesRebuildAfterAdds() {
        let store = tempStore()
        for text in ["select * from users", "https://example.com/page",
                     "git commit -m fix", "the quick brown fox", "lorem ipsum dolor"] {
            store.add(ClipItem(kind: .text, text: text))
        }
        XCTAssertEqual(actualIndex(store), expectedIndex(store),
                       "incremental tagIndex must equal a full rebuild after adds")
    }

    func testTagIndexMatchesRebuildAfterDeletes() {
        let store = tempStore()
        let items = ["alpha note", "beta config yaml", "gamma python def foo",
                     "delta url http://x.io", "epsilon plain text"].map {
            ClipItem(kind: .text, text: $0)
        }
        items.forEach { store.add($0) }
        // Delete a couple from the middle/ends.
        store.delete(items[1])
        store.delete(items[3])
        XCTAssertEqual(actualIndex(store), expectedIndex(store),
                       "incremental tagIndex must equal a full rebuild after deletes")
        // The deleted items must no longer appear in any bucket.
        let sig = EmbedderProvider.active.signature
        for gone in [items[1], items[3]] {
            for tag in gone.embeddings[sig]?.tags ?? [] {
                XCTAssertFalse(store.items(taggedWith: tag).contains { $0.id == gone.id })
            }
        }
    }

    func testTagIndexMatchesRebuildAfterPinTogglesThenAdd() {
        // Regression: togglePin reorders items globally; the index must still
        // match a full rebuild (Cassandra caught this in the original diff).
        let store = tempStore()
        let items = ["one line", "two lines here", "three things now",
                     "four score and", "five alive", "six sided die"].map {
            ClipItem(kind: .text, text: $0)
        }
        items.forEach { store.add($0) }
        store.togglePin(items[3])   // pin a middle item → global reorder
        XCTAssertEqual(actualIndex(store), expectedIndex(store),
                       "index must equal a full rebuild after a pin toggle")
        store.togglePin(items[1])   // pin another
        store.add(ClipItem(kind: .text, text: "added after pins"))
        XCTAssertEqual(actualIndex(store), expectedIndex(store),
                       "index must stay rebuild-identical across pin toggles + add")
        store.togglePin(items[3])   // unpin
        XCTAssertEqual(actualIndex(store), expectedIndex(store),
                       "index must equal a full rebuild after an unpin")
    }

    func testTagIndexMatchesRebuildAfterDuplicateBumpThenAdd() {
        let store = tempStore()
        let a = ClipItem(kind: .text, text: "shared content one")
        let b = ClipItem(kind: .text, text: "shared content two")
        store.add(a); store.add(b)
        // Re-add `a`'s signature: dedup-bumps `a` and reorders items without a
        // rebuild. A subsequent new add must still yield a rebuild-identical index.
        store.add(ClipItem(kind: .text, text: "shared content one"))
        store.add(ClipItem(kind: .text, text: "fresh distinct entry"))
        XCTAssertEqual(actualIndex(store), expectedIndex(store),
                       "index must re-sync to items order across bump-then-add")
    }
}
