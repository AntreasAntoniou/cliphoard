import XCTest
import SQLite3
@testable import Cliphoard

/// The re-index guard, and the archive ordering — the two things a mutation test showed the
/// suite could not see.
///
/// Deleting `reindexStale`'s entire safe-mode guard left all 435 tests green. The four tests
/// that appear to cover it skip on `skipIfKeychainUnreachable()` — on the KEYCHAIN, not on the
/// guard — and every one of them builds a HEALTHY store, so the guard never fires in them on
/// any machine, lid open or shut. Not a lid-closed blind spot: a total one.
@MainActor
final class FrozenReindexTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoFrozenReindex-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A store frozen by the RATIO term, over a database that WORKS.
    ///
    /// The fixture choice is the whole test. Freezing via a garbage `ditto.sqlite` also works
    /// and is what the UI tests use — but there the database is non-functional, so
    /// `deleteEmbeddings` and `upsertEmbedding` would fail anyway and the test could not
    /// distinguish "the guard refused" from "the database refused". It would pass for the
    /// wrong reason, which is this project's signature failure.
    ///
    /// Ten rows of `enc1:` bytes no key on the keyring opens: the read is COMPLETE (this is
    /// not the storage term), the database is healthy, and `shouldFreeze`'s ratio term fires
    /// on 10 of 10 unreadable. The rows are therefore PRESENT — and present rows are exactly
    /// what `reindexStale` needs in order to destroy anything.
    private func storeFrozenByUnreadableRows() throws -> ClipStore {
        let dir = tempDir()
        let path = dir.appendingPathComponent("ditto.sqlite").path
        _ = try XCTUnwrap(Database(path: path), "create the schema")
        // Raw SQL, because the point is a row whose stored text is ciphertext this process
        // cannot open — which `Database.insert` would never produce, since it seals with the
        // key this process actually holds.
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &raw, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close_v2(raw) }
        for i in 0..<10 {
            let sql = """
                INSERT INTO clips (id, kind, text, created_at, last_used_at, pinned, use_count)
                VALUES ('\(UUID().uuidString)', 'text',
                        'enc1:bm90LWEtcmVhbC1jaXBoZXJ0ZXh0LWJ1dC1zZWFsZWQ\(i)',
                        0, 0, 0, 0);
                """
            XCTAssertEqual(sqlite3_exec(raw, sql, nil, nil, nil), SQLITE_OK)
        }
        return ClipStore(directory: dir)
    }

    func testAFrozenStoreDoesNotPurgeVectorsOnReindex() throws {
        let store = try storeFrozenByUnreadableRows()
        try XCTSkipUnless(store.safeMode,
                          "the ratio fixture did not freeze the store — nothing to assert")
        XCTAssertEqual(store.items.count, 10, "precondition: the rows loaded and are present")

        // A clip vetoed AFTER it was indexed — the case the purge exists for, and the one
        // that makes the purge destructive on a store this process could not read.
        let victim = store.items[0]
        victim.flags.insert(.quarantined)
        XCTAssertTrue(victim.isIndexVetoed, "precondition")
        victim.embeddings = ["probe": ModelEmbedding(vector: [1, 0, 0])]

        store.reindexStale()

        XCTAssertFalse(victim.embeddings.isEmpty,
                       "a frozen store re-indexed and PURGED a vector. Safe mode's own log "
                       + "promises no re-index will run and nothing will be deleted, and the "
                       + "purge calls db.deleteEmbeddings on a store this process could not "
                       + "read in the first place")
        XCTAssertNil(store.indexing, "no pass may even start while frozen")
    }

    /// The converse, so the guard cannot pass by disabling re-indexing outright. Explicitly
    /// NOT the only coverage of the healthy direction — `DetectorWiringTests` covers it too.
    func testAHealthyStoreStillReindexes() throws {
        try skipIfKeychainUnreachable()
        let store = ClipStore(directory: tempDir())
        try XCTSkipIf(store.safeMode, "frozen here")
        let item = ClipItem(kind: .text, text: "meeting notes from the standup")
        store.add(item)
        item.embeddings.removeAll()

        store.reindexStale()

        XCTAssertNotNil(store.indexing, "a healthy store must still start a pass")
    }

    // MARK: - The archive ordering

    /// Preserving ciphertext is the SAFE half of the audit tool, and a completeness guard
    /// placed above the archive step disabled the non-destructive dry run in exactly the
    /// degraded-database incident the tool exists for — refusing to save what it could still
    /// read, in the name of safety.
    func testAShortReadStillArchivesAndOnlyTheDeleteIsRefused() {
        XCTAssertEqual(TagAudit.archivePlan(keychainReachable: true, readComplete: false,
                                            deleteRequested: false),
                       .archive(partial: true, thenDelete: false),
                       "a dry run on a short read must still write a partial archive")
        XCTAssertEqual(TagAudit.archivePlan(keychainReachable: true, readComplete: false,
                                            deleteRequested: true),
                       .archive(partial: true, thenDelete: false),
                       "…and must still refuse the DELETE, which is the destructive half")
        XCTAssertEqual(TagAudit.archivePlan(keychainReachable: true, readComplete: true,
                                            deleteRequested: true),
                       .archive(partial: false, thenDelete: true),
                       "the converse: a complete read must still be able to delete")
        XCTAssertEqual(TagAudit.archivePlan(keychainReachable: true, readComplete: true,
                                            deleteRequested: false),
                       .archive(partial: false, thenDelete: false))
    }

    /// The asymmetry, asserted rather than left to a comment: an unreachable keychain refuses
    /// OUTRIGHT, because it makes every row look unreadable, so the archive would be a file
    /// full of perfectly healthy clips.
    func testAnUnreachableKeychainRefusesOutrightRatherThanArchivingFalsePositives() {
        for complete in [true, false] {
            for wantsDelete in [true, false] {
                XCTAssertEqual(TagAudit.archivePlan(keychainReachable: false,
                                                    readComplete: complete,
                                                    deleteRequested: wantsDelete),
                               .refuseKeychainUnreachable)
            }
        }
    }

    /// Exit codes exist so a wrapper can tell "I refused and your data is fine" from "I
    /// broke". `2` used to mean six different things including one safety refusal.
    func testRefusalsAreDistinguishableFromFailures() {
        let codes: [TagAudit.ExitCode] = [.ok, .environment, .refusedKeychainUnreachable,
                                          .refusedIncompleteRead, .operationFailed]
        XCTAssertEqual(Set(codes.map(\.rawValue)).count, codes.count,
                       "duplicate exit codes — though this is belt and braces: the enum's "
                       + "raw values must already be unique to COMPILE")
        XCTAssertNotEqual(TagAudit.ExitCode.refusedIncompleteRead.rawValue,
                          TagAudit.ExitCode.environment.rawValue,
                          "a safety refusal must not be reported as a startup failure")
    }
}
