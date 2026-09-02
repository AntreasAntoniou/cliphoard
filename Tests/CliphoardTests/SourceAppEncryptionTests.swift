import XCTest
import SQLite3
@testable import Cliphoard

/// T1: `source_app` is sealed with the content, not stored beside it in the clear.
///
/// A row whose origin reads "Bitwarden" announces what the ciphertext next to it is.
/// So `Database.insert` seals the column exactly like `text`, `loadAll` opens it either
/// way, and one launch re-persists every legacy row through a single transaction —
/// stamping its one-shot marker only for work that actually landed.
@MainActor
final class SourceAppEncryptionTests: XCTestCase {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let markerKey = "sourceAppEncryptedV1"
    /// Every other one-shot pass is retired for the duration of a test, so the store
    /// under test runs THIS migration and nothing else rewrites rows.
    private static let retiredKeys = ["dbEncryptedV1", "reKeySEv2", "imagesEncryptedV1",
                                      "detectorBackfillV1"]

    private var saved: [String: Any?] = [:]
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        Feedback.soundEnabled = false
        for key in Self.retiredKeys + [Self.markerKey] {
            saved[key] = UserDefaults.standard.object(forKey: key)
        }
        for key in Self.retiredKeys { UserDefaults.standard.set(true, forKey: key) }
        UserDefaults.standard.removeObject(forKey: Self.markerKey)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoSourceApp-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for key in Self.retiredKeys + [Self.markerKey] {
            if let value = saved[key] ?? nil {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private var dbPath: String { tempDir.appendingPathComponent("ditto.sqlite").path }

    // MARK: - Fixture

    /// A raw 1.0-schema database whose rows carry sealed `text` and PLAINTEXT
    /// `source_app` — a store written before this change. `flags` rides along so a
    /// quarantined origin can be shown to survive the re-persist.
    private func writeLegacyFixture(_ rows: [(id: UUID, app: String, flags: Int64)]) throws {
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(dbPath, &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil),
                       SQLITE_OK)
        defer { sqlite3_close_v2(raw) }
        XCTAssertEqual(sqlite3_exec(raw, """
            CREATE TABLE clips (
                id TEXT PRIMARY KEY, kind TEXT NOT NULL, text TEXT NOT NULL,
                rtf BLOB, payload_file TEXT, file_path TEXT, color_hex TEXT,
                created_at REAL NOT NULL, last_used_at REAL NOT NULL,
                pinned INTEGER NOT NULL, source_app TEXT, use_count INTEGER NOT NULL,
                user_tags TEXT, flags INTEGER, shape TEXT, ocr_text TEXT);
            """, nil, nil, nil), SQLITE_OK)
        for (n, row) in rows.enumerated() {
            let sealed = try XCTUnwrap(Crypto.sealStrict("clip \(n)"))
            var stmt: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(raw, """
                INSERT INTO clips (id, kind, text, created_at, last_used_at, pinned,
                                   source_app, use_count, flags)
                VALUES (?, 'text', ?, ?, ?, 0, ?, 0, ?);
                """, -1, &stmt, nil), SQLITE_OK)
            sqlite3_bind_text(stmt, 1, row.id.uuidString, -1, Self.transient)
            sqlite3_bind_text(stmt, 2, sealed, -1, Self.transient)
            sqlite3_bind_double(stmt, 3, Double(n))
            sqlite3_bind_double(stmt, 4, Double(n))
            sqlite3_bind_text(stmt, 5, row.app, -1, Self.transient)
            sqlite3_bind_int64(stmt, 6, row.flags)
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
            sqlite3_finalize(stmt)
        }
    }

