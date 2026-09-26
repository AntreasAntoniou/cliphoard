import Foundation
import AppKit
import CryptoKit
import SQLite3

/// Import four years of clipboard history out of Paste (Setapp) and into Cliphoard.
///
/// Run from INSIDE the installed bundle, never from `.build`:
///
///     /Applications/Cliphoard.app/Contents/MacOS/Cliphoard \
///         --import-paste ~/exports-2026-06-26/paste-export/com.wiheads.paste-setapp/db.sqlite \
///         [--dry-run] [--limit N] [--since YYYY-MM-DD]
///
/// The bundle path matters and is not a style preference: keychain access is keyed to CODE
/// IDENTITY, so a binary run straight out of `.build` is a different principal, cannot reach
/// the same keys, and would either prompt endlessly or seal the imported clips under a key
/// the app cannot read — writing 7,846 permanently-unreadable rows. This session already
/// spent a night recovering from exactly that failure mode.
///
/// WHAT PASTE STORES, established by reading the export rather than by documentation:
/// `ZITEMENTITY.ZRAWPREVIEW` is plain UTF-8 JSON — no unarchiving, no decompression. The
/// separate `ZITEMDATAENTITY.ZRAWPASTEBOARDITEMS` blob IS opaque (a `01` version byte then
/// an unidentified encoding) and is deliberately NOT read: everything needed is in the
/// preview, so the opaque blob is a problem we can decline to have.
///
///     type 5   {"text":"…","type":"text"}              -> .text  (or .link/.color by shape)
///     type 4   {"url":"…","type":"link"}               -> .link
///     type 1   {"imageData":"<base64>",…}              -> .image
///     type 3   {"type":"files","filePaths":[…]}        -> .file
///     type 2   {"colorCode":N,"type":"color"}          -> .color
///
/// REVERSIBILITY IS BUILT IN. Every imported clip carries the user tag `paste-import`, so
/// the entire batch is one query to find and one action to remove. Importing 45x the store's
/// existing contents without a way to undo it would be the kind of irreversible act that
/// deserves a confirmation prompt; a marker is better than a prompt.
enum PasteImport {

    /// Apple's reference date. Paste stores Core Data timestamps, Cliphoard stores the same,
    /// so the conversion is identity — but it is written out rather than assumed, because a
    /// silent 31-year offset would put every imported clip in 1995 and still "work".
    private static let appleEpoch = Date(timeIntervalSince1970: 978_307_200)

    static let marker = "paste-import"

    struct Row {
        let created: Date
        let rawType: Int
        let preview: Data
        let sourceApp: String?
    }

    struct Tally {
        var byKind: [String: Int] = [:]
        var skippedNoPreview = 0
        var skippedUnparsable = 0
        var skippedEmpty = 0
        var skippedDuplicate = 0
        var imageBytes = 0
        var imported = 0
        /// Clips the stored history limit left in the source. An upper bound, counted before
        /// dedup; the source is only ever read, so this is a deferral, not a loss.
        var leftInSource = 0
    }

    @MainActor @discardableResult
    static func run(dbPath: String, store: ClipStore, dryRun: Bool,
                    limit: Int?, since: Date?) -> Tally {
        func say(_ s: String) { print(s); DebugLog.write("paste-import: \(s)") }

        say("source: \(dbPath)")
        say(dryRun ? "MODE: DRY RUN — nothing will be written" : "MODE: LIVE")

        guard !store.safeMode else {
            say("REFUSING: the store is in SAFE MODE. Importing would either fail to persist "
                + "or write rows under a key that cannot be read back. Fix the keychain first.")
            return Tally()
        }

        let rows = read(dbPath: dbPath, limit: limit, since: since, log: say)
        guard !rows.isEmpty else { say("no rows read — nothing to do"); return Tally() }
        say("read \(rows.count) rows")

        var tally = Tally()
        // ONE writer. `ClipImporters.write` owns dedup (by signature, so a re-run is
        // idempotent) and the fit rule: the newest clips that fit under the stored history
        // limit land, the rest stay in the export, which is only ever read. This used to call
        // `store.add` per row, and `add` → `trim()` evicted the user's own OLDEST clips past
        // the limit and unlinked their payloads — under "imported 20".
        let staged = stage(rows: rows, tally: &tally)
        ClipImporters.write(staged, marker: marker, store: store, dryRun: dryRun, tally: &tally)

        say("---")
        for (kind, n) in tally.byKind.sorted(by: { $0.value > $1.value }) {
            say(String(format: "  %-8s %6d", (kind as NSString).utf8String!, n))
        }
        say("  image payload bytes: \(tally.imageBytes / 1_000_000) MB")
        say("  skipped: no preview \(tally.skippedNoPreview), unparsable "
            + "\(tally.skippedUnparsable), empty \(tally.skippedEmpty), "
            + "duplicate \(tally.skippedDuplicate)")
        if tally.leftInSource > 0 {
            say("  up to \(tally.leftInSource) older clip(s) stay in Paste: the history limit "
                + "is \(store.historyLimit). Set it to 0 (Unlimited) and re-run.")
        }
        say(dryRun ? "DRY RUN — \(tally.imported) clips WOULD be imported"
                   : "imported \(tally.imported) clips, each tagged '\(marker)'")
        if !dryRun {
            say("to undo: search the tag '\(marker)' and delete, or "
                + "DELETE FROM clips WHERE id IN (…) — the tag is the handle")
        }
        return tally
    }

    /// Paste as a `ClipImporters` adapter. Same signature the catalogue references.
    @MainActor
    static func stage(path: String, tally: inout Tally) -> [ClipImporters.Staged] {
        stage(rows: read(dbPath: path, limit: nil, since: nil, log: { _ in }), tally: &tally)
    }

