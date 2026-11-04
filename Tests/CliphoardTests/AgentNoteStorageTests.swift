import XCTest
import SQLite3
@testable import Cliphoard

/// Real SQLite tests. The focused harness substitutes only an in-memory AES-GCM
/// Crypto fixture, so these tests never require a user's database or Keychain.
final class AgentNoteStorageTests: XCTestCase {
    private func directory() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("AgentNoteTests-\(UUID())")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: result) }
        return result
    }

    private func sql(_ statement: String, at path: String) throws {
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close_v2(connection) }
        XCTAssertEqual(sqlite3_exec(connection, statement, nil, nil, nil), SQLITE_OK)
    }

    func testInsertRetryAndReopenPreserveIdentityAndSeal() throws {
        let path = try directory().appendingPathComponent("ditto.sqlite").path
        let id = UUID(), text = "Research note about durable memory and context."
        var db: Database? = try XCTUnwrap(Database(path: path))
        XCTAssertTrue(db!.saveAgentNote(id: id, text: text))
        let first = try XCTUnwrap(db!.loadAll().first)
        XCTAssertEqual(first.id, id)
        XCTAssertEqual(first.text, text)
        XCTAssertTrue(first.pinned)
        XCTAssertEqual(first.sourceApp, "Cliphoard Agent")
        XCTAssertEqual(first.userTags, ["agent-note", "agent-share"])
        XCTAssertTrue(db!.saveAgentNote(id: id, text: text))
        XCTAssertEqual(db!.loadAll().count, 1)
        XCTAssertEqual(db!.loadAll().first?.createdAt, first.createdAt)
        for suffix in ["", "-wal", "-shm"] {
            if let bytes = try? Data(contentsOf: URL(fileURLWithPath: path + suffix)) {
                XCTAssertNil(bytes.range(of: Data(text.utf8)))
            }
        }
        db = nil
        let reopened = try XCTUnwrap(Database(path: path))
        XCTAssertTrue(reopened.saveAgentNote(id: id, text: text))
        XCTAssertEqual(reopened.loadAll().first?.text, text)
    }

    func testConflictsNeverOverwriteOrDeduplicateOtherNotes() throws {
        let path = try directory().appendingPathComponent("ditto.sqlite").path
        let db = try XCTUnwrap(Database(path: path))
        let existing = ClipItem(kind: .text, text: "A retained clipboard note.")
        XCTAssertTrue(db.insert(existing))
        XCTAssertFalse(db.saveAgentNote(id: existing.id, text: existing.text))
        let id = UUID()
        XCTAssertTrue(db.saveAgentNote(id: id, text: existing.text))
        XCTAssertFalse(db.saveAgentNote(id: id, text: "Replacement is forbidden."))
        XCTAssertTrue(db.saveAgentNote(id: UUID(), text: existing.text))
        XCTAssertEqual(db.loadAll().count, 3)
        XCTAssertEqual(db.loadAll().first(where: { $0.id == existing.id })?.pinned, false)
    }

    func testRejectsSensitiveBlankOversizeAndControlText() throws {
        let db = try XCTUnwrap(Database(path: try directory().appendingPathComponent("ditto.sqlite").path))
        for text in ["", " \n\t", "Contact owner@example.com", "-----BEGIN PRIVATE KEY-----",
                     "bad\0text", String(repeating: "é", count: 16_385)] {
            XCTAssertFalse(db.saveAgentNote(id: UUID(), text: text))
        }
        XCTAssertTrue(db.saveAgentNote(id: UUID(), text: String(repeating: "a ", count: 16_384)))
        XCTAssertEqual(db.loadAll().count, 1)
    }

    func testExactRetryRequiresAuthenticatedUnchangedFields() throws {
        let path = try directory().appendingPathComponent("ditto.sqlite").path
        let db = try XCTUnwrap(Database(path: path)), id = UUID()
        let text = "A short retained note."
        XCTAssertTrue(db.saveAgentNote(id: id, text: text))
        try sql("UPDATE clips SET text='A short retained note.' WHERE id='\(id.uuidString)';", at: path)
        XCTAssertFalse(db.saveAgentNote(id: id, text: text), "plaintext fallback is not a verified retry")
        let other = UUID()
        XCTAssertTrue(db.saveAgentNote(id: other, text: text))
        try sql("UPDATE clips SET pinned=0 WHERE id='\(other.uuidString)';", at: path)
        XCTAssertFalse(db.saveAgentNote(id: other, text: text))
    }

    func testReadbackRejectsEmbeddedNULAndTruncatedIntegerMetadata() throws {
        let path = try directory().appendingPathComponent("ditto.sqlite").path
        let db = try XCTUnwrap(Database(path: path)), first = UUID(), second = UUID()
        let text = "A protected note identity."
        XCTAssertTrue(db.saveAgentNote(id: first, text: text))
        try sql("UPDATE clips SET text=text || char(0) || 'suffix' WHERE id='\(first.uuidString)';", at: path)
        XCTAssertFalse(db.saveAgentNote(id: first, text: text))
        XCTAssertTrue(db.saveAgentNote(id: second, text: text))
        try sql("UPDATE clips SET pinned=4294967297 WHERE id='\(second.uuidString)';", at: path)
        XCTAssertFalse(db.saveAgentNote(id: second, text: text))
    }

    func testInsertFailureAndDeferredCommitFailureLeaveHistoryIntact() throws {
        let path = try directory().appendingPathComponent("ditto.sqlite").path
        let db = try XCTUnwrap(Database(path: path))
        let retained = ClipItem(kind: .text, text: "Keep this original history.")
        XCTAssertTrue(db.insert(retained))
        try sql("CREATE TRIGGER deny_agent BEFORE INSERT ON clips BEGIN SELECT RAISE(ABORT, 'fixture'); END;", at: path)
        XCTAssertFalse(db.saveAgentNote(id: UUID(), text: "An uncommitted note."))
        try sql("DROP TRIGGER deny_agent; CREATE TABLE fixture_parent(id INTEGER PRIMARY KEY); CREATE TABLE fixture_child(id INTEGER REFERENCES fixture_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER fail_commit AFTER INSERT ON clips BEGIN INSERT INTO fixture_child VALUES(99); END;", at: path)
        XCTAssertFalse(db.saveAgentNote(id: UUID(), text: "A deferred commit failure."))
        XCTAssertEqual(db.loadAll().map(\.id), [retained.id])
        try sql("DROP TRIGGER fail_commit;", at: path)
        XCTAssertTrue(db.saveAgentNote(id: UUID(), text: "A later valid note."), "rollback must release the failed transaction")
    }

    func testFailedSealingDoesNotInsert() throws {
        let db = try XCTUnwrap(Database(path: try directory().appendingPathComponent("ditto.sqlite").path))
        Crypto.simulatingEphemeralKey {
            XCTAssertFalse(db.saveAgentNote(id: UUID(), text: "Cannot persist this note."))
        }
        XCTAssertTrue(db.loadAll().isEmpty)
    }

    func testCanonicallyEquivalentButDifferentUTF8IsAConflict() throws {
        let db = try XCTUnwrap(Database(path: try directory().appendingPathComponent("ditto.sqlite").path))
        let id = UUID()
        XCTAssertTrue(db.saveAgentNote(id: id, text: "A café note."))
        XCTAssertFalse(db.saveAgentNote(id: id, text: "A cafe\u{301} note."))
    }

    @MainActor
    func testBackgroundWriteYieldsDuringSQLiteContentionAndRetries() async throws {
        let path = try directory().appendingPathComponent("ditto.sqlite").path
        let db = try XCTUnwrap(Database(path: path)), id = UUID()
        var locker: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &locker, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close_v2(locker) }
        XCTAssertEqual(sqlite3_exec(locker, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)
        let task = Task { await db.saveAgentNoteInBackground(id: id, text: "A background storage note.") }
        let start = Date()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "SQLite lock waiting must not hold MainActor")
        XCTAssertEqual(sqlite3_exec(locker, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
        let saved = await task.value
        XCTAssertTrue(saved)
        let retried = await db.saveAgentNoteInBackground(id: id, text: "A background storage note.")
        XCTAssertTrue(retried)
        XCTAssertEqual(db.loadAll().count, 1)
    }

    @MainActor
    func testBackgroundWriterRefusesMissingReplacedAndMemoryDatabase() async throws {
        let path = try directory().appendingPathComponent("ditto.sqlite").path
        let db = try XCTUnwrap(Database(path: path))
        try FileManager.default.moveItem(atPath: path, toPath: path + ".original")
        let missing = await db.saveAgentNoteInBackground(id: UUID(), text: "Must not recreate storage.")
        XCTAssertFalse(missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        let replacement = Data("different file identity; must remain untouched".utf8)
        try replacement.write(to: URL(fileURLWithPath: path))
        let replaced = await db.saveAgentNoteInBackground(id: UUID(), text: "Must not write replacement.")
        XCTAssertFalse(replaced)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), replacement)
        let memory = try XCTUnwrap(Database(path: ":memory:"))
        let memoryResult = await memory.saveAgentNoteInBackground(id: UUID(), text: "No second memory connection.")
        XCTAssertFalse(memoryResult)
    }

    #if !AGENT_STORAGE_DB_ONLY
    @MainActor
    func testStorePublishesOnlyCommittedInsertWithoutTrimming() async throws {
        let dir = try directory()
        let store = ClipStore(directory: dir)
        let first = UUID(), second = UUID()
        let firstSaved = await store.saveAgentNote(id: first, text: "The same note content.")
        let secondSaved = await store.saveAgentNote(id: second, text: "The same note content.")
        XCTAssertTrue(firstSaved)
        XCTAssertTrue(secondSaved)
        XCTAssertEqual(Set(store.items.map(\.id)), [first, second])
        XCTAssertEqual(store.userTagIndex["agent-share"]?.count, 2)
        try sql("CREATE TRIGGER deny_agent BEFORE INSERT ON clips BEGIN SELECT RAISE(ABORT, 'fixture'); END;", at: dir.appendingPathComponent("ditto.sqlite").path)
        let failed = await store.saveAgentNote(id: UUID(), text: "Not committed.")
        XCTAssertFalse(failed)
        XCTAssertEqual(Set(store.items.map(\.id)), [first, second])
    }

    @MainActor
    func testFrozenStoreRefusesWrite() async throws {
        let dir = try directory()
        let store = Crypto.simulatingEphemeralKey { ClipStore(directory: dir) }
        XCTAssertTrue(store.safeMode)
        let saved = await store.saveAgentNote(id: UUID(), text: "No writes in safe mode.")
        XCTAssertFalse(saved)
        XCTAssertTrue(store.items.isEmpty)
    }
    #endif
}