    /// Run one SQL statement over an independent read-only connection.
    private func rawExec(_ sql: String) {
        var raw: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &raw, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            return XCTFail("could not reopen database for a raw write")
        }
        defer { sqlite3_close_v2(raw) }
        XCTAssertEqual(sqlite3_exec(raw, sql, nil, nil, nil), SQLITE_OK,
                       String(cString: sqlite3_errmsg(raw)))
    }

    /// `source_app` for every row, as stored on disk, keyed by id. nil = SQL NULL.
    private func rawSourceApps() -> [String: String?] {
        var raw: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &raw, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            XCTFail("could not reopen database for a raw read"); return [:]
        }
        defer { sqlite3_close_v2(raw) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(raw, "SELECT id, source_app FROM clips;", -1, &stmt, nil) == SQLITE_OK else {
            XCTFail("could not prepare the raw read"); return [:]
        }
        var out: [String: String?] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            if sqlite3_column_type(stmt, 1) == SQLITE_NULL {
                out[id] = .some(nil)
            } else {
                out[id] = String(cString: sqlite3_column_text(stmt, 1))
            }
        }
        return out
    }

    private func rawScalar(_ sql: String) -> Int {
        var raw: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &raw, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            XCTFail("could not reopen database for a raw read"); return -1
        }
        defer { sqlite3_close_v2(raw) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(raw, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else {
            XCTFail("raw scalar failed: \(sql)"); return -1
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private var marker: Bool { UserDefaults.standard.bool(forKey: Self.markerKey) }

    // MARK: - Tests

    /// The write path seals; the read path opens; NULL stays NULL.
    func testInsertSealsSourceAppAndLoadOpensIt() throws {
        try skipIfKeychainUnreachable()
        let db = try XCTUnwrap(Database(path: dbPath))
        let named = ClipItem(kind: .text, text: "from a password manager")
        named.sourceApp = "Passwords"
        let anonymous = ClipItem(kind: .text, text: "origin unknown")
        anonymous.sourceApp = nil
        XCTAssertTrue(db.insert(named))
        XCTAssertTrue(db.insert(anonymous))

        let stored = rawSourceApps()
        let onDisk = try XCTUnwrap(stored[named.id.uuidString] ?? nil,
                                   "the named row must carry a source_app on disk")
        XCTAssertTrue(onDisk.hasPrefix("enc1:"), "source_app reached disk unsealed: \(onDisk)")
        XCTAssertNotEqual(onDisk, "Passwords")
        XCTAssertEqual(stored[anonymous.id.uuidString], .some(nil),
                       "a nil source app must stay SQL NULL, not become sealed \"\"")

        let loaded = db.loadAll()
        XCTAssertEqual(loaded.first { $0.id == named.id }?.sourceApp, "Passwords")
        XCTAssertNil(loaded.first { $0.id == anonymous.id }?.sourceApp)
    }

    /// One launch seals every legacy row; the names still read; the pass is idempotent.
    func testLegacyPlaintextSourceAppsAreSealedAfterOneLaunchAndStillReadable() throws {
        try skipIfKeychainUnreachable()
        let bw = UUID()
        try writeLegacyFixture([
            (id: bw, app: "Bitwarden", flags: Int64(ClipFlags.quarantined.rawValue)),
            (id: UUID(), app: "Passwords", flags: 0),
            (id: UUID(), app: "Safari", flags: 0),
        ])
        XCTAssertEqual(rawScalar("SELECT SUM(source_app NOT LIKE 'enc1:%') FROM clips;"), 3,
                       "precondition: the fixture is plaintext")

        let store = ClipStore(directory: tempDir)
        XCTAssertFalse(store.safeMode, "the store must be healthy for the pass to run at all")

        XCTAssertEqual(rawScalar("SELECT SUM(source_app NOT LIKE 'enc1:%') FROM clips;"), 0,
                       "a source app is still on disk in the clear after the launch")
        XCTAssertEqual(rawScalar("SELECT COUNT(*) FROM clips;"), 3, "the pass must not lose rows")
        XCTAssertEqual(store.items.compactMap(\.sourceApp).sorted(),
                       ["Bitwarden", "Passwords", "Safari"])
        let bitwarden = try XCTUnwrap(store.items.first { $0.id == bw })
        XCTAssertTrue(bitwarden.flags.contains(.quarantined),
                      "sealing the origin must not drop the quarantine it earned")
        XCTAssertTrue(marker, "a fully committed pass must retire itself")

        let again = ClipStore(directory: tempDir)
        XCTAssertEqual(again.items.compactMap(\.sourceApp).sorted(),
                       ["Bitwarden", "Passwords", "Safari"],
                       "a second launch must open what the first sealed")
    }

    /// A row that fails to write rolls the WHOLE pass back, and the marker stays clear
    /// so the next launch retries — no half-sealed table stamped as done.
    ///
    /// Two distinct refusals, because the guard has two terms and each is load-bearing
    /// on a different failure. A write that fails at STEP marks the transaction failed,
    /// so `committed` is false and everything rolls back. A write that fails at PREPARE
    /// never steps, so nothing marks the transaction and it COMMITS — empty — with
    /// `written == 0`; only the tally term sees that one. Delete either term and one of
    /// the two launches below stamps a marker for work that never happened.
    func testMarkerIsNotStampedWhenARowFailsToWriteAndTheNextLaunchRetries() throws {
        try skipIfKeychainUnreachable()
        let bw = UUID()
        try writeLegacyFixture([
            (id: bw, app: "Bitwarden", flags: Int64(ClipFlags.quarantined.rawValue)),
            (id: UUID(), app: "Passwords", flags: 0),
            (id: UUID(), app: "Safari", flags: 0),
        ])

        // Launch 0 — the INSERT cannot even be PREPARED (sqlite compiles trigger bodies
        // into the triggering statement, and this one names a table that does not
        // exist). `Database.prepare` fails, `step` never runs, the transaction commits
        // with nothing in it, and `committed` is TRUE. Only `written == eligible.count`
        // stands between that and a stamped marker.
        rawExec("""
            CREATE TRIGGER prep_fail BEFORE INSERT ON clips
            BEGIN INSERT INTO no_such_table VALUES (1); END;
            """)
        let zeroth = ClipStore(directory: tempDir)
        XCTAssertFalse(zeroth.safeMode)
        XCTAssertFalse(marker, "the marker was stamped although no row could be prepared")
        XCTAssertEqual(rawScalar("SELECT SUM(source_app NOT LIKE 'enc1:%') FROM clips;"), 3,
                       "a row was sealed although the insert could not be prepared")
        rawExec("DROP TRIGGER prep_fail;")

        // Launch 1 — one row aborts at STEP; the transaction must roll the others back.
        rawExec("""
            CREATE TRIGGER block_bw BEFORE INSERT ON clips WHEN NEW.id = '\(bw.uuidString)'
            BEGIN SELECT RAISE(ABORT, 'blocked by test'); END;
            """)

        let first = ClipStore(directory: tempDir)
        XCTAssertFalse(first.safeMode)
        XCTAssertFalse(marker, "the marker was stamped although a row refused to write")
        let afterFirst = rawSourceApps()
        XCTAssertEqual(afterFirst.count, 3)
        for (id, app) in afterFirst {
            let value = try XCTUnwrap(app ?? nil, "row \(id) lost its source_app")
            XCTAssertFalse(value.hasPrefix("enc1:"),
                           "row \(id) was sealed although the transaction should have "
                           + "rolled back: \(value)")
        }
        XCTAssertEqual(first.items.first { $0.id == bw }?.sourceApp, "Bitwarden")

        rawExec("DROP TRIGGER block_bw;")
        // Launch 2 — nothing in the way: the retry completes and retires itself.
        let second = ClipStore(directory: tempDir)
        XCTAssertFalse(second.safeMode)
        XCTAssertTrue(marker, "with the block lifted the retry must complete and retire itself")
        XCTAssertEqual(rawScalar("SELECT SUM(source_app NOT LIKE 'enc1:%') FROM clips;"), 0)
        XCTAssertEqual(rawScalar("SELECT COUNT(*) FROM clips;"), 3)
        XCTAssertEqual(second.items.compactMap(\.sourceApp).sorted(),
                       ["Bitwarden", "Passwords", "Safari"])
    }

    /// A one-shot marker stamped after a failed load retires its migration permanently:
    /// the next healthy launch never revisits those rows.
    func testMarkerIsNotStampedAfterAFailedLoad() throws {
        try skipIfKeychainUnreachable()
        try Data(repeating: 0xFF, count: 100).write(to: URL(fileURLWithPath: dbPath))

        let store = ClipStore(directory: tempDir)

        XCTAssertFalse(store.storageComplete)
        XCTAssertFalse(marker, "a marker was stamped for work that never happened")
    }

    /// The column is sealed, so only the file that seals and opens it may name it. Any
    /// other SQL touching `source_app` would read ciphertext as a name.
    func testNothingReadsSourceAppThroughSQLOutsideDatabase() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CliphoardTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: sources.path))
        var offenders: [String] = []
        var scanned = 0
        while let rel = enumerator.nextObject() as? String {
            guard rel.hasSuffix(".swift") else { continue }
            scanned += 1
            let text = try String(contentsOf: sources.appendingPathComponent(rel), encoding: .utf8)
            if text.contains("source_app"), !rel.hasSuffix("/Database.swift") {
                offenders.append(rel)
            }
        }
        XCTAssertGreaterThan(scanned, 10, "the scan found almost no sources — wrong root?")
        XCTAssertEqual(offenders, [], "source_app is named outside Database.swift")
    }
}