    /// Rows → `Staged`. Shared by `run` (which reads with --limit/--since and logs) and the
    /// adapter above (which reads everything and logs nothing); the verified parser exists once.
    @MainActor
    static func stage(rows: [Row], tally: inout Tally) -> [ClipImporters.Staged] {
        var out: [ClipImporters.Staged] = []
        for row in rows {
            guard let json = decodePreview(row.preview) else { tally.skippedUnparsable += 1; continue }
            var staged = ClipImporters.Staged(kind: .text, text: "", created: row.created,
                                              sourceApp: row.sourceApp, filePath: nil,
                                              colorHex: nil, imageData: nil)
            switch json["type"] as? String {
            case "text":
                guard let t = json["text"] as? String,
                      !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    tally.skippedEmpty += 1; continue
                }
                staged.kind = ClipboardMonitor.detectKind(for: t); staged.text = t
                if staged.kind == .color { staged.colorHex = t.trimmingCharacters(in: .whitespaces) }
            case "link":
                guard let u = json["url"] as? String, !u.isEmpty else { tally.skippedEmpty += 1; continue }
                staged.kind = .link; staged.text = u
            case "color":
                guard let c = json["colorCode"] as? Int else { tally.skippedEmpty += 1; continue }
                let hex = String(format: "#%06X", c & 0xFFFFFF)
                staged.kind = .color; staged.text = hex; staged.colorHex = hex
            case "files":
                guard let ps = json["filePaths"] as? [String], let f = ps.first else {
                    tally.skippedEmpty += 1; continue
                }
                staged.kind = .file; staged.text = f; staged.filePath = f
            default:
                guard let b64 = json["imageData"] as? String,
                      let raw = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else {
                    tally.skippedNoPreview += 1; continue
                }
                staged.kind = .image; staged.text = "Image"; staged.imageData = raw
            }
            out.append(staged)
        }
        return out
    }

    // MARK: - Source

    private static func read(dbPath: String, limit: Int?, since: Date?,
                             log: (String) -> Void) -> [Row] {
        // Through the shared WAL-honouring open. This used to hardcode `immutable=1` with a
        // comment arguing it was correct "precisely because the export is frozen" — true of
        // the export, and false of the other path this very adapter advertises: the
        // catalogue also points at a LIVE Paste install, whose recent clips live in a -wal
        // that immutable mode ignores. The argument was sound about one input and was
        // applied to both.
        var db: OpaquePointer?
        guard ClipImporters.openReadOnly(dbPath, &db) else {
            log("cannot open \(dbPath)")
            return []
        }
        defer { sqlite3_close(db) }

        var sql = """
        SELECT i.ZCREATEDAT, i.ZRAWTYPE, i.ZRAWPREVIEW, a.ZNAME
        FROM ZITEMENTITY i
        LEFT JOIN ZAPPLICATIONENTITY a ON a.Z_PK = i.ZSOURCEAPPLICATION
        WHERE i.ZRAWPREVIEW IS NOT NULL
        """
        if let since { sql += " AND i.ZCREATEDAT >= \(since.timeIntervalSince(appleEpoch))" }
        sql += " ORDER BY i.ZCREATEDAT ASC"
        if let limit { sql += " LIMIT \(limit)" }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            log("query failed: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var out: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let created = appleEpoch.addingTimeInterval(sqlite3_column_double(stmt, 0))
            let rawType = Int(sqlite3_column_int(stmt, 1))
            guard let bytes = sqlite3_column_blob(stmt, 2) else { continue }
            let n = Int(sqlite3_column_bytes(stmt, 2))
            let preview = Data(bytes: bytes, count: n)
            let app = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            out.append(Row(created: created, rawType: rawType, preview: preview, sourceApp: app))
        }
        return out
    }

    // MARK: - Mapping

    /// JSON or binary plist, whichever this row happens to be.
    ///
    /// `bplist00` is checked by MAGIC rather than by attempting plist first, because
    /// `PropertyListSerialization` will happily accept some JSON-shaped input and return a
    /// structure that is subtly not what the JSON path would produce. Cheap explicit check,
    /// then the expensive parse.
    private static func decodePreview(_ data: Data) -> [String: Any]? {
        if data.starts(with: Array("bplist00".utf8)) {
            return (try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil)) as? [String: Any]
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }
        // A JSON row that failed to parse might still be a plist in a format we did not
        // recognise by magic. Try anyway rather than losing the row on a guess.
        return (try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil)) as? [String: Any]
    }

    /// Re-encodes to PNG and seals it, going through the SAME shape as `persistImage` so an
    /// imported image is byte-identical in treatment to a copied one: hash the PLAINTEXT
    /// png, name the file by that hash, then seal. Dedup therefore works across the import
    /// boundary — an image copied twice over four years lands once.
    @MainActor
    static func imageItem(from raw: Data, into directory: URL,
                                  tally: inout Tally) -> ClipItem? {
        guard let image = NSImage(data: raw),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            tally.skippedUnparsable += 1
            return nil
        }
        let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let name = "\(hash).png"
        let url = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard let sealed = Crypto.seal(png), Crypto.isSealed(sealed) else {
                tally.skippedUnparsable += 1
                return nil
            }
            do { try sealed.write(to: url, options: .atomic) }
            catch { tally.skippedUnparsable += 1; return nil }
        }
        tally.imageBytes += png.count
        let item = ClipItem(kind: .image,
                            text: "Image \(Int(image.size.width))×\(Int(image.size.height))")
        item.payloadFile = name
        item.imageHash = hash
        return item
    }
}
