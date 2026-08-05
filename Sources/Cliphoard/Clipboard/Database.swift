import Foundation
import SQLite3

/// Thin SQLite store for the clipboard history. Replaces the whole-file JSON
/// rewrite with incremental row operations, and stores embedding vectors as
/// compact Float16 BLOBs instead of bloated JSON text.
///
/// All access is on the main actor (mirroring `ClipStore`), so no extra locking.
final class Database {
    private var db: OpaquePointer?
    /// Set true by `step` whenever a write inside the current transaction fails,
    /// so `transaction` rolls back instead of committing a partial write.
    private var txnFailed = false
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(path: String) {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            NSLog("Cliphoard: failed to open db at \(path)")
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
            pinned INTEGER NOT NULL, source_app TEXT, use_count INTEGER NOT NULL,
            user_tags TEXT);
        """)
        ensureColumn("user_tags", definition: "TEXT", in: "clips")
        exec("""
        CREATE TABLE IF NOT EXISTS embeddings (
            clip_id TEXT NOT NULL, model TEXT NOT NULL,
            vector BLOB NOT NULL, tags TEXT NOT NULL,
            PRIMARY KEY (clip_id, model),
            FOREIGN KEY (clip_id) REFERENCES clips(id) ON DELETE CASCADE);
        """)
        // Suggested user tags the user has explicitly dismissed for a clip, so the
        // suggestion loop (spec §5.1) never re-offers them. `tag` holds the SEALED
        // tag (user content, same at-rest guarantee as `clips.user_tags`); the
        // composite key therefore only catches byte-identical ciphertext, so the
        // write path de-duplicates by decrypting the clip's existing rows.
        exec("""
        CREATE TABLE IF NOT EXISTS user_tag_dismissals (
            tag TEXT NOT NULL, clip_id TEXT NOT NULL,
            PRIMARY KEY (tag, clip_id));
        """)
        // Deliberately NO foreign key to clips: `insert` uses INSERT OR REPLACE,
        // which deletes+reinserts a clip row on every re-save, and an ON DELETE
        // CASCADE would silently wipe that clip's dismissals each time. Dismissals
        // are instead pruned explicitly when a clip is genuinely deleted (see
        // `delete(id:)` / `deleteUnpinned`).
        exec("CREATE INDEX IF NOT EXISTS idx_dismissals_clip ON user_tag_dismissals(clip_id);")
        exec("CREATE INDEX IF NOT EXISTS idx_clips_order ON clips(pinned, last_used_at);")
    }

    /// One dismissed `(tag, clip)` suggestion pair.
    struct UserTagDismissal: Hashable {
        let tag: String
        let clipID: UUID
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
            // Decrypt at-rest embedding columns (legacy plaintext passes through).
            let vec = Self.vectorFromBlob(Crypto.open(Self.blob(stmt, 2)))
            let tags = Self.tags(fromText: Crypto.open(column(stmt, 3)))
            embByClip[clipID, default: [:]][model] = ModelEmbedding(vector: vec, tags: tags)
        }
        // 2. Clips.
        var result: [ClipItem] = []
        prepareEach("""
            SELECT id, kind, text, rtf, payload_file, file_path, color_hex,
                   created_at, last_used_at, pinned, source_app, use_count, user_tags
            FROM clips ORDER BY pinned DESC, last_used_at DESC;
            """) { stmt in
            let idStr = column(stmt, 0)
            guard let id = UUID(uuidString: idStr) else { return }
            let item = ClipItem(
                id: id,
                kind: ClipKind(rawValue: column(stmt, 1)) ?? .text,
                // Decrypt content (legacy plaintext rows pass through unchanged).
                text: Crypto.open(column(stmt, 2)),
                rtf: Crypto.open(Self.blob(stmt, 3)),
                payloadFile: columnOpt(stmt, 4),
                filePath: columnOpt(stmt, 5).map(Crypto.open),
                colorHex: columnOpt(stmt, 6).map(Crypto.open),
                createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 7)),
                lastUsedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 8)),
                pinned: sqlite3_column_int(stmt, 9) != 0,
                sourceApp: columnOpt(stmt, 10),
                useCount: Int(sqlite3_column_int(stmt, 11)),
                userTags: Self.userTags(fromText: columnOpt(stmt, 12).map(Crypto.open) ?? ""))
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
             created_at, last_used_at, pinned, source_app, use_count, user_tags)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """
        // Encrypt the actual clipboard CONTENT at rest (text, rich text, file
        // path, color). Metadata (id, kind, timestamps, source app) stays clear.
        // Fail CLOSED: if any content column can't be sealed we refuse the whole
        // insert rather than let plaintext reach disk. `sealStrict` returns nil
        // only if AES-GCM seal genuinely fails (effectively never) — a backstop.
        guard let encText = Crypto.sealStrict(item.text) else {
            NSLog("Cliphoard db: content seal failed — refusing insert (text)"); return false
        }
        var encRTF: Data? = nil
        if let rtf = item.rtf {
            guard let s = Crypto.sealStrict(rtf) else {
                NSLog("Cliphoard db: content seal failed — refusing insert (rtf)"); return false
            }
            encRTF = s
        }
        var encPath: String? = nil
        if let path = item.filePath {
            guard let s = Crypto.sealStrict(path) else {
                NSLog("Cliphoard db: content seal failed — refusing insert (path)"); return false
            }
            encPath = s
        }
        var encColor: String? = nil
        if let color = item.colorHex {
            guard let s = Crypto.sealStrict(color) else {
                NSLog("Cliphoard db: content seal failed — refusing insert (color)"); return false
            }
            encColor = s
        }
        let normalizedTags = ClipItem.normalizedUserTags(item.userTags)
        guard let encUserTags = Crypto.sealStrict(normalizedTags.joined(separator: "\n")) else {
            NSLog("Cliphoard db: user-tag seal failed — refusing insert"); return false
        }
        var ok = false
        prepare(sql) { stmt in
            bindText(stmt, 1, item.id.uuidString)
            bindText(stmt, 2, item.kind.rawValue)
            bindText(stmt, 3, encText)
            bindBlob(stmt, 4, encRTF)
            bindText(stmt, 5, item.payloadFile)
            bindText(stmt, 6, encPath)
            bindText(stmt, 7, encColor)
            sqlite3_bind_double(stmt, 8, item.createdAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 9, item.lastUsedAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_int(stmt, 10, item.pinned ? 1 : 0)
            bindText(stmt, 11, item.sourceApp)
            sqlite3_bind_int(stmt, 12, Int32(item.useCount))
            bindText(stmt, 13, encUserTags)
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

    /// Persist only user-owned tags. Sealing happens before SQLite is touched;
    /// a crypto failure leaves the previous value intact.
    @discardableResult
    func updateUserTags(_ item: ClipItem) -> Bool {
        let normalized = ClipItem.normalizedUserTags(item.userTags)
        guard let sealed = Crypto.sealStrict(normalized.joined(separator: "\n")) else {
            NSLog("Cliphoard db: user-tag seal failed — refusing update")
            return false
        }
        var ok = false
        prepare("UPDATE clips SET user_tags=? WHERE id=?;") { stmt in
            bindText(stmt, 1, sealed)
            bindText(stmt, 2, item.id.uuidString)
            ok = step(stmt)
        }
        return ok
    }

    // MARK: User-tag suggestion dismissals

    /// Every dismissed `(tag, clipID)` pair, decrypted. Legacy/plaintext values
    /// pass through `Crypto.open` unchanged, exactly like `user_tags`.
    func userTagDismissals() -> Set<UserTagDismissal> {
        var result: Set<UserTagDismissal> = []
        prepareEach("SELECT tag, clip_id FROM user_tag_dismissals;") { stmt in
            guard let clipID = UUID(uuidString: column(stmt, 1)),
                  let tag = ClipItem.normalizedUserTags([Crypto.open(column(stmt, 0))]).first
            else { return }
            result.insert(UserTagDismissal(tag: tag, clipID: clipID))
        }
        return result
    }

    /// Tags dismissed for one clip — the O(rows-for-clip) lookup the suggestion
    /// loop needs before offering a tag.
    func dismissedUserTags(forClip clipID: UUID) -> Set<String> {
        Set(dismissalRows(forClip: clipID).map(\.tag))
    }

    /// Record a dismissal. Fail CLOSED: if the tag can't be sealed we refuse to
    /// persist it rather than let a plaintext label reach disk.
    @discardableResult
    func addUserTagDismissal(tag: String, clipID: UUID) -> Bool {
        guard let normalized = ClipItem.normalizedUserTags([tag]).first else { return false }
        // Sealing is nondeterministic (fresh AES-GCM nonce per call), so the
        // composite primary key can't dedupe for us — check first.
        if dismissedUserTags(forClip: clipID).contains(normalized) { return true }
        guard let sealed = Crypto.sealStrict(normalized) else {
            NSLog("Cliphoard db: dismissal seal failed — refusing insert"); return false
        }
        var ok = false
        prepare("INSERT OR REPLACE INTO user_tag_dismissals (tag, clip_id) VALUES (?,?);") { stmt in
            bindText(stmt, 1, sealed)
            bindText(stmt, 2, clipID.uuidString)
            ok = step(stmt)
        }
        return ok
    }

    /// Undo a dismissal (the tag becomes suggestable again for that clip).
    @discardableResult
    func removeUserTagDismissal(tag: String, clipID: UUID) -> Bool {
        guard let normalized = ClipItem.normalizedUserTags([tag]).first else { return false }
        let victims = dismissalRows(forClip: clipID).filter { $0.tag == normalized }.map(\.rowID)
        guard !victims.isEmpty else { return true }   // already absent
        var ok = true
        for rowID in victims {
            prepare("DELETE FROM user_tag_dismissals WHERE rowid=?;") { stmt in
                sqlite3_bind_int64(stmt, 1, rowID)
                ok = step(stmt) && ok
            }
        }
        return ok
    }

    /// rowid + decrypted tag for one clip's dismissal rows.
    private func dismissalRows(forClip clipID: UUID) -> [(rowID: Int64, tag: String)] {
        var rows: [(Int64, String)] = []
        prepare("SELECT rowid, tag FROM user_tag_dismissals WHERE clip_id=?;") { stmt in
            bindText(stmt, 1, clipID.uuidString)
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let tag = ClipItem.normalizedUserTags([Crypto.open(column(stmt, 1))]).first
                else { continue }
                rows.append((sqlite3_column_int64(stmt, 0), tag))
            }
        }
        return rows
    }

    @discardableResult
    func upsertEmbedding(clipID: UUID, model: String, embedding: ModelEmbedding) -> Bool {
        // Fail CLOSED: the vector and tags are content-derived, so never persist
        // them unsealed. If sealing fails, skip this embedding — the clip itself is
        // already stored sealed by `insert`, and degraded search beats a leak.
        guard let encVec = Crypto.sealStrict(Self.blob(fromVector: embedding.vector)),
              let encTags = Crypto.sealStrict(embedding.tags.map(String.init).joined(separator: ",")) else {
            NSLog("Cliphoard db: embedding seal failed — skipping upsert")
            return false
        }
        var ok = false
        prepare("INSERT OR REPLACE INTO embeddings (clip_id, model, vector, tags) VALUES (?,?,?,?);") { stmt in
            bindText(stmt, 1, clipID.uuidString)
            bindText(stmt, 2, model)
            bindBlob(stmt, 3, encVec)
            bindText(stmt, 4, encTags)
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
        // No FK cascade on dismissals (see the table definition) — prune here.
        prepare("DELETE FROM user_tag_dismissals WHERE clip_id=?;") { stmt in
            bindText(stmt, 1, id.uuidString); _ = step(stmt)
        }
        return ok
    }

    func deleteUnpinned() {
        exec("DELETE FROM clips WHERE pinned=0;")
        exec("DELETE FROM user_tag_dismissals WHERE clip_id NOT IN (SELECT id FROM clips);")
    }

    /// Rewrite the database file, purging free pages. Used after the encryption
    /// migration so stale plaintext can't linger in the file at rest.
    func vacuum() { exec("VACUUM;") }

    func delete(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        transaction { for id in ids { delete(id: id) } }
    }

    func transaction(_ body: () -> Void) {
        exec("BEGIN;")
        txnFailed = false
        body()
        exec(txnFailed ? "ROLLBACK;" : "COMMIT;")
    }

    // MARK: Low-level helpers

    private func exec(_ sql: String) {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            NSLog("Cliphoard db exec error: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func prepare(_ sql: String, _ body: (OpaquePointer?) -> Void) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK { body(stmt) }
        else { NSLog("Cliphoard db prepare error: \(String(cString: sqlite3_errmsg(db)))") }
    }

    /// Run a write statement to completion, logging the SQLite error on failure.
    /// Returns true only when the step reaches SQLITE_DONE.
    private func step(_ stmt: OpaquePointer?) -> Bool {
        if sqlite3_step(stmt) == SQLITE_DONE { return true }
        NSLog("Cliphoard db step error: \(String(cString: sqlite3_errmsg(db)))")
        txnFailed = true   // any failed write aborts the enclosing transaction
        return false
    }

    private func prepareEach(_ sql: String, _ row: (OpaquePointer?) -> Void) {
        prepare(sql) { stmt in while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) } }
    }

    private func ensureColumn(_ name: String, definition: String, in table: String) {
        var exists = false
        prepareEach("PRAGMA table_info(\(table));") { stmt in
            if column(stmt, 1) == name { exists = true }
        }
        if !exists { exec("ALTER TABLE \(table) ADD COLUMN \(name) \(definition);") }
    }

    private func bindText(_ stmt: OpaquePointer?, _ i: Int32, _ s: String?) {
        if let s { sqlite3_bind_text(stmt, i, s, -1, Self.transient) } else { sqlite3_bind_null(stmt, i) }
    }

    private func bindBlob(_ stmt: OpaquePointer?, _ i: Int32, _ d: Data?) {
        guard let d, !d.isEmpty else { sqlite3_bind_null(stmt, i); return }
        _ = d.withUnsafeBytes { sqlite3_bind_blob(stmt, i, $0.baseAddress, Int32(d.count), Self.transient) }
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

    /// [Float] → Float32 BLOB (4 bytes/value). Float32, NOT Float16: `Float16` is
    /// unavailable on x86_64 macOS, so using it prevents a universal (Apple Silicon +
    /// Intel) build. Old Float16 blobs from earlier versions read back as a
    /// wrong-length vector and are transparently re-indexed by `ClipIndexer.isStale`,
    /// so no explicit migration is needed. (Embedding storage isn't shipped — the DMG
    /// carries an empty database — so the extra 2 bytes/value cost nothing to download.)
    static func blob(fromVector v: [Float]) -> Data {
        v.withUnsafeBytes { Data($0) }
    }

    /// Float32 BLOB → [Float]. Accepts already-decrypted `Data` so callers can
    /// `Crypto.open` the column before parsing.
    static func vectorFromBlob(_ data: Data?) -> [Float] {
        guard let data else { return [] }
        let stride = MemoryLayout<Float>.stride
        guard data.count % stride == 0 else {   // malformed blob → treat as no vector
            NSLog("Cliphoard db: embedding blob length \(data.count) not a multiple of \(stride)")
            return []
        }
        let count = data.count / stride
        // loadUnaligned: a Data buffer is not guaranteed 4-byte aligned, so a
        // bound Float pointer would be undefined behavior.
        return data.withUnsafeBytes { raw in
            (0..<count).map { raw.loadUnaligned(fromByteOffset: $0 * stride, as: Float.self) }
        }
    }

    static func tags(fromText s: String) -> [Int] {
        s.isEmpty ? [] : s.split(separator: ",").compactMap { Int($0) }
    }

    static func userTags(fromText s: String) -> [String] {
        ClipItem.normalizedUserTags(s.split(separator: "\n").map(String.init))
    }
}
