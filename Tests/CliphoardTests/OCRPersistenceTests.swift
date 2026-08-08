import XCTest
import SQLite3
@testable import Cliphoard

/// TP-15: persistence of recognised image text.
///
/// Three properties carry the whole design and each is cheap to break silently:
///   1. It is SEALED at rest. It is verbatim clipboard content reconstructed from
///      pixels — the same category as `text`, not the same as the deliberately-clear
///      `flags`/`shape` tokens.
///   2. NULL and "" are DISTINCT after a round trip. NULL means "never analysed" and
///      is how the background pass finds work; "" means "analysed, nothing to index"
///      (empty, undecryptable, or withheld). Collapsing them either re-analyses
///      forever or silently excludes every image.
///   3. It survives `insert`, which is INSERT OR REPLACE. Both `reKeyToSecureEnclave`
///      and `encryptExistingRows` drive that statement across every clip, so an
///      unbound column blanks every result on the next re-key — with no error.
final class OCRPersistenceTests: XCTestCase {

    private func tempPath() -> String {
        NSTemporaryDirectory() + "ocr-\(UUID().uuidString).sqlite"
    }

    private func imageClip(ocr: String?) -> ClipItem {
        let item = ClipItem(kind: .image, text: "Image 1920×1080")
        item.payloadFile = "abc123.png"
        item.imageHash = "abc123"
        item.ocrText = ocr
        return item
    }

    /// Raw column read, bypassing `Crypto.open`, so we see what actually hit disk.
    private func rawOCRColumn(id: UUID, path: String) -> (isNull: Bool, text: String?) {
        var raw: OpaquePointer?
        guard sqlite3_open_v2(path, &raw, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            XCTFail("could not reopen database"); return (false, nil)
        }
        defer { sqlite3_close_v2(raw) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(raw, "SELECT ocr_text FROM clips WHERE id=?;", -1, &stmt, nil) == SQLITE_OK
        else { XCTFail("prepare failed"); return (false, nil) }
        sqlite3_bind_text(stmt, 1, (id.uuidString as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { XCTFail("row not found"); return (false, nil) }
        if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return (true, nil) }
        return (false, sqlite3_column_text(stmt, 0).map { String(cString: $0) })
    }

    // MARK: - 1. Sealed at rest

    func testRecognisedTextIsSealedOnDisk() {
        let path = tempPath()
        let db = Database(path: path)!
        let item = imageClip(ocr: "AKIAIOSFODNN7EXAMPLE appears in this screenshot")
        XCTAssertTrue(db.insert(item))

        let raw = rawOCRColumn(id: item.id, path: path)
        XCTAssertFalse(raw.isNull)
        XCTAssertTrue(raw.text?.hasPrefix("enc1:") ?? false,
                      "recognised text must be sealed at rest, got: \(raw.text ?? "nil")")
        XCTAssertFalse(raw.text?.contains("AKIA") ?? true,
                       "plaintext of a recognised secret reached disk")
    }

    // MARK: - 2. NULL vs "" survive as distinct states

    func testNeverAnalysedRoundTripsAsNullNotEmpty() {
        let path = tempPath()
        let db = Database(path: path)!
        let item = imageClip(ocr: nil)
        XCTAssertTrue(db.insert(item))

        XCTAssertTrue(rawOCRColumn(id: item.id, path: path).isNull,
                      "an unanalysed clip must be SQL NULL, not empty text")

        let reloaded = Database(path: path)!.loadAll().first { $0.id == item.id }
        XCTAssertNil(reloaded?.ocrText,
                     "NULL must load back as nil — as \"\" it would read as 'analysed, "
                     + "nothing to index' and the background pass would skip it forever")
    }

    func testAnalysedButWithheldRoundTripsAsEmptyNotNull() {
        let path = tempPath()
        let db = Database(path: path)!
        let item = imageClip(ocr: "")          // withheld, or genuinely no text
        XCTAssertTrue(db.insert(item))

        let raw = rawOCRColumn(id: item.id, path: path)
        XCTAssertFalse(raw.isNull, "an analysed-but-withheld clip must NOT be NULL")
        XCTAssertTrue(raw.text?.hasPrefix("enc1:") ?? false,
                      "sealing \"\" must still produce ciphertext, or the two states collapse")

        let reloaded = Database(path: path)!.loadAll().first { $0.id == item.id }
        XCTAssertEqual(reloaded?.ocrText, "",
                       "\"\" must survive as \"\" — if it loads as nil the clip is analysed "
                       + "again on every launch, and a withheld secret is retried forever")
    }

    // MARK: - 3. Survives INSERT OR REPLACE (the re-key path)

    func testRecognisedTextSurvivesReSave() {
        let path = tempPath()
        let db = Database(path: path)!
        let item = imageClip(ocr: "validation accuracy by epoch")
        XCTAssertTrue(db.insert(item))

        // Exactly what a re-key does: load every clip, write every clip back.
        let loaded = db.loadAll().first { $0.id == item.id }
        XCTAssertEqual(loaded?.ocrText, "validation accuracy by epoch")
        XCTAssertTrue(db.insert(loaded!))

        let after = Database(path: path)!.loadAll().first { $0.id == item.id }
        XCTAssertEqual(after?.ocrText, "validation accuracy by epoch",
                       "recognised text was lost on re-save — `insert` is INSERT OR REPLACE, "
                       + "so an unbound column blanks every row on the next re-key")
    }

    // MARK: - Migration: an older database gains the column with rows intact

    func testOlderDatabaseGainsColumnAndReadsAsNeverAnalysed() {
        let path = tempPath()
        // A database created before the column existed, then dropped to simulate it.
        do {
            let db = Database(path: path)!
            XCTAssertTrue(db.insert(imageClip(ocr: "will be dropped")))
        }
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &raw, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, "ALTER TABLE clips DROP COLUMN ocr_text;", nil, nil, nil),
                       SQLITE_OK, "precondition: could not simulate the pre-change schema")
        sqlite3_close_v2(raw)

        // Reopening must re-add it additively, leaving the row present and unanalysed.
        let migrated = Database(path: path)!
        let items = migrated.loadAll()
        XCTAssertEqual(items.count, 1, "the migration must not lose rows")
        XCTAssertNil(items.first?.ocrText,
                     "a row that predates the column must read as nil (never analysed), "
                     + "so the background pass picks it up rather than skipping it")
    }

    // MARK: - The search-integration contract

    /// `searchText` is the single seam images enter the pipeline through. The empty
    /// fallback is what makes a withheld result invisible to the embedder, the tag
    /// index and all three substring paths without any of them knowing the rule.
    func testSearchTextPrefersRecognisedTextAndFallsBackWhenWithheld() {
        let analysed = imageClip(ocr: "git rebase --onto main")
        XCTAssertEqual(SemanticRanker.searchText(analysed), "git rebase --onto main")

        let withheld = imageClip(ocr: "")
        XCTAssertEqual(SemanticRanker.searchText(withheld), "Image 1920×1080",
                       "a withheld clip must read exactly as it did before this feature")

        let unanalysed = imageClip(ocr: nil)
        XCTAssertEqual(SemanticRanker.searchText(unanalysed), "Image 1920×1080")
    }
}
