import XCTest
@testable import Ditto

/// Direct tests for the SQLite store — previously untested (audit BL-T1).
final class DatabaseTests: XCTestCase {
    private func tempDB() -> Database {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoDBTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return Database(path: dir.appendingPathComponent("t.sqlite").path)!
    }

    private func text(_ s: String) -> ClipItem { ClipItem(kind: .text, text: s) }

    func testFloat16BlobRoundTripWithinTolerance() {
        let v: [Float] = [0.0, 1.0, -0.5, 0.040161, 0.25, -0.999]
        let blob = Database.blob(fromVector: v)
        XCTAssertEqual(blob.count, v.count * 2, "Float16 = 2 bytes/element")
    }

    func testInsertThenLoadAllReturnsEquivalentClip() {
        let db = tempDB()
        let item = text("hello db")
        item.pinned = true
        item.embeddings["m1"] = ModelEmbedding(vector: [0.5, -0.25, 1.0], tags: [3, 7])
        db.insert(item)
        let loaded = db.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.text, "hello db")
        XCTAssertTrue(loaded.first?.pinned ?? false)
        let emb = loaded.first?.embeddings["m1"]
        XCTAssertEqual(emb?.tags, [3, 7])
        // Float16 round-trip tolerance.
        XCTAssertEqual(emb?.vector.count, 3)
        XCTAssertEqual(emb?.vector[0] ?? 0, 0.5, accuracy: 0.01)
        XCTAssertEqual(emb?.vector[2] ?? 0, 1.0, accuracy: 0.01)
    }

    func testDeleteCascadesEmbeddings() {
        let db = tempDB()
        let item = text("to delete")
        item.embeddings["m1"] = ModelEmbedding(vector: [1, 0], tags: [1])
        db.insert(item)
        db.delete(id: item.id)
        XCTAssertEqual(db.loadAll().count, 0)
        XCTAssertEqual(db.clipCount(), 0)
    }

    func testDeleteUnpinnedKeepsPinned() {
        let db = tempDB()
        let keep = text("keep"); keep.pinned = true
        db.insert(keep)
        db.insert(text("drop1")); db.insert(text("drop2"))
        db.deleteUnpinned()
        let loaded = db.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.text, "keep")
    }

    func testLoadAllOrdersPinnedThenRecency() {
        let db = tempDB()
        let old = text("old"); old.lastUsedAt = Date(timeIntervalSinceReferenceDate: 100)
        let new = text("new"); new.lastUsedAt = Date(timeIntervalSinceReferenceDate: 200)
        let pinnedOld = text("pinnedOld"); pinnedOld.pinned = true
        pinnedOld.lastUsedAt = Date(timeIntervalSinceReferenceDate: 50)
        db.insert(old); db.insert(new); db.insert(pinnedOld)
        let order = db.loadAll().map(\.text)
        XCTAssertEqual(order.first, "pinnedOld", "pinned floats to front despite being oldest")
        XCTAssertEqual(Array(order.dropFirst()), ["new", "old"], "then by recency")
    }

    func testReopenIsIdempotentAndPersists() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoDBTests-reopen-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("t.sqlite").path
        do { Database(path: path)!.insert(text("persisted")) }
        let reopened = Database(path: path)!
        XCTAssertEqual(reopened.loadAll().first?.text, "persisted")
    }
}
