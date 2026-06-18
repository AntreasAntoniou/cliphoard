import Foundation
import SQLite3

/// Thin SQLite store for the clipboard history. Replaces the whole-file JSON
/// rewrite with incremental row operations, and stores embedding vectors as
/// compact Float16 BLOBs instead of bloated JSON text.
///
/// All access is on the main actor (mirroring `ClipStore`), so no extra locking.
final class Database {
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(path: String) {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            NSLog("Ditto: failed to open db at \(path)")
            return nil
        }
        exec("PRAGMA journal_mode = WAL;")
        exec("PRAGMA foreign_keys = ON;")
        exec("PRAGMA busy_timeout = 5000;")     // wait out brief WAL contention
        exec("PRAGMA synchronous = NORMAL;")
        exec("""
        CREATE TABLE IF NOT EXISTS clips (
            id TEXT PRIMARY KEY, kind TEXT NOT NULL, text TEXT NOT NULL,
            rtf BLOB, payload_file TEXT, file_path TEXT, color_hex TEXT,
            created_at REAL NOT NULL, last_used_at REAL NOT NULL,
            pinned INTEGER NOT NULL, source_app TEXT, use_count INTEGER NOT NULL);
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS embeddings (
            clip_id TEXT NOT NULL, model TEXT NOT NULL,
            vector BLOB NOT NULL, tags TEXT NOT NULL,
            PRIMARY KEY (clip_id, model),
            FOREIGN KEY (clip_id) REFERENCES clips(id) ON DELETE CASCADE);
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_clips_order ON clips(pinned, last_used_at);")
    }

    deinit { sqlite3_close_v2(db) }   // v2 tolerates outstanding statements

    // MARK: Reads

    func clipCount() -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM clips;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    /// Load every clip with its embeddings, newest/pinned first.
    func loadAll() -> [ClipItem] {
        // 1. Embeddings grouped by clip id.
        var embByClip: [String: [String: ModelEmbedding]] = [:]
        prepareEach("SELECT clip_id, model, vector, tags FROM embeddings;") { stmt in
            let clipID = column(stmt, 0)
            let model = column(stmt, 1)
            let vec = Self.vectorFromBlob(stmt, 2)
            let tags = Self.tags(fromText: column(stmt, 3))
            embByClip[clipID, default: [:]][model] = ModelEmbedding(vector: vec, tags: tags)
        }
        // 2. Clips.
        var result: [ClipItem] = []
        prepareEach("""
            SELECT id, kind, text, rtf, payload_file, file_path, color_hex,
                   created_at, last_used_at, pinned, source_app, use_count
            FROM clips ORDER BY pinned DESC, last_used_at DESC;
            """) { stmt in
            let idStr = column(stmt, 0)
            guard let id = UUID(uuidString: idStr) else { return }
            let item = ClipItem(
                id: id,
                kind: ClipKind(rawValue: column(stmt, 1)) ?? .text,
                text: column(stmt, 2),
                rtf: Self.blob(stmt, 3),
                payloadFile: columnOpt(stmt, 4),
                filePath: columnOpt(stmt, 5),
                colorHex: columnOpt(stmt, 6),
                createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 7)),
                lastUsedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 8)),
                pinned: sqlite3_column_int(stmt, 9) != 0,
                sourceApp: columnOpt(stmt, 10),
                useCount: Int(sqlite3_column_int(stmt, 11)))
            item.embeddings = embByClip[idStr] ?? [:]
            result.append(item)
        }
        return result
    }

    // MARK: Writes

    @discardableResult
    func insert(_ item: ClipItem) -> Bool {
        let sql = """
            INSERT OR REPLACE INTO clips
            (id, kind, text, rtf, payload_file, file_path, color_hex,
             created_at, last_used_at, pinned, source_app, use_count)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?);
            """
        var ok = false
        prepare(sql) { stmt in
            bindText(stmt, 1, item.id.uuidString)
            bindText(stmt, 2, item.kind.rawValue)
            bindText(stmt, 3, item.text)
            bindBlob(stmt, 4, item.rtf)
            bindText(stmt, 5, item.payloadFile)
            bindText(stmt, 6, item.filePath)
            bindText(stmt, 7, item.colorHex)
            sqlite3_bind_double(stmt, 8, item.createdAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 9, item.lastUsedAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_int(stmt, 10, item.pinned ? 1 : 0)
            bindText(stmt, 11, item.sourceApp)
            sqlite3_bind_int(stmt, 12, Int32(item.useCount))
            ok = step(stmt)
        }
        for (model, emb) in item.embeddings { upsertEmbedding(clipID: item.id, model: model, embedding: emb) }
        return ok
    }

    /// Update the mutable metadata of an existing clip (pin, recency, kind, …).
    @discardableResult
    func updateMeta(_ item: ClipItem) -> Bool {
        var ok = false
        prepare("UPDATE clips SET kind=?, last_used_at=?, pinned=?, use_count=? WHERE id=?;") { stmt in
            bindText(stmt, 1, item.kind.rawValue)
            sqlite3_bind_double(stmt, 2, item.lastUsedAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_int(stmt, 3, item.pinned ? 1 : 0)
            sqlite3_bind_int(stmt, 4, Int32(item.useCount))
            bindText(stmt, 5, item.id.uuidString)
            ok = step(stmt)
        }
        return ok
    }

    @discardableResult
    func upsertEmbedding(clipID: UUID, model: String, embedding: ModelEmbedding) -> Bool {
        var ok = false
        prepare("INSERT OR REPLACE INTO embeddings (clip_id, model, vector, tags) VALUES (?,?,?,?);") { stmt in
            bindText(stmt, 1, clipID.uuidString)
            bindText(stmt, 2, model)
            bindBlob(stmt, 3, Self.blob(fromVector: embedding.vector))
            bindText(stmt, 4, embedding.tags.map(String.init).joined(separator: ","))
            ok = step(stmt)
        }
        return ok
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        var ok = false
        prepare("DELETE FROM clips WHERE id=?;") { stmt in
            bindText(stmt, 1, id.uuidString); ok = step(stmt)
        }
        return ok
    }

    func deleteUnpinned() { exec("DELETE FROM clips WHERE pinned=0;") }

    func delete(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        transaction { for id in ids { delete(id: id) } }
    }

    func transaction(_ body: () -> Void) {
        exec("BEGIN;"); body(); exec("COMMIT;")
    }

    // MARK: Low-level helpers

    private func exec(_ sql: String) {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            NSLog("Ditto db exec error: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func prepare(_ sql: String, _ body: (OpaquePointer?) -> Void) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK { body(stmt) }
        else { NSLog("Ditto db prepare error: \(String(cString: sqlite3_errmsg(db)))") }
    }

    /// Run a write statement to completion, logging the SQLite error on failure.
    /// Returns true only when the step reaches SQLITE_DONE.
    private func step(_ stmt: OpaquePointer?) -> Bool {
        if sqlite3_step(stmt) == SQLITE_DONE { return true }
        NSLog("Ditto db step error: \(String(cString: sqlite3_errmsg(db)))")
        return false
    }

    private func prepareEach(_ sql: String, _ row: (OpaquePointer?) -> Void) {
        prepare(sql) { stmt in while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) } }
    }

    private func bindText(_ stmt: OpaquePointer?, _ i: Int32, _ s: String?) {
        if let s { sqlite3_bind_text(stmt, i, s, -1, Self.transient) } else { sqlite3_bind_null(stmt, i) }
    }

    private func bindBlob(_ stmt: OpaquePointer?, _ i: Int32, _ d: Data?) {
        guard let d, !d.isEmpty else { sqlite3_bind_null(stmt, i); return }
        d.withUnsafeBytes { sqlite3_bind_blob(stmt, i, $0.baseAddress, Int32(d.count), Self.transient) }
    }
}

// MARK: Column readers (free functions to keep call sites short)

private func column(_ stmt: OpaquePointer?, _ i: Int32) -> String {
    guard let c = sqlite3_column_text(stmt, i) else { return "" }
    return String(cString: c)
}
private func columnOpt(_ stmt: OpaquePointer?, _ i: Int32) -> String? {
    sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : column(stmt, i)
}

extension Database {
    static func blob(_ stmt: OpaquePointer?, _ i: Int32) -> Data? {
        guard sqlite3_column_type(stmt, i) != SQLITE_NULL, let p = sqlite3_column_blob(stmt, i) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
    }

    /// [Float] → Float16 BLOB (model already runs in Float16; halves storage).
    static func blob(fromVector v: [Float]) -> Data {
        let halves = v.map { Float16($0) }
        return halves.withUnsafeBytes { Data($0) }
    }

    static func vectorFromBlob(_ stmt: OpaquePointer?, _ i: Int32) -> [Float] {
        guard let data = blob(stmt, i) else { return [] }
        let stride = MemoryLayout<Float16>.stride
        guard data.count % stride == 0 else {   // malformed blob → treat as no vector
            NSLog("Ditto db: embedding blob length \(data.count) not a multiple of \(stride)")
            return []
        }
        let count = data.count / stride
        // loadUnaligned: a Data buffer is not guaranteed 2-byte aligned, so a
        // bound Float16 pointer would be undefined behavior.
        return data.withUnsafeBytes { raw in
            (0..<count).map { Float(raw.loadUnaligned(fromByteOffset: $0 * stride, as: Float16.self)) }
        }
    }

    static func tags(fromText s: String) -> [Int] {
        s.isEmpty ? [] : s.split(separator: ",").compactMap { Int($0) }
    }
}
