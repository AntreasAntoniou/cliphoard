import XCTest
import SQLite3
@testable import Cliphoard

final class ScopedEmbeddingDeletionTests: XCTestCase {
    func testForgetRemovesOnlySelectedSignatureAndKeepsOtherClips() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("synthetic.sqlite").path
        let database = try XCTUnwrap(Database(path: path))
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &raw), SQLITE_OK)
        defer { sqlite3_close(raw) }
        let one = UUID(), two = UUID()
        // Public synthetic bytes; no clipboard, model download or vault access.
        XCTAssertEqual(sqlite3_exec(raw, "INSERT INTO embeddings(clip_id,model,vector) VALUES ('\(one.uuidString)','gemma-picture',X'0000'), ('\(one.uuidString)','other-model',X'0000'), ('\(two.uuidString)','gemma-picture',X'0000');", nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(database.deleteEmbedding(clipID: one, signature: "gemma-picture"))
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(raw, "SELECT clip_id,model FROM embeddings ORDER BY model", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var remaining = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            remaining.insert(String(cString: sqlite3_column_text(statement, 0)) + "/" + String(cString: sqlite3_column_text(statement, 1)))
        }
        XCTAssertEqual(remaining, [one.uuidString + "/other-model", two.uuidString + "/gemma-picture"])
    }
}
