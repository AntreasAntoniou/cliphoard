import XCTest
import SQLite3
@testable import Cliphoard

/// At-rest guarantees for per-clip user tags (spec §5) — the same contract
/// `DatabaseTests.testClipContentColumnsAreSealedAtRest` proves for clip content:
/// sealed on disk, plaintext never present, and a clean round-trip through
/// `loadAll`. Plus the additive `user_tags` migration for pre-tag databases and
/// the sealed `user_tag_dismissals` side table (spec §5.1).
final class UserTagStorageTests: XCTestCase {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func tempPath() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoUserTagTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("t.sqlite").path
    }

    /// Read one raw column from a row via an independent read-only connection —
    /// what is genuinely on disk, undecrypted.
    private func rawColumn(_ sql: String, path: String, bind: String) -> String? {
        var raw: OpaquePointer?
        guard sqlite3_open_v2(path, &raw, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close_v2(raw) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(raw, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, bind, -1, Self.transient)
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    private func columns(ofTable table: String, path: String) -> [String] {
        var raw: OpaquePointer?
        guard sqlite3_open_v2(path, &raw, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close_v2(raw) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(raw, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK else { return [] }
        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 1) {
            names.append(String(cString: c))
        }
        return names
    }

    // MARK: Sealed at rest

    func testUserTagsColumnIsSealedAtRestAndRoundTrips() throws {
        let path = tempPath()
        let db = try XCTUnwrap(Database(path: path))
        let secretTag = "client-acme-project-zeus"
        let item = ClipItem(kind: .text, text: "kickoff notes")
        item.userTags = ["  Client-ACME-Project-Zeus ", secretTag, "research notes"]
        XCTAssertTrue(db.insert(item))

        let raw = rawColumn("SELECT user_tags FROM clips WHERE id=?;", path: path, bind: item.id.uuidString)
        XCTAssertTrue(raw?.hasPrefix("enc1:") ?? false, "on-disk user_tags must be sealed")
        XCTAssertFalse(raw?.contains(secretTag) ?? true, "plaintext user tag must not appear on disk")
        // Nor anywhere else on disk — scan the main file AND the WAL/SHM sidecars.
        // SQLite runs in WAL mode, so a freshly-inserted row often lives only in
        // the -wal file; reading just the main .sqlite would pass vacuously.
        var scanned = false
        for suffix in ["", "-wal", "-shm"] {
            guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: path + suffix)) else { continue }
            scanned = true
            XCTAssertNil(bytes.range(of: Data(secretTag.utf8)),
                         "plaintext user tag must not appear in the database file\(suffix)")
        }
        XCTAssertTrue(scanned, "expected at least the main database file on disk")

        // …and it round-trips normalized (trimmed, lowercased, de-duped, ordered).
        let loaded = try XCTUnwrap(db.loadAll().first)
        XCTAssertEqual(loaded.userTags, [secretTag, "research notes"])
    }

    /// The tag update path is fail-closed in the same way: it seals before it
    /// touches SQLite, and never leaves a plaintext label behind.
    func testUpdateUserTagsRewritesSealedValue() throws {
        let path = tempPath()
        let db = try XCTUnwrap(Database(path: path))
        let item = ClipItem(kind: .text, text: "note")
        XCTAssertTrue(db.insert(item))

        item.userTags = ["Invoices", "invoices", " urgent "]
        XCTAssertTrue(db.updateUserTags(item))

        let raw = rawColumn("SELECT user_tags FROM clips WHERE id=?;", path: path, bind: item.id.uuidString)
        XCTAssertTrue(raw?.hasPrefix("enc1:") ?? false, "updated user_tags must be sealed")
        XCTAssertFalse(raw?.contains("invoices") ?? true, "plaintext must not reach disk on update")
        XCTAssertEqual(try XCTUnwrap(db.loadAll().first).userTags, ["invoices", "urgent"])
    }

    // MARK: Additive migration

    func testPreTagDatabaseGainsColumnAndReadsEmptyTags() throws {
        let path = tempPath()
        // A database written before user tags existed: no `user_tags` column, and
        // one row already in it.
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, """
            CREATE TABLE clips (
                id TEXT PRIMARY KEY, kind TEXT NOT NULL, text TEXT NOT NULL,
                rtf BLOB, payload_file TEXT, file_path TEXT, color_hex TEXT,
                created_at REAL NOT NULL, last_used_at REAL NOT NULL,
                pinned INTEGER NOT NULL, source_app TEXT, use_count INTEGER NOT NULL);
            """, nil, nil, nil), SQLITE_OK)
        let legacyID = UUID()
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(raw, """
            INSERT INTO clips (id, kind, text, created_at, last_used_at, pinned, use_count)
            VALUES (?, 'text', 'legacy row', 1, 1, 0, 0);
            """, -1, &stmt, nil), SQLITE_OK)
        sqlite3_bind_text(stmt, 1, legacyID.uuidString, -1, Self.transient)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        sqlite3_finalize(stmt)
        sqlite3_close_v2(raw)

        let db = try XCTUnwrap(Database(path: path))
        XCTAssertTrue(columns(ofTable: "clips", path: path).contains("user_tags"),
                      "opening an old database must ADD the column, not recreate the table")
        let loaded = try XCTUnwrap(db.loadAll().first)
        XCTAssertEqual(loaded.id, legacyID, "the pre-existing row must survive the migration")
        XCTAssertEqual(loaded.text, "legacy row", "legacy plaintext content still passes through")
        XCTAssertEqual(loaded.userTags, [], "a NULL user_tags column reads as no tags")

        // Re-opening is idempotent (the guard must not ALTER twice).
        XCTAssertNotNil(Database(path: path))
        XCTAssertEqual(columns(ofTable: "clips", path: path).filter { $0 == "user_tags" }.count, 1)
    }

    // MARK: Dismissals

    func testUserTagDismissalsRoundTripSealedAndCascade() throws {
        let path = tempPath()
        let db = try XCTUnwrap(Database(path: path))
        let item = ClipItem(kind: .text, text: "suggestion target")
        XCTAssertTrue(db.insert(item))

        XCTAssertTrue(db.addUserTagDismissal(tag: " Client-Acme ", clipID: item.id))
        XCTAssertTrue(db.addUserTagDismissal(tag: "client-acme", clipID: item.id),
                      "re-dismissing the same tag is a no-op, not a failure")
        XCTAssertTrue(db.addUserTagDismissal(tag: "invoices", clipID: item.id))

        let stored = rawColumn("SELECT tag FROM user_tag_dismissals WHERE clip_id=?;",
                               path: path, bind: item.id.uuidString)
        XCTAssertTrue(stored?.hasPrefix("enc1:") ?? false, "dismissed tags are sealed at rest too")
        XCTAssertFalse(stored?.contains("client-acme") ?? true, "plaintext tag must not reach disk")

        XCTAssertEqual(db.dismissedUserTags(forClip: item.id), ["client-acme", "invoices"])
        XCTAssertEqual(db.userTagDismissals(),
                       [Database.UserTagDismissal(tag: "client-acme", clipID: item.id),
                        Database.UserTagDismissal(tag: "invoices", clipID: item.id)])

        XCTAssertTrue(db.removeUserTagDismissal(tag: "CLIENT-ACME", clipID: item.id))
        XCTAssertEqual(db.dismissedUserTags(forClip: item.id), ["invoices"])

        // Deleting the clip prunes its dismissals (explicit, since there is no FK).
        XCTAssertTrue(db.delete(id: item.id))
        XCTAssertTrue(db.userTagDismissals().isEmpty, "dismissals are pruned with the clip")
    }

    @MainActor
    func testStoreTagSettersWriteThroughAndKeepIndexInSync() throws {
        try skipIfKeychainUnreachable()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoUserTagStore-\(UUID().uuidString)")
        var store: ClipStore? = ClipStore(directory: dir)
        let item = ClipItem(kind: .text, text: "invoice for acme")
        store?.add(item)

        XCTAssertTrue(store?.addUserTag(" Invoices ", to: item) ?? false)
        XCTAssertTrue(store?.addUserTag("invoices", to: item) ?? false, "duplicate add is a no-op")
        XCTAssertTrue(store?.addUserTag("client-acme", to: item) ?? false)
        XCTAssertEqual(item.userTags, ["invoices", "client-acme"])
        XCTAssertEqual(store?.allUserTags(), ["client-acme", "invoices"])
        XCTAssertEqual(store?.items(withUserTag: "INVOICES").map(\.id), [item.id])

        XCTAssertTrue(store?.removeUserTag("invoices", from: item) ?? false)
        XCTAssertTrue(store?.items(withUserTag: "invoices").isEmpty ?? false)
        XCTAssertEqual(store?.allUserTags(), ["client-acme"])
        XCTAssertTrue(store?.dismissSuggestedUserTag("meeting", for: item) ?? false)
        store = nil

        let reloaded = ClipStore(directory: dir)
        let persisted = try XCTUnwrap(reloaded.items.first)
        XCTAssertEqual(persisted.userTags, ["client-acme"], "tags survive a reload")
        XCTAssertEqual(reloaded.allUserTags(), ["client-acme"])
        XCTAssertEqual(reloaded.dismissedUserTags(for: persisted), ["meeting"])
    }
}
