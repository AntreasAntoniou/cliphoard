import XCTest
import SQLite3
@testable import Cliphoard

/// Direct tests for the SQLite store — previously untested (audit BL-T1).
final class DatabaseTests: XCTestCase {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func tempPath() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoDBTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("t.sqlite").path
    }

    private func tempDB() -> Database { Database(path: tempPath())! }

    /// Read the raw (undecrypted) vector/tags columns of the first embedding row
    /// via an independent connection — verifies what is actually on disk.
    private func rawEmbedding(path: String) -> (vector: Data?, tags: String?) {
        // `tags` is retired; the tuple keeps its shape so callers need no churn.
        var raw: OpaquePointer?
        guard sqlite3_open_v2(path, &raw, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return (nil, nil) }
        defer { sqlite3_close_v2(raw) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(raw, "SELECT vector FROM embeddings LIMIT 1;", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return (nil, nil) }
        var vec: Data?
        if let p = sqlite3_column_blob(stmt, 0) { vec = Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, 0))) }
        return (vec, nil)
    }

    /// Insert a PLAINTEXT (legacy, pre-encryption) embedding row directly, so we
    /// can prove old databases still load after the encrypt-at-rest change.
    private func insertLegacyPlaintextEmbedding(path: String, clipID: UUID, vector: [Float]) {
        var raw: OpaquePointer?
        guard sqlite3_open_v2(path, &raw, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return }
        defer { sqlite3_close_v2(raw) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(raw,
            "INSERT OR REPLACE INTO embeddings (clip_id, model, vector) VALUES (?,?,?);",
            -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, clipID.uuidString, -1, Self.transient)
        sqlite3_bind_text(stmt, 2, "legacy", -1, Self.transient)
        let blob = Database.blob(fromVector: vector)   // plaintext Float16 blob
        _ = blob.withUnsafeBytes { sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32(blob.count), Self.transient) }
        _ = sqlite3_step(stmt)
    }

    private func text(_ s: String) -> ClipItem { ClipItem(kind: .text, text: s) }

    private func rawUserTags(path: String, id: UUID) -> String? {
        var raw: OpaquePointer?
        guard sqlite3_open_v2(path, &raw, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close_v2(raw) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(raw, "SELECT user_tags FROM clips WHERE id=?;", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, Self.transient)
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    private func taggedItem(_ tags: [String]) throws -> ClipItem {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString, "kind": "text", "text": "tagged clip",
            "createdAt": 1, "lastUsedAt": 1, "pinned": false, "useCount": 0,
            "userTags": tags,
        ])
        return try JSONDecoder().decode(ClipItem.self, from: data)
    }

    func testEmbeddingBlobRoundTripsExactly() {
        let v: [Float] = [0.0, 1.0, -0.5, 0.040161, 0.25, -0.999]
        let blob = Database.blob(fromVector: v)
        XCTAssertEqual(blob.count, v.count * 4, "Float32 = 4 bytes/element (portable; universal build)")
        // Float32 storage → exact round-trip (Float16 was unavailable on x86_64 macOS).
        XCTAssertEqual(Database.vectorFromBlob(blob), v)
    }

    func testOpeningLegacyDatabaseAddsUserTagsColumn() {
        let path = tempPath()
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, """
            CREATE TABLE clips (
                id TEXT PRIMARY KEY, kind TEXT NOT NULL, text TEXT NOT NULL,
                rtf BLOB, payload_file TEXT, file_path TEXT, color_hex TEXT,
                created_at REAL NOT NULL, last_used_at REAL NOT NULL,
                pinned INTEGER NOT NULL, source_app TEXT, use_count INTEGER NOT NULL);
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(raw)

        _ = Database(path: path)
        var reopened: OpaquePointer?
        sqlite3_open_v2(path, &reopened, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close_v2(reopened) }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(reopened, "PRAGMA table_info(clips);", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        var columns: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 1) {
            columns.append(String(cString: c))
        }
        XCTAssertTrue(columns.contains("user_tags"), "additive migration must preserve old databases")
    }

    func testUserTagsAreSealedAtRestAndRoundTrip() throws {
        let path = tempPath()
        let db = Database(path: path)!
        let item = try taggedItem([" Client-Acme ", "research notes"])
        XCTAssertTrue(db.insert(item))

        let raw = rawUserTags(path: path, id: item.id)
        XCTAssertTrue(raw?.hasPrefix("enc1:") ?? false, "on-disk user tags must be sealed")
        XCTAssertFalse(raw?.contains("client-acme") ?? true, "plaintext user tag must not appear on disk")

        let loaded = try XCTUnwrap(db.loadAll().first)
        let encoded = try JSONEncoder().encode(loaded)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["userTags"] as? [String], ["client-acme", "research notes"])
    }

    func testInsertThenLoadAllReturnsEquivalentClip() {
        let db = tempDB()
        let item = text("hello db")
        item.pinned = true
        item.embeddings["m1"] = ModelEmbedding(vector: [0.5, -0.25, 1.0])
        db.insert(item)
        let loaded = db.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.text, "hello db")
        XCTAssertTrue(loaded.first?.pinned ?? false)
        let emb = loaded.first?.embeddings["m1"]
        // Float16 round-trip tolerance.
        XCTAssertEqual(emb?.vector.count, 3)
        XCTAssertEqual(emb?.vector[0] ?? 0, 0.5, accuracy: 0.01)
        XCTAssertEqual(emb?.vector[2] ?? 0, 1.0, accuracy: 0.01)
    }

    func testDeleteCascadesEmbeddings() {
        let db = tempDB()
        let item = text("to delete")
        item.embeddings["m1"] = ModelEmbedding(vector: [1, 0])
        db.insert(item)
        db.delete(id: item.id)
        XCTAssertEqual(db.loadAll().count, 0)
        XCTAssertEqual(db.clipCountStatus(), .counted(0),
                       "a REPORTED zero, not a zero produced by a failed count")
    }

    func testWriteMethodsReportSuccess() {
        let db = tempDB()
        let item = text("write result")
        XCTAssertTrue(db.insert(item), "insert should report success")
        item.pinned = true
        XCTAssertTrue(db.updateMeta(item), "updateMeta should report success")
        XCTAssertTrue(
            db.upsertEmbedding(clipID: item.id, model: "m1",
                               embedding: ModelEmbedding(vector: [0.5])),
            "upsertEmbedding should report success")
        XCTAssertTrue(db.delete(id: item.id), "delete should report success")
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

    func testEmbeddingColumnsAreSealedAtRest() {
        let path = tempPath()
        let db = Database(path: path)!
        let item = text("secret vec")
        item.embeddings["m1"] = ModelEmbedding(vector: [0.5, -0.25, 1.0])
        db.insert(item)

        let raw = rawEmbedding(path: path)
        XCTAssertTrue(Crypto.isSealed(raw.vector), "on-disk vector blob must be sealed")
        // And it must still round-trip back to the original values.
        let emb = db.loadAll().first?.embeddings["m1"]
        XCTAssertEqual(emb?.vector.count, 3)
        XCTAssertEqual(emb?.vector[0] ?? 0, 0.5, accuracy: 0.01)
        XCTAssertEqual(emb?.vector[2] ?? 0, 1.0, accuracy: 0.01)
    }

    /// Read the raw (undecrypted) content columns of a clip row by id via an
    /// independent connection — verifies what is actually on disk.
    private func rawClip(path: String, id: UUID)
        -> (text: String?, rtf: Data?, filePath: String?, colorHex: String?) {
        var raw: OpaquePointer?
        guard sqlite3_open_v2(path, &raw, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return (nil, nil, nil, nil) }
        defer { sqlite3_close_v2(raw) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(raw, "SELECT text, rtf, file_path, color_hex FROM clips WHERE id=?;",
                                 -1, &stmt, nil) == SQLITE_OK else { return (nil, nil, nil, nil) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, Self.transient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return (nil, nil, nil, nil) }
        var t: String?; if let c = sqlite3_column_text(stmt, 0) { t = String(cString: c) }
        var rtf: Data?; if let p = sqlite3_column_blob(stmt, 1) { rtf = Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, 1))) }
        var fp: String?; if let c = sqlite3_column_text(stmt, 2) { fp = String(cString: c) }
        var ch: String?; if let c = sqlite3_column_text(stmt, 3) { ch = String(cString: c) }
        return (t, rtf, fp, ch)
    }

    /// Content columns (text/rtf/file_path/color_hex) are sealed at rest and the
    /// plaintext never survives in the raw row — the fail-CLOSED insert contract.
    func testClipContentColumnsAreSealedAtRest() {
        let path = tempPath()
        let db = Database(path: path)!
        let secret = "aws_secret_key=AKIA-XXXX-TOP-SECRET"
        let item = ClipItem(kind: .text, text: secret)
        item.rtf = Data("{\\rtf1 \(secret)}".utf8)
        item.filePath = "/Users/me/\(secret).txt"
        item.colorHex = "#ABCDEF"
        XCTAssertTrue(db.insert(item))

        let raw = rawClip(path: path, id: item.id)
        XCTAssertTrue(raw.text?.hasPrefix("enc1:") ?? false, "on-disk text must be sealed")
        XCTAssertFalse(raw.text?.contains(secret) ?? true, "plaintext text must not appear on disk")
        XCTAssertTrue(Crypto.isSealed(raw.rtf), "on-disk rtf must be sealed")
        XCTAssertTrue(raw.filePath?.hasPrefix("enc1:") ?? false, "on-disk file path must be sealed")
        XCTAssertFalse(raw.filePath?.contains(secret) ?? true, "plaintext path must not appear on disk")
        XCTAssertTrue(raw.colorHex?.hasPrefix("enc1:") ?? false, "on-disk color must be sealed")
        // …and it all round-trips back through load.
        let loaded = db.loadAll().first
        XCTAssertEqual(loaded?.text, secret)
        XCTAssertEqual(loaded?.filePath, "/Users/me/\(secret).txt")
        XCTAssertEqual(loaded?.colorHex, "#ABCDEF")
    }

    func testLegacyPlaintextEmbeddingStillLoads() {
        let path = tempPath()
        let db = Database(path: path)!
        let item = text("has legacy emb")
        db.insert(item)   // clip row (needed for the FK)
        insertLegacyPlaintextEmbedding(path: path, clipID: item.id, vector: [0.5, -0.25, 1.0])

        // Confirm the row really is plaintext on disk.
        let raw = rawEmbedding(path: path)
        XCTAssertFalse(Crypto.isSealed(raw.vector), "legacy vector should be plaintext")

        // Reopen and confirm it decodes via the plaintext passthrough.
        let emb = Database(path: path)!.loadAll().first?.embeddings["legacy"]
        XCTAssertEqual(emb?.vector.count, 3)
        XCTAssertEqual(emb?.vector[0] ?? 0, 0.5, accuracy: 0.01)
        XCTAssertEqual(emb?.vector[2] ?? 0, 1.0, accuracy: 0.01)
    }

    func testTransactionRollsBackOnFailedStep() {
        let db = tempDB()
        db.insert(text("pre-existing"))   // committed before the transaction
        db.transaction {
            db.insert(text("added in txn"))   // valid write inside the txn
            // A foreign-key violation (embedding for a nonexistent clip) makes
            // step() fail, which must roll the whole transaction back.
            db.upsertEmbedding(clipID: UUID(), model: "m",
                               embedding: ModelEmbedding(vector: [1.0]))
        }
        // Only the pre-transaction commit survives; the txn insert is undone too.
        XCTAssertEqual(db.loadAll().map(\.text), ["pre-existing"],
                       "a failed step must roll back the whole transaction (no partial rows)")
        XCTAssertEqual(db.clipCountStatus(), .counted(1))
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
