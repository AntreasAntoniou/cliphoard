import XCTest
import SQLite3
@testable import Cliphoard

/// The legacy `--import-paste` command line. It bypassed `ClipImporters.write` and pushed every
/// row through `add` → `trim()`: a 20-row export into a limit of 10 evicted the user's own six
/// OLDER clips and then most of the import, under "imported 20 clips". Same fit rule as every
/// other importer now: newest that fit land, the rest stay in the export, which is only read.
@MainActor
final class PasteImportTests: XCTestCase {

    private func tempStore() -> ClipStore {
        ClipStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoPasteImport-\(UUID().uuidString)"))
    }

    private func withLimit(_ limit: Int, _ store: ClipStore, _ body: () throws -> Void) rethrows {
        let saved = UserDefaults.standard.object(forKey: "historyLimit")
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "historyLimit") }
            else { UserDefaults.standard.removeObject(forKey: "historyLimit") }
        }
        store.historyLimit = limit
        try body()
    }

    func testImportPasteLandsOnlyWhatFitsAndNeverDeletesAClipAlreadyHere() throws {
        try skipIfKeychainUnreachable()
        let store = tempStore()
        try XCTSkipIf(store.safeMode, "frozen store here")
        try withLimit(10, store) {
            for n in 0..<6 {   // OLDER than every export row: the case trim() ate
                let item = ClipItem(kind: .text, text: "mine \(n) \(UUID())")
                item.createdAt = Date(timeIntervalSinceReferenceDate: 600_000_000 + Double(n))
                item.lastUsedAt = item.createdAt
                store.add(item)
            }
            let mine = Set(store.items.map(\.id))
            XCTAssertEqual(mine.count, 6, "precondition")
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("DittoPaste-\(UUID().uuidString)", isDirectory: true)
            let path = try PasteFixture.write(20, to: dir)

            // --dry-run writes no rows and reports what a live run would do.
            let dry = PasteImport.run(dbPath: path, store: store, dryRun: true, limit: nil, since: nil)
            XCTAssertEqual(store.items.count, 6, "a dry run must write nothing, ever")
            XCTAssertEqual(Set(store.items.map(\.id)), mine)
            XCTAssertEqual(dry.imported, 4, "room for four under a limit of 10 with 6 here")
            XCTAssertEqual(dry.leftInSource, 16)

            let live = PasteImport.run(dbPath: path, store: store, dryRun: false, limit: nil, since: nil)
            XCTAssertTrue(mine.isSubset(of: Set(store.items.map(\.id))),
                          "the import DELETED clips the user already had")
            XCTAssertEqual(store.items.filter { !$0.pinned }.count, 10,
                           "more landed than the limit keeps — the next capture would evict them")
            let landed = store.items.filter { $0.userTags.contains(PasteImport.marker) }
            XCTAssertEqual(Set(landed.map(\.text)), Set((16..<20).map { "paste clip \($0)" }),
                           "the NEWEST rows by ZCREATEDAT must be the ones that land")
            XCTAssertEqual(live.imported, 4, "the report must count what landed, not what was read")
            XCTAssertEqual(live.leftInSource, 16)

            // Idempotent: a second live run into the full store lands nothing and doubles nothing.
            _ = PasteImport.run(dbPath: path, store: store, dryRun: false, limit: nil, since: nil)
            XCTAssertEqual(store.items.count, 10)

            // Unlimited + re-run brings the rest, exactly once; the user's clips are still here.
            store.historyLimit = 0
            let rest = PasteImport.run(dbPath: path, store: store, dryRun: false, limit: nil, since: nil)
            XCTAssertEqual(store.items.count, 26)
            XCTAssertEqual(rest.imported, 16)
            XCTAssertEqual(rest.skippedDuplicate, 4, "the four already here are counted, not re-added")
            XCTAssertTrue(mine.isSubset(of: Set(store.items.map(\.id))))
            let again = PasteImport.run(dbPath: path, store: store, dryRun: false, limit: nil, since: nil)
            XCTAssertEqual(again.imported, 0)
            XCTAssertEqual(again.skippedDuplicate, 20)
            XCTAssertEqual(store.items.count, 26)
        }
    }

    /// `--limit` (SQL LIMIT on the ASC read: the OLDEST N) and `--since` still reach the read.
    func testImportPasteKeepsLimitAndSince() throws {
        try skipIfKeychainUnreachable()
        let store = tempStore()
        try XCTSkipIf(store.safeMode, "frozen store here")
        try withLimit(10, store) {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("DittoPaste-\(UUID().uuidString)", isDirectory: true)
            let path = try PasteFixture.write(20, to: dir)
            let limited = PasteImport.run(dbPath: path, store: store, dryRun: true, limit: 3, since: nil)
            XCTAssertEqual(limited.imported, 3)
            XCTAssertEqual(store.items.count, 0)
            let since = Date(timeIntervalSinceReferenceDate: PasteFixture.created(18))
            let recent = PasteImport.run(dbPath: path, store: store, dryRun: false, limit: nil, since: since)
            XCTAssertEqual(recent.imported, 2)
            XCTAssertEqual(Set(store.items.map(\.text)), ["paste clip 18", "paste clip 19"])
        }
    }
}

/// A Paste-shaped export: exactly the tables and columns `PasteImport.read` selects —
/// `ZITEMENTITY(ZCREATEDAT REAL seconds since 2001, ZRAWTYPE, ZRAWPREVIEW BLOB of UTF-8 JSON,
/// ZSOURCEAPPLICATION)` LEFT JOINed to `ZAPPLICATIONENTITY(Z_PK, ZNAME)`. Type-5 text rows,
/// row n created at 2024-01-01 + n minutes — every row newer than the test's own clips.
enum PasteFixture {
    static func created(_ n: Int) -> Double { 725_846_400 + Double(n * 60) }

    static func write(_ count: Int, to dir: URL) throws -> String {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("db.sqlite").path
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw XCTSkip("sqlite3 could not open \(path)") }
        defer { sqlite3_close(db) }
        var sql = "CREATE TABLE ZAPPLICATIONENTITY (Z_PK INTEGER PRIMARY KEY, ZNAME TEXT);"
            + "INSERT INTO ZAPPLICATIONENTITY VALUES (1, 'Terminal');"
            + "CREATE TABLE ZITEMENTITY (Z_PK INTEGER PRIMARY KEY, ZCREATEDAT REAL, ZRAWTYPE INTEGER, "
            + "ZRAWPREVIEW BLOB, ZSOURCEAPPLICATION INTEGER);"
        for n in 0..<count {
            sql += "INSERT INTO ZITEMENTITY VALUES (\(n + 1), \(Int(created(n))), 5, "
                + "CAST('{\"text\":\"paste clip \(n)\",\"type\":\"text\"}' AS BLOB), 1);"
        }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw XCTSkip("fixture SQL failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        return path
    }
}
