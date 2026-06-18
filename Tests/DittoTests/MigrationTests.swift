import XCTest
@testable import Ditto

/// Audit BL-T2: legacy `history.json` → SQLite migration on `ClipStore` init.
/// Verifies pins survive, the legacy single-vector fields fold into the per-model
/// `embeddings` cache, the JSON is archived (not re-imported), and a corrupt file
/// is preserved rather than silently dropping the user's history.
@MainActor
final class MigrationTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        Feedback.soundEnabled = false
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoMigrationTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func writeHistory(_ raw: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: raw, options: [])
        try data.write(to: dir.appendingPathComponent("history.json"))
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    /// A valid legacy history (no `embeddings` key) migrates: pins are kept and the
    /// legacy vector/tagIDs/vectorModel fold into the per-model embeddings cache.
    func testLegacyHistoryMigratesPinsAndFoldsVector() throws {
        let pinnedID = UUID().uuidString
        let now = Date().timeIntervalSinceReferenceDate
        // Two clips, one pinned and carrying legacy single-vector fields. No
        // `embeddings` key at all — exactly what a pre-per-model file looked like.
        try writeHistory([
            [
                "id": pinnedID,
                "kind": "text",
                "text": "pinned legacy clip",
                "createdAt": now,
                "lastUsedAt": now,
                "pinned": true,
                "useCount": 2,
                "vector": [0.6, 0.8],
                "tagIDs": [3, 7],
                "vectorModel": "ogma-small-256",
            ],
            [
                "id": UUID().uuidString,
                "kind": "text",
                "text": "ordinary legacy clip",
                "createdAt": now - 10,
                "lastUsedAt": now - 10,
                "pinned": false,
                "useCount": 0,
            ],
        ])

        let store = ClipStore(directory: dir)

        XCTAssertEqual(store.items.count, 2, "both legacy clips loaded")
        let pinned = try XCTUnwrap(store.items.first { $0.text == "pinned legacy clip" })
        XCTAssertTrue(pinned.pinned, "pin preserved through migration")

        // Legacy single-vector fields folded into embeddings[<vectorModel>].
        let emb = try XCTUnwrap(pinned.embeddings["ogma-small-256"],
                                "legacy vector folded under its vectorModel signature")
        XCTAssertEqual(emb.tags, [3, 7])
        XCTAssertEqual(emb.vector.count, 2)
        XCTAssertEqual(emb.vector[0], 0.6, accuracy: 0.01)
        XCTAssertEqual(emb.vector[1], 0.8, accuracy: 0.01)

        // The legacy scalar fields are cleared once folded.
        XCTAssertNil(pinned.vector)
        XCTAssertNil(pinned.tagIDs)
        XCTAssertNil(pinned.vectorModel)

        // JSON archived so a relaunch doesn't re-import it.
        XCTAssertFalse(exists("history.json"), "original consumed")
        XCTAssertTrue(exists("history.migrated.json"), "archived as backup")
    }

    /// Re-opening the same directory must not re-import (clip count is non-zero and
    /// there's no `history.json` left), so the count stays stable.
    func testReopenDoesNotReimport() throws {
        let now = Date().timeIntervalSinceReferenceDate
        try writeHistory([[
            "id": UUID().uuidString, "kind": "text", "text": "once",
            "createdAt": now, "lastUsedAt": now, "pinned": false, "useCount": 0,
        ]])
        _ = ClipStore(directory: dir)
        let reopened = ClipStore(directory: dir)
        XCTAssertEqual(reopened.items.count, 1, "no duplicate import on reopen")
        XCTAssertTrue(exists("history.migrated.json"))
    }

    /// A corrupt `history.json` must be PRESERVED (as history.corrupt.json) and the
    /// store left empty — never silently wiped.
    func testCorruptHistoryIsPreservedNotWiped() throws {
        let garbage = Data("{ this is not valid json ]".utf8)
        try garbage.write(to: dir.appendingPathComponent("history.json"))

        let store = ClipStore(directory: dir)

        XCTAssertTrue(store.items.isEmpty, "no items loaded from corrupt file")
        XCTAssertTrue(exists("history.corrupt.json"), "corrupt history kept for recovery")
        // Not migrated/archived as a success.
        XCTAssertFalse(exists("history.migrated.json"))

        let preserved = try Data(contentsOf: dir.appendingPathComponent("history.corrupt.json"))
        XCTAssertEqual(preserved, garbage, "corrupt bytes preserved verbatim")
    }
}
