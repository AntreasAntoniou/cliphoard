import XCTest
import SQLite3
@testable import Cliphoard

/// The invariant this whole file exists to pin: **a value meaning "I could not read"
/// must never be spent as "there is nothing there."**
///
/// That substitution destroyed ~210 clips at the keychain layer. It survived at the
/// sqlite layer for fourteen further rounds of review, because every symptom looked like
/// a different bug: a nil handle, a scan that stopped early, a count that would not
/// prepare, a `fileExists` that could not stat. They are one defect with four faces, and
/// the endpoint in every case is `sweepOrphanPayloads` deleting every image the user has.
///
/// Two deliberate design choices make this suite work on a lid-closed machine, where
/// the keychain is unreachable, every `ClipStore` is frozen, and `init` returns before
/// the destructive passes run — so anything phrased end-to-end would pass for the wrong
/// reason:
///
///  1. The `Database`-level facts need no keychain at all. `Database.init?` runs only
///     CREATE TABLE / ensureColumn, and `Crypto.open` passes plaintext through unchanged,
///     so raw-SQL fixtures with plaintext values exercise the real read path.
///  2. The refusal logic lives in pure functions on `HistoryReaper`, tested directly.
///     A rule that can only be tested in its safe state is not a tested rule.
@MainActor
final class UnreadableStorageTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoUnreadable-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A `ditto.sqlite` full of garbage. Probed behaviour, and the reason this fixture is
    /// the interesting one: `sqlite3_open_v2` defers header validation, so the handle
    /// opens (rc 0) and `Database.init?` SUCCEEDS. `guard let db` does not save you here.
    /// Every statement then fails with rc 26 (SQLITE_NOTADB), so the table is never
    /// created, the count cannot prepare, and the scan yields nothing.
    @discardableResult
    private func writeGarbageDatabase(in dir: URL) -> String {
        let path = dir.appendingPathComponent("ditto.sqlite").path
        try? Data(repeating: 0xFF, count: 100).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func writePNG(_ name: String, in dir: URL) {
        try? Data([0x89, 0x50, 0x4E, 0x47]).write(to: dir.appendingPathComponent(name))
    }

    // MARK: - T1/T2 — the database stops lying (no keychain needed; always runs)

    func testACountThatCouldNotRunIsUnavailableNotZero() throws {
        let dir = tempDir()
        let path = writeGarbageDatabase(in: dir)
        let db = try XCTUnwrap(Database(path: path),
                               "precondition: sqlite opens the handle before validating "
                               + "the header, so a corrupt file yields a LIVE Database")

        // Before this change `clipCount()` returned 0 here, and `items.count == 0` then
        // satisfied the guard that was written to catch exactly this case.
        guard case .unavailable = db.clipCountStatus() else {
            return XCTFail("a count that could not be taken reported a number — 0 == 0 is "
                           + "how total read failure passes a completeness check")
        }
    }

    func testAnUnreadableDatabaseIsNotACompleteEmptyHistory() throws {
        let dir = tempDir()
        let db = try XCTUnwrap(Database(path: writeGarbageDatabase(in: dir)))

        guard case .unavailable = db.loadAllStatus() else {
            return XCTFail("an unreadable database reported a COMPLETE history, which "
                           + "entitles the sweep to delete every payload on disk")
        }
        XCTAssertTrue(db.loadAll().isEmpty,
                      "loadAll still returns rows-or-nothing; safety comes from the token, "
                      + "not from removing the convenience accessor")
    }

    // MARK: - T3 — a short read is not a smaller history (no keychain needed)

    /// The subtlest face of the defect: sqlite is entirely healthy. One row simply cannot
    /// be materialised, the clips scan skips it silently, and that clip's PNG then looks
    /// unreferenced to the sweep.
    func testARowThatCannotBeMaterialisedIsAShortReadNotAsmallerHistory() throws {
        let dir = tempDir()
        let path = dir.appendingPathComponent("ditto.sqlite").path
        do {
            let db = try XCTUnwrap(Database(path: path))
            for i in 0..<3 { db.insert(ClipItem(kind: .text, text: "clip \(i)")) }
            XCTAssertEqual(db.clipCountStatus(), .counted(3), "precondition")
        }
        // Break exactly one id, leaving the row present and countable.
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &raw, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, "UPDATE clips SET id='not-a-uuid' "
                                    + "WHERE id=(SELECT id FROM clips LIMIT 1);",
                                    nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(raw)

        let db = try XCTUnwrap(Database(path: path))
        XCTAssertEqual(db.clipCountStatus(), .counted(3),
                       "the row is still there and still counted")
        guard case .unavailable(.short(let loaded, let stored)) = db.loadAllStatus() else {
            return XCTFail("a silently skipped row was reported as a complete history")
        }
        XCTAssertEqual(loaded, 2)
        XCTAssertEqual(stored, 3)
    }

    /// The converse, and the one that stops the fix passing by disabling the feature: a
    /// healthy database must still report `.complete`, and must still mint a token.
    func testAHealthyDatabaseStillReportsACompleteHistory() throws {
        let dir = tempDir()
        let db = try XCTUnwrap(Database(path: dir.appendingPathComponent("ditto.sqlite").path))
        let img = ClipItem(kind: .image, text: "Image 4×4")
        img.payloadFile = "live.png"
        db.insert(img)
        db.insert(ClipItem(kind: .text, text: "hello"))

        guard case .complete(let rows, let proof) = db.loadAllStatus() else {
            return XCTFail("a healthy database must still load completely, or this fix has "
                           + "simply broken loading")
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(proof.storedCount, 2)
        XCTAssertEqual(proof.referencedPayloads, ["live.png"])
        XCTAssertEqual(proof.imagePayloadsByClip, [img.id: "live.png"])
    }

    /// A genuinely fresh install: empty, but REPORTEDLY empty. This is the distinction the
    /// whole change turns on — `.counted(0)` is `.absent`, not `.unavailable`.
    func testAFreshStoreIsCompleteAndEmpty() throws {
        let dir = tempDir()
        let db = try XCTUnwrap(Database(path: dir.appendingPathComponent("ditto.sqlite").path))
        XCTAssertEqual(db.clipCountStatus(), .counted(0))
        guard case .complete(let rows, let proof) = db.loadAllStatus() else {
            return XCTFail("an empty store must be COMPLETE — otherwise a fresh install "
                           + "would freeze and never sweep")
        }
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(proof.storedCount, 0)
    }

    // MARK: - T5/T6/T7 — the refusals (pure; these can never skip)

    func testASweepIsRefusedWhenTheDirectoryCannotBeListed() {
        XCTAssertNil(HistoryReaper.sweepDecision(onDisk: nil, referenced: []),
                     "\"I could not enumerate\" is not \"there is nothing there\"")
        XCTAssertNil(HistoryReaper.orphanDecision(onDisk: nil, imagePayloadsByClip: [:]),
                     "the row path collapsed the same way, via per-file fileExists")
    }

    /// The case no count check can reach: the read genuinely succeeded and the history
    /// genuinely is empty (a zero-byte or restored database counts a truthful 0), while
    /// every payload is still on disk.
    func testASweepIsRefusedWhenItWouldTakeMostOfTheDirectory() {
        let onDisk = Set((0..<12).map { "img\($0).png" })
        XCTAssertNil(HistoryReaper.sweepDecision(onDisk: onDisk, referenced: []),
                     "deleting 12 of 12 payloads is not housekeeping")

        // And it is not merely a one-launch delay: keying on \"the store is empty\" would
        // stop refusing the moment a single unrelated clip arrives.
        XCTAssertNil(HistoryReaper.sweepDecision(onDisk: onDisk, referenced: ["img0.png"]),
                     "11 of 12 is still most of the directory — one new clip must not "
                     + "re-arm the deletion")
    }

    /// The anti-lobotomy assertion. Without it, `return nil` always would pass every
    /// other test in this file.
    func testAnOrdinarySweepStillDeletesStrays() {
        let onDisk: Set<String> = ["a.png", "a-thumb.png", "stray.png"]
        XCTAssertEqual(HistoryReaper.sweepDecision(onDisk: onDisk, referenced: ["a.png"]),
                       ["stray.png"],
                       "the sweep must still WORK — a live thumbnail is kept, a stray goes")

        // A healthy, populated store: 300 images + 300 thumbs + 3 strays sweeps normally.
        var big = Set((0..<300).map { "c\($0).png" })
        let referenced = big
        big.formUnion((0..<300).map { "c\($0)-thumb.png" })
        big.formUnion(["x1.png", "x2.png", "x3.png"])
        XCTAssertEqual(HistoryReaper.sweepDecision(onDisk: big, referenced: referenced),
                       ["x1.png", "x2.png", "x3.png"])

        // Under the floor, ordinary housekeeping is untouched.
        XCTAssertEqual(HistoryReaper.sweepDecision(onDisk: ["a.png", "b.png"], referenced: []),
                       ["a.png", "b.png"],
                       "a small directory of genuine strays must still be swept")
    }

    func testRowDeletionIsRefusedWhenItWouldTakeMostOfTheImages() {
        let ids = (0..<12).map { _ in UUID() }
        var byClip: [UUID: String] = [:]
        for (i, id) in ids.enumerated() { byClip[id] = "img\(i).png" }

        XCTAssertNil(HistoryReaper.orphanDecision(onDisk: [], imagePayloadsByClip: byClip),
                     "an empty-but-listable directory facing 12 image rows is the same "
                     + "catastrophe through a different door")

        // The converse: one genuinely missing payload is still reaped.
        var present = Set(byClip.values); present.remove("img7.png")
        XCTAssertEqual(HistoryReaper.orphanDecision(onDisk: present, imagePayloadsByClip: byClip),
                       [ids[7]],
                       "a single vanished payload must still drop its row")
    }

    // MARK: - The population the proportion is taken over

    /// Thumbnail coverage is NON-UNIFORM by construction — `writeThumbnail` is
    /// best-effort and `removePayload` deletes a clip's thumb with its original — so live
    /// payloads mostly have sidecars and dead ones often do not. Counting FILES therefore
    /// let the "more than half" rule slide anywhere between a third and two thirds. A
    /// probe that gives every payload a thumb makes the bug invisible, which is exactly
    /// what happened: two independent reviewers measured this and reached opposite
    /// conclusions, and the one who probed uniform coverage called it a non-issue.
    func testTheSweepCountsPayloadsNotFilesWhenCoverageIsUneven() {
        // 20 live clips WITH thumbs, 21 dead originals WITHOUT. 21 of 41 files is barely
        // over half so the file-counted rule refused nothing — but it is 21 of 41
        // PAYLOADS, which is over half, and must refuse.
        var onDisk = Set<String>()
        var referenced = Set<String>()
        for i in 0..<20 { onDisk.insert("live\(i).png"); onDisk.insert("live\(i)-thumb.png")
                          referenced.insert("live\(i).png") }
        for i in 0..<21 { onDisk.insert("dead\(i).png") }
        XCTAssertNil(HistoryReaper.sweepDecision(onDisk: onDisk, referenced: referenced),
                     "21 dead payloads of 41 is over half — the file count hid it behind "
                     + "20 live sidecars")

        // The converse, and the direction that would LOBOTOMISE the sweep: 20 live bare,
        // 11 dead each carrying a thumb. 22 of 31 FILES reads as disproportionate; 11 of
        // 31 payloads is ordinary housekeeping and must proceed.
        var onDisk2 = Set<String>()
        var referenced2 = Set<String>()
        for i in 0..<20 { onDisk2.insert("live\(i).png"); referenced2.insert("live\(i).png") }
        for i in 0..<11 { onDisk2.insert("dead\(i).png"); onDisk2.insert("dead\(i)-thumb.png") }
        XCTAssertEqual(HistoryReaper.sweepDecision(onDisk: onDisk2, referenced: referenced2)?.count,
                       22,
                       "11 dead payloads of 31 is routine housekeeping; the file count "
                       + "refused it and left 22 stray files forever")
    }

    /// The FLOOR still counts FILES, and this is the test that stops someone "tidying" it
    /// into payload counting on both sides. Nine images with thumbs whose database
    /// truthfully reports zero — the flagship scenario of this entire effort — is 18 files
    /// but 9 payloads, so a payload-counted floor falls under 10 and deletes all nine.
    func testTheFloorCountsFilesSoASmallStoreIsStillProtected() {
        var onDisk = Set<String>()
        for i in 0..<9 { onDisk.insert("img\(i).png"); onDisk.insert("img\(i)-thumb.png") }
        XCTAssertNil(HistoryReaper.sweepDecision(onDisk: onDisk, referenced: []),
                     "a nine-image store facing a truthfully-empty database must refuse; "
                     + "counting payloads on both sides drops it below the floor and "
                     + "destroys every image")
    }

    /// Under UNIFORM coverage the two readings agree exactly — which is why a probe that
    /// gives every payload a sidecar concludes there is no bug. 15 live + 15 dead, all
    /// thumbed: 15 of 30 payloads and 30 of 60 files are both exactly half, and half is
    /// not MORE than half, so both readings sweep. Pinned as a deliberate no-op.
    func testUniformThumbnailCoverageDecidesIdenticallyEitherWay() {
        var onDisk = Set<String>()
        var referenced = Set<String>()
        for i in 0..<15 { onDisk.insert("a\(i).png"); onDisk.insert("a\(i)-thumb.png")
                          referenced.insert("a\(i).png") }
        for i in 0..<15 { onDisk.insert("b\(i).png"); onDisk.insert("b\(i)-thumb.png") }
        XCTAssertEqual(HistoryReaper.sweepDecision(onDisk: onDisk, referenced: referenced)?.count,
                       30,
                       "exactly half is not more than half, under either population — the "
                       + "agreement here is precisely what hides the non-uniform defect")
    }

    /// The row pass had the same defect through `max(onDisk.count, rows.count)`: sidecars
    /// inflated the denominator, so it refused only above two thirds while documenting one
    /// half.
    func testRowDeletionCountsRowsNotFiles() {
        let ids = (0..<20).map { _ in UUID() }
        var byClip: [UUID: String] = [:]
        for (i, id) in ids.enumerated() { byClip[id] = "img\(i).png" }
        // 20 rows, 11 payloads missing. On disk: the 9 survivors plus 21 stray thumbs.
        var onDisk = Set<String>()
        for i in 11..<20 { onDisk.insert("img\(i).png") }
        for i in 0..<21 { onDisk.insert("t\(i)-thumb.png") }
        XCTAssertNil(HistoryReaper.orphanDecision(onDisk: onDisk, imagePayloadsByClip: byClip),
                     "11 of 20 image ROWS is over half; the inflated denominator (30 files) "
                     + "made it read as under a third")
    }

    // MARK: - The freeze decision, term by term

    /// `safeMode` itself cannot be tested term by term on this machine: the canary term is
    /// unconditionally true here, so every end-to-end assertion is satisfied by it alone —
    /// deleting the sqlite term outright survived the entire suite, which is how the gap
    /// was found. A pure function has no such blind spot.
    func testEachFreezeTermFiresOnItsOwn() {
        XCTAssertTrue(ClipStore.shouldFreeze(storageComplete: false, decryptionHealthy: true,
                                             itemCount: 0, unreadableCount: 0),
                      "a load that could not be proven complete must freeze ON ITS OWN")
        XCTAssertTrue(ClipStore.shouldFreeze(storageComplete: true, decryptionHealthy: false,
                                             itemCount: 0, unreadableCount: 0))
        XCTAssertTrue(ClipStore.shouldFreeze(storageComplete: true, decryptionHealthy: true,
                                             itemCount: 12, unreadableCount: 7))
        XCTAssertFalse(ClipStore.shouldFreeze(storageComplete: true, decryptionHealthy: true,
                                              itemCount: 12, unreadableCount: 6),
                       "exactly half is not MORE than half")
        XCTAssertFalse(ClipStore.shouldFreeze(storageComplete: true, decryptionHealthy: true,
                                              itemCount: 9, unreadableCount: 9),
                       "the floor is deliberate, not accidental")
        XCTAssertFalse(ClipStore.shouldFreeze(storageComplete: true, decryptionHealthy: true,
                                              itemCount: 0, unreadableCount: 0),
                       "and the converse, so a fix cannot pass by freezing everything")
    }

    // MARK: - The scan that never ran

    /// `prepareEach` starts at `SQLITE_ERROR` because a failed prepare never enters the
    /// loop and must not report the value meaning "reached the end". Nothing asserted it:
    /// changing the initial value to `SQLITE_DONE` left all 428 tests green while minting
    /// a COMPLETE history — and a token — from a scan that never ran.
    ///
    /// Renames a COLUMN, not the table: `Database.init` runs `CREATE TABLE IF NOT EXISTS`,
    /// which silently repairs a dropped table and would make this fixture test nothing.
    func testAScanWhoseStatementWillNotPrepareIsNotACompleteRead() throws {
        let dir = tempDir()
        let path = dir.appendingPathComponent("ditto.sqlite").path
        do {
            let db = try XCTUnwrap(Database(path: path))
            db.insert(ClipItem(kind: .text, text: "hello"))
            XCTAssertEqual(db.clipCountStatus(), .counted(1), "precondition")
        }
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &raw, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, "ALTER TABLE embeddings RENAME COLUMN vector TO vector_x;",
                                    nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(raw)

        let db = try XCTUnwrap(Database(path: path))
        XCTAssertEqual(db.clipCountStatus(), .counted(1), "the clips table is untouched")
        guard case .unavailable(.embeddingScanStoppedEarly) = db.loadAllStatus() else {
            return XCTFail("a scan whose statement would not even PREPARE was reported as a "
                           + "complete read — the reapers are then entitled to delete on it")
        }
    }

    // MARK: - Loading inside someone else's transaction

    /// `loadAllStatus` used to `BEGIN`/`COMMIT`. Inside a caller's transaction that
    /// committed the CALLER's work early and turned its ROLLBACK into "no transaction is
    /// active", so a write it had decided to discard survived. SAVEPOINT nests legally.
    /// Nothing reaches this today; the point is that the next caller cannot get it wrong.
    func testALoadInsideATransactionDoesNotCommitIt() throws {
        let dir = tempDir()
        let path = dir.appendingPathComponent("ditto.sqlite").path
        let db = try XCTUnwrap(Database(path: path))
        db.insert(ClipItem(kind: .text, text: "before"))
        let observer = try XCTUnwrap(Database(path: path))

        var seenMidTransaction: Database.CountRead = .unavailable(0)
        _ = db.transaction {
            db.insert(ClipItem(kind: .text, text: "in flight"))
            _ = db.loadAll()
            seenMidTransaction = observer.clipCountStatus()
        }
        XCTAssertEqual(seenMidTransaction, .counted(1),
                       "a second connection saw the in-flight write, so the load had "
                       + "already COMMITTED the enclosing transaction — its ROLLBACK would "
                       + "then discard nothing")
    }

    // MARK: - T4 — the store refuses to treat a failed load as an empty one

    /// `storageComplete` is assigned BEFORE the safe-mode early return, which is what
    /// makes this assertable on a lid-closed machine.
    ///
    /// HONESTY NOTE: the payload-survival assertion below is real only when the keychain
    /// is reachable. Lid-closed the store is already frozen and `init` returns before the
    /// sweep, so the PNGs would survive for the wrong reason — hence the skip. The
    /// `storageComplete` assertion is genuine either way, and `testASweepIsRefused…`
    /// covers the same logic purely and unconditionally.
    func testAFailedLoadIsNotReportedAsAnEmptyStore() throws {
        let dir = tempDir()
        writeGarbageDatabase(in: dir)
        for i in 0..<5 { writePNG("img\(i).png", in: dir) }

        let store = ClipStore(directory: dir)

        XCTAssertFalse(store.storageComplete,
                       "an unreadable database was reported as a complete, empty history")
        XCTAssertTrue(store.safeMode,
                      "a load that could not be proven complete must freeze the store — "
                      + "safeMode used to be computed only from `items`, so an empty "
                      + "FAILED load left it off")

        try skipIfKeychainUnreachable()
        for i in 0..<5 {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: dir.appendingPathComponent("img\(i).png").path),
                "the orphan sweep deleted an image payload on the strength of a load that "
                + "failed — one transient sqlite error, every image gone")
        }
    }

    /// A one-shot marker stamped after a failed load retires its migration permanently:
    /// the next healthy launch never revisits those rows.
    func testMigrationMarkersAreNotStampedAfterAFailedLoad() throws {
        try skipIfKeychainUnreachable()
        let dir = tempDir()
        writeGarbageDatabase(in: dir)
        let key = "dbEncryptedV1"
        let previous = UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(false, forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }

        let store = ClipStore(directory: dir)

        XCTAssertFalse(store.storageComplete)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: key),
                       "a marker was stamped for work that never happened")
    }
}
