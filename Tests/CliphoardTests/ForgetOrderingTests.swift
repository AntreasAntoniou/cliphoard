import XCTest
import SQLite3
@testable import Cliphoard

/// "Forget image understanding" deleted the right rows in the wrong ORDER.
///
/// `Database.forgetAllImageUnderstanding()` ends in `vacuum()`, and its own doc comment
/// says why: "content-derived bytes must not linger in free pages ... a delete button that
/// does not delete, which is worse than no button." The compaction was always there. The
/// embedding deletions simply ran AFTER it, so those rows were freed into pages the VACUUM
/// had already rewritten and the bytes stayed in unallocated space.
///
/// This is the shape worth remembering: **every assertion anyone would naturally write
/// passed.** `SELECT count(*) FROM embeddings` returns 0 whichever side of the vacuum the
/// delete happens on, so a row-count test — the obvious test, and the one below — cannot
/// see the bug at all. It was found by reading the two call sites next to each other, and
/// the second loop below the vacuum call reads as harmless tidying.
///
/// So this file asserts BOTH properties, and neither is redundant:
///   1. the rows are gone at all (behavioural, and would have passed before the fix), and
///   2. the deletion precedes the compaction (structural, and is the actual fix).
///
/// **A byte-level test was written and rejected**, rather than skipped for convenience.
/// The tempting version seals a distinctive vector, records its ciphertext, and asserts
/// those bytes are absent from the file afterwards — testing the real property rather than
/// a proxy. It is not reliable here: the database runs in WAL mode (`Database.init`), so
/// pre-VACUUM page images can persist in `ditto.sqlite-wal` frames until a checkpoint that
/// no test controls. It would fail against correct code depending on checkpoint timing. A
/// flaky privacy test is worse than an honest proxy, because the first response to a flaky
/// test is to delete it.
@MainActor
final class ForgetOrderingTests: XCTestCase {

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoForget-\(UUID().uuidString)")
    }

    // MARK: - 1. The behavioural half (passes before AND after the fix — say so)

    /// The rows really are gone. This does NOT catch the ordering bug and is not intended
    /// to; it exists so the ordering fix cannot be "achieved" by dropping the deletion.
    func testForgettingLeavesNoEmbeddingRowBehind() throws {
        try skipIfKeychainUnreachable()
        let dir = tempDir()
        let store = ClipStore(directory: dir)
        try XCTSkipIf(store.safeMode, "store is frozen here, so forget correctly refuses")

        let item = ClipItem(kind: .image, text: "a screenshot")
        store.add(item)

        let path = dir.appendingPathComponent("ditto.sqlite").path
        let probe = try XCTUnwrap(Database(path: path), "could not open a second connection")
        XCTAssertTrue(
            probe.upsertEmbedding(clipID: item.id, model: "forget-ordering-test",
                                  embedding: ModelEmbedding(vector: [0.5, 0.25, 0.125])),
            "precondition: the embedding must persist, or the test proves nothing")
        XCTAssertEqual(Self.embeddingRows(atPath: path, clipID: item.id), 1,
                       "precondition: exactly one row to destroy")

        store.forgetImageUnderstanding()

        XCTAssertEqual(Self.embeddingRows(atPath: path, clipID: item.id), 0,
                       "forget left an embedding row behind — the vector is derived from "
                       + "recognised text, so the words stay reachable through semantic "
                       + "search after the user was told they were forgotten")
    }

    // MARK: - 2. The structural half (this is the one that fails on the bug)

    /// The deletion must appear BEFORE the compaction in the source of
    /// `forgetImageUnderstanding`. Asserted structurally because the observable difference
    /// is bytes in free pages, which WAL makes nondeterministic to read (see the type
    /// comment). This is a weaker test than measuring the property, and it is written this
    /// way deliberately rather than by omission.
    func testTheDeletionPrecedesTheCompaction() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Cliphoard/Clipboard/ClipStore.swift"),
            encoding: .utf8)

        let marker = "func forgetImageUnderstanding()"
        guard let start = source.range(of: marker) else {
            return XCTFail("could not find \(marker) — if it was renamed, move this test with it")
        }
        // Bounded by the next declaration so a later, unrelated call cannot satisfy this.
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    /// ") ?? rest.range(of: "\n    func ")
        let body = String(rest[..<(end?.lowerBound ?? rest.endIndex)])

        // Matched with the `db?.` prefix, so these are CALL SITES rather than any mention.
        // The first version searched for the bare names and failed against the correct fix:
        // the comment explaining the ordering names `forgetAllImageUnderstanding()` before
        // the code calls it, and a text search cannot tell prose from a call. A source-order
        // assertion is only as good as its ability to distinguish the two, and the comment
        // documenting an invariant is exactly the text most likely to break it.
        guard let delete = body.range(of: "db?.deleteEmbeddings(") else {
            return XCTFail("forgetImageUnderstanding no longer deletes embedding rows at all")
        }
        guard let compact = body.range(of: "db?.forgetAllImageUnderstanding()") else {
            return XCTFail("forgetImageUnderstanding no longer calls forgetAllImageUnderstanding")
        }

        XCTAssertLessThan(
            delete.lowerBound, compact.lowerBound,
            "deleteEmbeddings runs AFTER forgetAllImageUnderstanding, whose last act is "
            + "VACUUM. The rows are freed into pages that have already been compacted, so "
            + "their bytes stay in unallocated space — exactly the failure the VACUUM was "
            + "added to prevent. Row-count assertions pass either way; only the order tells "
            + "the truth.")
    }

    /// The compaction must still HAPPEN. Otherwise the ordering test above is satisfiable
    /// by deleting the vacuum, which would trade one leak for a larger one.
    func testTheCompactionStillHappens() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let db = try String(
            contentsOf: root.appendingPathComponent("Sources/Cliphoard/Clipboard/Database.swift"),
            encoding: .utf8)
        guard let start = db.range(of: "func forgetAllImageUnderstanding()") else {
            return XCTFail("forgetAllImageUnderstanding was renamed or removed")
        }
        let body = String(db[start.upperBound...].prefix(400))
        XCTAssertTrue(body.contains("vacuum()"),
                      "forgetAllImageUnderstanding no longer compacts, so forgotten text "
                      + "remains recoverable in free pages regardless of delete ordering")
    }

    // MARK: - helper

    /// Counted over a RAW connection rather than through `Database`. Two reasons, and the
    /// second is the real one: `prepare`/`bindText` are private, and a test auditing a
    /// privacy guarantee should not read the state through the same layer it is auditing.
    private static func embeddingRows(atPath path: String, clipID: UUID) -> Int {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return -1   // distinguishable from "no rows" at the call site
        }
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle,
                                 "SELECT COUNT(*) FROM embeddings WHERE clip_id=?;",
                                 -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (clipID.uuidString as NSString).utf8String, -1, nil)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : -1
    }
}
