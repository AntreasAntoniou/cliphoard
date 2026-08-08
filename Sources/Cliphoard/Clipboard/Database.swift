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
            user_tags TEXT, flags INTEGER, shape TEXT);
        """)
        ensureColumn("user_tags", definition: "TEXT", in: "clips")
        // Tier-1 detector verdict (design §5). Both columns are additive and
        // guarded exactly like `user_tags`, so an older database gains them on
        // open with its rows intact (they read back as flags=[] / shape=nil).
        //
        // Deliberately NOT encrypted, unlike the content columns: `flags` is a
        // small non-content integer that filtering reads on every render, and
        // `shape` is a short enum-like token from a fixed vocabulary. Neither
        // carries clipboard content, and sealing them would cost a decrypt per
        // row per query for no confidentiality gain.
        ensureColumn("flags", definition: "INTEGER", in: "clips")
        ensureColumn("shape", definition: "TEXT", in: "clips")
        // Recognised image text. Additive and guarded like the pair above, so an older
        // database gains it on open with rows intact — they read back as ocrText == nil,
        // "never analysed", which is what makes the background pass find them.
        //
        // UNLIKE flags/shape, this one IS sealed. Those two are deliberately clear
        // because they are small non-content tokens read on every render. This is
        // verbatim clipboard content, reconstructed from pixels — the same category as
        // `text`, and it gets the same treatment: sealStrict, fail closed.
        ensureColumn("ocr_text", definition: "TEXT", in: "clips")
        // Vision perceptual prints. A SEPARATE table, not a reserved signature inside
        // `embeddings`: that dictionary is documented as "per-model cache: embedder
        // signature → embedding", and a Vision print is not a text-model embedding of
        // anything. Filing it there would make an existing doc comment false, and a
        // false invariant is the failure family this codebase keeps writing tests against.
        //
        // WITH the cascade, matching `embeddings` and unlike `user_tag_dismissals`. That
        // neighbour omits its foreign key deliberately, because `insert` is INSERT OR
        // REPLACE and would cascade-delete its rows on every re-save — but dismissals are
        // AUTHORED data, gone forever if dropped. A print is DERIVED: one Vision call
        // rebuilds it. So the two should fail in opposite directions. No-cascade fails
        // toward RETENTION, leaving the perceptual fingerprint of a DELETED screenshot on
        // disk, which on a privacy-first product is the wrong way to fail. Cascade fails
        // toward loss and costs a recompute. `insert` therefore write-throughs the print
        // from memory, exactly as it already does for every vector.
        //
        // `revision` is stored because Vision's print revisions are not comparable:
        // revision 1 emits 2048 floats, revision 2 emits 768. A future revision selects
        // `WHERE revision != n` and recomputes, rather than silently comparing across
        // spaces.
        exec("""
        CREATE TABLE IF NOT EXISTS image_features (
            clip_id TEXT NOT NULL PRIMARY KEY,
            revision INTEGER NOT NULL,
            vector BLOB NOT NULL,
            FOREIGN KEY (clip_id) REFERENCES clips(id) ON DELETE CASCADE);
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS embeddings (
            clip_id TEXT NOT NULL, model TEXT NOT NULL,
            vector BLOB NOT NULL,
            PRIMARY KEY (clip_id, model),
            FOREIGN KEY (clip_id) REFERENCES clips(id) ON DELETE CASCADE);
        """)
        dropTagIDColumnIfPresent()
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

    /// What a COUNT actually reported.
    ///
    /// `clipCount() -> Int` returned `0` for "the table is empty", for "the statement
    /// would not prepare", and for "the step failed". Those are the same two meanings
    /// whose conflation cost 210 clips one layer down — "I could not read" spent as
    /// "there is nothing there" — and the guard written to catch it,
    /// `items.count == db.clipCount()`, is SATISFIED by `0 == 0` in exactly the
    /// total-failure case.
    ///
    /// That is not a hypothetical. Probed: a `ditto.sqlite` of garbage bytes opens
    /// fine (`sqlite3_open_v2` defers header validation), so `Database.init?` returns a
    /// live handle; `CREATE TABLE` then fails with rc 26 so the table never exists;
    /// the COUNT fails to prepare and reported `0`; the loader returns `[]`. The guard
    /// passed and stamped one-shot migration markers for work never done.
    enum CountRead: Equatable {
        /// A statement ran and produced this number — including `0`. A zero here is a
        /// REPORTED zero, which is the entire point of the type.
        case counted(Int)
        /// Prepare or step failed. The count is UNKNOWN. It is not zero.
        case unavailable(Int32)
    }

    /// The number of stored clips, or why it could not be taken.
    func clipCountStatus() -> CountRead {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM clips;", -1, &stmt, nil)
        guard rc == SQLITE_OK else {
            NSLog("Cliphoard db: clip count unavailable: \(String(cString: sqlite3_errmsg(db)))")
            return .unavailable(rc)
        }
        let step = sqlite3_step(stmt)
        guard step == SQLITE_ROW else {
            NSLog("Cliphoard db: clip count returned no row: \(String(cString: sqlite3_errmsg(db)))")
            return .unavailable(step)
        }
        return .counted(Int(sqlite3_column_int(stmt, 0)))
    }

    /// What a history read actually found.
    ///
    /// Mirrors `Crypto.BlobRead` deliberately and for the same reason: the only value
    /// that may be treated as "this is the whole history" is one that can prove it.
    /// That shape is the single fix in this codebase that has held under fourteen
    /// consecutive rounds of adversarial review, while every positional guard has been
    /// breached at least once.
    enum HistoryRead {
        /// Every row the database holds was materialised. The array may be empty — but
        /// that emptiness was REPORTED by statements that ran, not manufactured by a
        /// failure.
        case complete([ClipItem], CompleteHistory)
        /// No handle, a count that would not run, a scan that stopped early, or fewer
        /// rows loaded than stored. The history is not empty; it is UNKNOWN.
        case unavailable(Reason)

        enum Reason: Equatable {
            case noDatabase
            case countUnavailable(Int32)
            case clipScanStoppedEarly(Int32)
            case embeddingScanStoppedEarly(Int32)
            case featureScanStoppedEarly(Int32)
            /// Rows were skipped without erroring — today, a row whose id is not a
            /// UUID (see the `guard let id` in the clips scan). The clip vanishes from
            /// `items` with no signal, and its payload PNG then looks unreferenced.
            case short(loaded: Int, stored: Int)
        }

        var isComplete: Bool { if case .complete = self { return true }; return false }
    }

    /// Proof that a load saw EVERY row the database holds.
    ///
    /// It exists to be a parameter. Every pass that permanently destroys stored bytes
    /// takes one, and `init` is `fileprivate` to this file, so the only way to obtain
    /// the value is a load that actually proved completeness. That is the difference
    /// between this and the guard it replaces: a guard is invisible to the next call
    /// site somebody writes, and a required argument of a type they cannot construct
    /// is the first thing the compiler asks them about.
    ///
    /// Deliberately holds FLAT IMMUTABLE FACTS rather than `[ClipItem]`. `ClipItem` is
    /// a class, so a token carrying references would prove the set was complete and
    /// nothing whatever about the objects in it — and the reapers have no business
    /// touching a live item anyway.
    struct CompleteHistory {
        /// Every `payloadFile` referenced by a live clip.
        let referencedPayloads: Set<String>
        /// Image clips only, id → payload file name.
        let imagePayloadsByClip: [UUID: String]
        /// What the database itself reported, which `loadAll` matched exactly.
        let storedCount: Int

        fileprivate init(referencedPayloads: Set<String>,
                         imagePayloadsByClip: [UUID: String],
                         storedCount: Int) {
            self.referencedPayloads = referencedPayloads
            self.imagePayloadsByClip = imagePayloadsByClip
            self.storedCount = storedCount
        }
    }

    /// Load every clip with its embeddings, newest/pinned first.
    ///
    /// DISCARDS the completeness signal, so the result MAY BE SHORT and must never
    /// feed a deletion. Callers that delete take a `CompleteHistory` instead, which
    /// only `loadAllStatus` can mint. Kept for diagnostics, the audit tool and tests.
    func loadAll() -> [ClipItem] {
        if case .complete(let rows, _) = loadAllStatus() { return rows }
        return loadAllUnchecked().rows
    }

    /// `loadAll`, plus whether it read the whole thing.
    ///
    /// One `BEGIN DEFERRED` snapshot around the count and all three scans: in WAL mode
    /// that pins a consistent view, so a second process writing between the count and
    /// the scan cannot manufacture a `.short` and freeze this one for nothing.
    ///
    /// Must not be called from inside an open transaction — nesting `BEGIN` is an
    /// error. Today the only callers are `ClipStore.init` and the audit tool, neither
    /// of which holds one.
    func loadAllStatus() -> HistoryRead {
        exec("BEGIN DEFERRED;")
        defer { exec("COMMIT;") }

        guard case .counted(let stored) = clipCountStatus() else {
            if case .unavailable(let rc) = clipCountStatus() {
                return .unavailable(.countUnavailable(rc))
            }
            return .unavailable(.countUnavailable(SQLITE_ERROR))
        }
        let read = loadAllUnchecked()
        guard read.featureRC == SQLITE_DONE else {
            return .unavailable(.featureScanStoppedEarly(read.featureRC))
        }
        guard read.embeddingRC == SQLITE_DONE else {
            return .unavailable(.embeddingScanStoppedEarly(read.embeddingRC))
        }
        guard read.clipRC == SQLITE_DONE else {
            return .unavailable(.clipScanStoppedEarly(read.clipRC))
        }
        // A row that EXISTS and could not be materialised is a SHORT read, not a
        // smaller history. Today the only route is a non-UUID id, which the scan skips
        // silently — and that clip's PNG then looks unreferenced to the sweep.
        guard read.rows.count == stored else {
            return .unavailable(.short(loaded: read.rows.count, stored: stored))
        }
        var imagePayloads: [UUID: String] = [:]
        for item in read.rows where item.kind == .image {
            if let f = item.payloadFile { imagePayloads[item.id] = f }
        }
        return .complete(read.rows, CompleteHistory(
            referencedPayloads: Set(read.rows.compactMap { $0.payloadFile }),
            imagePayloadsByClip: imagePayloads,
            storedCount: stored))
    }

    /// The scans themselves, reporting each one's terminal sqlite result.
    private func loadAllUnchecked()
        -> (rows: [ClipItem], clipRC: Int32, embeddingRC: Int32, featureRC: Int32) {
        // 0. Vision prints, one query rather than one per clip.
        let features = loadImageFeaturesChecked()
        let featuresByClip = features.features
        // 1. Embeddings grouped by clip id.
        var embByClip: [String: [String: ModelEmbedding]] = [:]
        let embeddingRC = prepareEach("SELECT clip_id, model, vector FROM embeddings;") { stmt in
            let clipID = column(stmt, 0)
            let model = column(stmt, 1)
            // Decrypt at-rest embedding columns (legacy plaintext passes through).
            let vec = Self.vectorFromBlob(Crypto.open(Self.blob(stmt, 2)))
            embByClip[clipID, default: [:]][model] = ModelEmbedding(vector: vec)
        }
        // 2. Clips.
        var result: [ClipItem] = []
        let clipRC = prepareEach("""
            SELECT id, kind, text, rtf, payload_file, file_path, color_hex,
                   created_at, last_used_at, pinned, source_app, use_count, user_tags,
                   flags, shape, ocr_text
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
                userTags: Self.userTags(fromText: columnOpt(stmt, 12).map(Crypto.open) ?? ""),
                // The FULL stored integer, never masked to the bits this build
                // knows: a flag written by a newer version must survive a
                // load → save round-trip through an older one untouched.
                flags: ClipFlags(rawValue: columnIntOpt(stmt, 13) ?? 0),
                shape: columnOpt(stmt, 14),
                // `columnOpt` returns nil ONLY for SQL NULL, and sealing "" produces
                // non-empty ciphertext that opens back to "". So NULL ("never
                // analysed") and "" ("analysed, nothing to index") survive the round
                // trip as distinct states — which is what lets the column be its own
                // progress marker with no separate flag.
                ocrText: columnOpt(stmt, 15).map(Crypto.open))
            item.embeddings = embByClip[idStr] ?? [:]
            item.imageFeature = featuresByClip[idStr]
            result.append(item)
        }
        return (result, clipRC, embeddingRC, features.rc)
    }

    // MARK: Writes

    @discardableResult
    func insert(_ item: ClipItem) -> Bool {
        let sql = """
            INSERT OR REPLACE INTO clips
            (id, kind, text, rtf, payload_file, file_path, color_hex,
             created_at, last_used_at, pinned, source_app, use_count, user_tags,
             flags, shape, ocr_text)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
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
        // MUST be bound, not merely added to the schema. This statement is INSERT OR
        // REPLACE, so it deletes and reinserts the row — and both `reKeyToSecureEnclave`
        // and `encryptExistingRows` drive it across every clip. An unbound column would
        // silently blank every recognised text on the next re-key, with no error.
        // `nil` stays NULL ("never analysed"); "" seals to real ciphertext that opens
        // back to "" ("analysed, withheld or empty"), preserving the distinction.
        var encOCR: String? = nil
        if let ocr = item.ocrText {
            guard let s = Crypto.sealStrict(ocr) else {
                NSLog("Cliphoard db: content seal failed — refusing insert (ocr)"); return false
            }
            encOCR = s
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
            // Written verbatim (see `loadAll`): the whole raw value goes back to
            // disk, including any bit this build has no name for.
            sqlite3_bind_int64(stmt, 14, Int64(item.flags.rawValue))
            bindText(stmt, 15, item.shape)
            bindText(stmt, 16, encOCR)
            ok = step(stmt)
        }
        for (model, emb) in item.embeddings { upsertEmbedding(clipID: item.id, model: model, embedding: emb) }
        // Write-through, for the same reason as the loop above: this statement is
        // INSERT OR REPLACE, so it deletes and reinserts the clip row, and the cascade
        // takes both child tables with it. The vector loop is the ONLY reason embeddings
        // survive a re-key today; the print needs the same treatment or it would vanish
        // on every re-save with no error.
        if let fp = item.imageFeature, !fp.vector.isEmpty {
            upsertImageFeature(clipID: item.id, revision: fp.revision, vector: fp.vector)
        }
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
        // `_ =` on purpose: a short read here loses a dismissed SUGGESTION, so the
        // suggestion reappears. Nothing is deleted on the strength of this scan.
        _ = prepareEach("SELECT tag, clip_id FROM user_tag_dismissals;") { stmt in
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

    /// Drop every stored vector for a clip.
    ///
    /// Needed by the §5 veto: a clip can BECOME vetoed after it was indexed (the
    /// sensitive-source denylist grows, a detector improves), and merely skipping
    /// it in later passes would leave the old vector on disk forever. Filtering
    /// prevents new leaks; only this removes the existing one.
    @discardableResult
    func deleteEmbeddings(clipID: UUID) -> Bool {
        var ok = false
        prepare("DELETE FROM embeddings WHERE clip_id=?;") { stmt in
            bindText(stmt, 1, clipID.uuidString); ok = step(stmt)
        }
        return ok
    }

    /// Narrow write for an analysed clip: the sealed recognised text and the flags,
    /// together. Deliberately NOT `insert` — that is INSERT OR REPLACE, which deletes and
    /// reinserts the row and re-upserts every child — and NOT `updateMeta`, which does not
    /// write flags, and the flags are half the point of this write. Seals BEFORE touching
    /// SQLite so a crypto failure leaves the previous value intact.
    @discardableResult
    func updateOCR(_ item: ClipItem) -> Bool {
        var encOCR: String? = nil
        if let ocr = item.ocrText {
            guard let s = Crypto.sealStrict(ocr) else {
                NSLog("Cliphoard db: ocr seal failed — refusing update")
                return false
            }
            encOCR = s
        }
        var ok = false
        prepare("UPDATE clips SET ocr_text=?, flags=? WHERE id=?;") { stmt in
            bindText(stmt, 1, encOCR)
            sqlite3_bind_int64(stmt, 2, Int64(item.flags.rawValue))
            bindText(stmt, 3, item.id.uuidString)
            ok = step(stmt)
        }
        return ok
    }

    /// Sealed, fail-closed, exactly like `upsertEmbedding` — a perceptual print is
    /// content-derived, so it never reaches disk in the clear.
    @discardableResult
    func upsertImageFeature(clipID: UUID, revision: Int, vector: [Float]) -> Bool {
        guard !vector.isEmpty else { return false }
        guard let encVec = Crypto.sealStrict(Self.blob(fromVector: vector)) else {
            NSLog("Cliphoard db: image-feature seal failed — skipping upsert")
            return false
        }
        var ok = false
        prepare("INSERT OR REPLACE INTO image_features (clip_id, revision, vector) VALUES (?,?,?);") { stmt in
            bindText(stmt, 1, clipID.uuidString)
            sqlite3_bind_int(stmt, 2, Int32(revision))
            bindBlob(stmt, 3, encVec)
            ok = step(stmt)
        }
        return ok
    }

    /// Must be called wherever vectors are purged. A clip that becomes vetoed AFTER its
    /// print was stored would otherwise keep a perceptual fingerprint — and a fingerprint
    /// of a password-manager screenshot still confirms the user was looking at that exact
    /// screen, even though it is not readable text.
    @discardableResult
    func deleteImageFeature(clipID: UUID) -> Bool {
        var ok = false
        prepare("DELETE FROM image_features WHERE clip_id=?;") { stmt in
            bindText(stmt, 1, clipID.uuidString); ok = step(stmt)
        }
        return ok
    }

    /// Erase every recognised text and every perceptual print, then compact.
    ///
    /// The VACUUM is not housekeeping: this file's own standard is that content-derived
    /// bytes must not linger in free pages, and recognised text is content. Without it,
    /// "forget" would leave the words recoverable in unallocated space — a delete button
    /// that does not delete, which is worse than no button.
    ///
    /// Sets the column to NULL rather than "": NULL means "never analysed", so if the
    /// user later re-enables recognition the pass picks these up again. "" would mean
    /// "analysed, nothing there" and would make the erasure permanent in a way the user
    /// did not ask for.
    func forgetAllImageUnderstanding() {
        exec("UPDATE clips SET ocr_text=NULL;")
        exec("DELETE FROM image_features;")
        vacuum()
    }

    /// All stored prints, by clip. Read once at load, like the vector cache.
    func loadImageFeatures() -> [String: (revision: Int, vector: [Float])] {
        loadImageFeaturesChecked().features
    }

    /// `loadImageFeatures`, plus the scan's terminal result so a truncated read is
    /// reportable rather than silently smaller.
    private func loadImageFeaturesChecked()
        -> (features: [String: (revision: Int, vector: [Float])], rc: Int32) {
        var out: [String: (revision: Int, vector: [Float])] = [:]
        let rc = prepareEach("SELECT clip_id, revision, vector FROM image_features;") { stmt in
            let id = column(stmt, 0)
            let revision = Int(sqlite3_column_int(stmt, 1))
            guard let blob = Crypto.open(Self.blob(stmt, 2)) else { return }
            out[id] = (revision, Self.vectorFromBlob(blob))
        }
        return (out, rc)
    }

    @discardableResult
    func upsertEmbedding(clipID: UUID, model: String, embedding: ModelEmbedding) -> Bool {
        // Fail CLOSED: the vector is content-derived, so never persist it unsealed.
        // If sealing fails, skip this embedding — the clip itself is already stored
        // sealed by `insert`, and degraded search beats a leak.
        guard let encVec = Crypto.sealStrict(Self.blob(fromVector: embedding.vector)) else {
            NSLog("Cliphoard db: embedding seal failed — skipping upsert")
            return false
        }
        var ok = false
        prepare("INSERT OR REPLACE INTO embeddings (clip_id, model, vector) VALUES (?,?,?);") { stmt in
            bindText(stmt, 1, clipID.uuidString)
            bindText(stmt, 2, model)
            bindBlob(stmt, 3, encVec)
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

    /// Runs `body` in a transaction and reports whether it COMMITTED.
    ///
    /// The return value matters for one-shot passes (the detector backfill): a
    /// caller that marks itself "done" after a rolled-back transaction never runs
    /// again, so work that silently failed is never retried. Discardable, so
    /// existing fire-and-forget callers are unaffected.
    @discardableResult
    func transaction(_ body: () -> Void) -> Bool {
        exec("BEGIN;")
        txnFailed = false
        body()
        let committed = !txnFailed
        exec(committed ? "COMMIT;" : "ROLLBACK;")
        return committed
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

    /// Run a read statement over every row, returning the scan's TERMINAL result.
    ///
    /// `SQLITE_DONE` means the cursor genuinely reached the end. Any other value means
    /// the loop stopped early and the rows the caller accumulated are a PREFIX, not the
    /// answer — and a failed `prepare` never enters the loop at all, which is why the
    /// initial value is `SQLITE_ERROR` rather than `SQLITE_DONE`.
    ///
    /// Deliberately NOT `@discardableResult`. The defect this whole change exists to
    /// remove is that a short read is indistinguishable from a complete one; an
    /// attribute whose meaning is "you may ignore this", applied to the value that
    /// distinguishes them, is that defect with a nicer name. The three callers that
    /// genuinely do not care write `_ =`, which is a visible act — and none of them can
    /// feed a deletion: both PRAGMA probes fail safe on a short read, and the
    /// dismissals scan only ever loses a suggestion.
    private func prepareEach(_ sql: String, _ row: (OpaquePointer?) -> Void) -> Int32 {
        var terminal: Int32 = SQLITE_ERROR
        prepare(sql) { stmt in
            var rc = sqlite3_step(stmt)
            while rc == SQLITE_ROW { row(stmt); rc = sqlite3_step(stmt) }
            if rc != SQLITE_DONE {
                NSLog("Cliphoard db: row scan stopped early (rc \(rc)): "
                      + "\(String(cString: sqlite3_errmsg(db)))")
            }
            terminal = rc
        }
        return terminal
    }

    /// One-way retirement of `embeddings.tags`.
    ///
    /// Tag ids are a pure function of (vector, embedder, basket, τ, topK) and are now
    /// DERIVED at the point of use. A stored copy is a second, independently mutable
    /// answer to a question the vector already answers — and the marker that claimed
    /// it was current stamped itself without writing anything: the migration filtered
    /// its targets by the ACTIVE embedder signature while every row on disk belonged
    /// to a different one, so it hit its empty-targets early return, stamped, and
    /// persisted nothing. The column is the substrate of that lie, so it goes.
    ///
    /// BLANK-then-drop, not drop alone: on a SQLite older than 3.35 the DROP is
    /// refused, and the stale ids must be gone regardless. Fail-safe, not fail-open.
    /// VACUUM afterwards because the ids were content-derived and sealed, and this
    /// file's own standard (see `upsertEmbedding`, and the encryption migration in
    /// ClipStore) is that content-derived bytes must not linger in free pages.
    ///
    /// PROBED rather than attempted-and-logged: a DROP that errors on every launch
    /// writes "no such column" to the log forever, which trains readers to ignore the
    /// log — the same failure family as the marker this replaces.
    private func dropTagIDColumnIfPresent() {
        var exists = false
        // `_ =` on purpose: a short PRAGMA read leaves `exists` false, so the DROP is
        // skipped and retried next launch. Fails safe by construction.
        _ = prepareEach("PRAGMA table_info(embeddings);") { stmt in
            if column(stmt, 1) == "tags" { exists = true }
        }
        guard exists else { return }
        exec("UPDATE embeddings SET tags='';")
        exec("ALTER TABLE embeddings DROP COLUMN tags;")
        exec("VACUUM;")
        // Clearing the marker is what keeps the revert shim honest. The shim restores
        // an EMPTY `tags` column, and the reverted `migrateTagVocabularyIfNeeded`
        // recomputes only when the marker disagrees with the active basket. Leave it
        // stamped and a revert yields a store where every clip has zero tags and
        // nothing ever notices — the same stamp-without-writing bug this change kills.
        UserDefaults.standard.removeObject(forKey: TagBasket.persistedVocabularyKey)
        NSLog("Cliphoard db: retired embeddings.tags — tag ids are now derived, never stored")
    }

    private func ensureColumn(_ name: String, definition: String, in table: String) {
        var exists = false
        // `_ =` on purpose: a short PRAGMA read leaves `exists` false, so the ALTER is
        // re-attempted and sqlite refuses a duplicate column. Fails safe, and loudly.
        _ = prepareEach("PRAGMA table_info(\(table));") { stmt in
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
/// A 64-bit integer column, or nil when the column is NULL (a row written before
/// the column existed). Read as int64 and widened without truncation so every
/// bit — including ones this build does not recognise — is preserved.
private func columnIntOpt(_ stmt: OpaquePointer?, _ i: Int32) -> Int? {
    guard sqlite3_column_type(stmt, i) != SQLITE_NULL else { return nil }
    return Int(truncatingIfNeeded: sqlite3_column_int64(stmt, i))
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


    static func userTags(fromText s: String) -> [String] {
        ClipItem.normalizedUserTags(s.split(separator: "\n").map(String.init))
    }
}
