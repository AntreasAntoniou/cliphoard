import XCTest
import SQLite3
@testable import Cliphoard

/// The Settings surface for imports.
///
/// The engine shipped weeks before any way to reach it: it was a command-line flag that had
/// to be run from inside the `.app` bundle. Meanwhile the site advertised "bring your
/// history". A feature nobody can find is not shipped, however well it is tested.
///
/// What these pin is the SAFETY SHAPE, not the pixels. Nine of the ten adapters have never
/// been executed against a real store — none of those apps is installed on the machine they
/// were written on — so a one-click Import would take an untested parser and write its
/// output straight into someone's history. The preview step is the whole point, and it is
/// the first thing a well-meaning simplification would remove.
@MainActor
final class ImportUITests: XCTestCase {

    private func tempStore() -> ClipStore {
        ClipStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoImportUI-\(UUID().uuidString)"))
    }

    /// Nothing lands that the next capture would evict, and nothing already here is deleted.
    /// `ClipImporters.write` used to push every clip through `add` → `trim()`: a 20-clip
    /// import into a limit of 10 evicted the user's own OLDER clips first, then most of the
    /// import, under "Imported 20". The fit rule lands the newest that fit; the rest stay in
    /// the other manager, and the sentence says so and stays true after "Unlimited + re-import".
    func testAnImportLandsOnlyWhatFitsAndNeverDeletesAClipAlreadyHere() throws {
        try skipIfKeychainUnreachable()
        let store = tempStore()
        try XCTSkipIf(store.safeMode, "frozen store here")
        guard let maccy = ClipImporters.all.first(where: { $0.id == "maccy" }), maccy.read != nil else {
            throw XCTSkip("no Maccy adapter in this build")
        }
        let saved = UserDefaults.standard.object(forKey: "historyLimit")
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "historyLimit") }
            else { UserDefaults.standard.removeObject(forKey: "historyLimit") }
        }
        store.historyLimit = 10
        for n in 0..<6 {   // OLDER than the import: the case trim() ate
            let item = ClipItem(kind: .text, text: "mine \(n) \(UUID())")
            item.createdAt = Date(timeIntervalSinceReferenceDate: 600_000_000 + Double(n))
            item.lastUsedAt = item.createdAt
            store.add(item)
        }
        let mine = Set(store.items.map(\.id))
        XCTAssertEqual(mine.count, 6, "precondition")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoMaccy-\(UUID().uuidString)", isDirectory: true)
        let path = try MaccyFixture.write(20, to: dir)
        let model = ImportModel()
        let candidate = ImportModel.Candidate(source: maccy, path: path)

        model.dryRun(candidate, store: store)
        XCTAssertEqual(store.items.count, 6, "a preview must write nothing, ever")
        XCTAssertEqual(model.preview?.total, 4, "room for four under a limit of 10 with 6 here")
        XCTAssertEqual(model.preview?.leftInSource, 16)

        model.commit(candidate, store: store)
        XCTAssertTrue(mine.isSubset(of: Set(store.items.map(\.id))),
                      "the import DELETED clips the user already had")
        XCTAssertEqual(store.items.filter { !$0.pinned }.count, 10,
                       "more landed than the limit keeps — the next capture would evict them")
        let landed = store.items.filter { $0.userTags.contains("import-maccy") }
        XCTAssertEqual(Set(landed.map(\.text)), Set((16..<20).map { "maccy clip \($0)" }),
                       "the NEWEST clips by source date must be the ones that land")
        let result = try XCTUnwrap(model.result)
        XCTAssertTrue(result.contains("Imported 4 ") && result.contains("16")
                      && result.contains("Unlimited") && !result.contains("Pro"), result)

        // The sentence's promise: Unlimited + import again brings the rest, and nothing doubles.
        store.historyLimit = 0
        model.commit(candidate, store: store)
        XCTAssertEqual(store.items.count, 26)
        XCTAssertTrue(mine.isSubset(of: Set(store.items.map(\.id))))
    }

    /// A scan lists only sources whose store EXISTS here. Ten rows for someone who uses one
    /// clipboard manager is nine invitations to click something that cannot work.
    func testScanOnlyOffersSourcesPresentOnThisMachine() {
        let model = ImportModel()
        model.scan()
        for candidate in model.candidates {
            XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path),
                          "\(candidate.source.id) was offered but its store is not at "
                          + "\(candidate.path) — the row cannot do anything")
        }
    }

    /// Nothing is written before a preview. This is the assertion that matters most: it is
    /// the difference between "you saw what an untested parser produced" and "an untested
    /// parser edited your clipboard history".
    func testAPreviewWritesNothing() throws {
        try skipIfKeychainUnreachable()
        let store = tempStore()
        try XCTSkipIf(store.safeMode, "frozen store here")
        // Against the REAL Paste export, not against whatever happens to be installed.
        // `scan()` only looks where an app would install its store, so on a machine with no
        // clipboard manager this test skipped — and a skipped test is indistinguishable
        // from a passing one in a summary line. The export is the verified fixture: 7,775
        // rows of genuine Core Data, the same data the adapter was developed against.
        let export = ("~/exports-2026-06-26/paste-export/com.wiheads.paste-setapp/db.sqlite"
                      as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: export),
              let paste = ClipImporters.all.first(where: { $0.id == "paste" }) else {
            throw XCTSkip("the Paste export fixture is not on this machine, so there is no "
                          + "real store to preview against. Not a pass.")
        }
        let model = ImportModel()
        let candidate = ImportModel.Candidate(source: paste, path: export)
        let before = store.items.count
        model.dryRun(candidate, store: store)
        XCTAssertEqual(store.items.count, before,
                       "a preview added clips to the store. The preview exists precisely so "
                       + "an untested adapter can be inspected BEFORE it writes anything.")
        XCTAssertNotNil(model.preview, "the preview produced no tally to inspect")
    }

    /// The preview must carry a per-kind breakdown, because that breakdown IS the check.
    /// A misreading adapter shows up as everything arriving under one kind — visible at a
    /// glance here, invisible in a progress bar or a bare total.
    func testThePreviewReportsAKindBreakdownNotJustATotal() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Cliphoard/UI/ImportPanel.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains("let byKind:"),
                      "the preview no longer carries a per-kind breakdown, so a parser "
                      + "misreading a store looks identical to one reading it correctly")
        XCTAssertTrue(source.contains("ForEach(preview.byKind"),
                      "the breakdown is computed but never shown — the user sees a total "
                      + "and has nothing to judge it by")
    }

    /// Unverified adapters must SAY SO in the interface. The user is consenting to run a
    /// parser that has never been executed; that fact belongs on screen, not in a comment.
    func testUnverifiedAdaptersAreLabelledInTheUI() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Cliphoard/UI/ImportPanel.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains("confidence != .verified"),
                      "the UI no longer distinguishes a verified importer from one that has "
                      + "never been run — the CLI refuses to write without --force for "
                      + "exactly this reason, and the UI must not be the lax path")
        XCTAssertTrue(source.contains("untested importer"),
                      "the warning text is gone; `confidence` is checked but says nothing")
    }

    /// A frozen store must not be importable into. Every write path in this app refuses in
    /// safe mode; an import that bypassed it would be the largest such write there is.
    func testImportControlsRefuseWhileTheStoreIsFrozen() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Cliphoard/UI/ImportPanel.swift"),
            encoding: .utf8)
        XCTAssertEqual(source.components(separatedBy: "store.safeMode").count - 1, 2,
                       "expected BOTH the Preview and the Import buttons to be disabled in "
                       + "safe mode; found a different number of guards")
    }

    /// Imported batches stay reversible: the marker is what makes "undo this import" a
    /// single query rather than an archaeology exercise.
    func testEveryImportIsTaggedWithItsSourceMarker() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Cliphoard/UI/ImportPanel.swift"),
            encoding: .utf8)
        XCTAssertEqual(source.components(separatedBy: #"marker: "import-\("#).count - 1, 2,
                       "both the preview and the commit must use the same per-source marker, "
                       + "or the preview's dedup count will not match what the import does")
    }
}

/// A Maccy-shaped store, text only: row n first copied at 2024-01-01 + n minutes (Apple epoch,
/// which `stageMaccy`'s `appleDate` expects). The schema is the minimum `stageMaccy` selects.
enum MaccyFixture {
    static func write(_ count: Int, to dir: URL) throws -> String {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("Storage.sqlite").path
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw XCTSkip("sqlite3 could not open \(path)") }
        defer { sqlite3_close(db) }
        var sql = "CREATE TABLE ZHISTORYITEM (Z_PK INTEGER PRIMARY KEY, ZFIRSTCOPIEDAT REAL, ZAPPLICATION TEXT);"
            + "CREATE TABLE ZHISTORYITEMCONTENT (Z_PK INTEGER PRIMARY KEY, ZITEM INTEGER, ZTYPE TEXT, ZVALUE BLOB);"
        for n in 0..<count {
            sql += "INSERT INTO ZHISTORYITEM VALUES (\(n + 1), \(725_846_400 + n * 60), 'com.apple.Terminal');"
            sql += "INSERT INTO ZHISTORYITEMCONTENT VALUES (\(n + 1), \(n + 1), 'public.utf8-plain-text', "
                + "CAST('maccy clip \(n)' AS BLOB));"
        }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw XCTSkip("fixture SQL failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        return path
    }
}
