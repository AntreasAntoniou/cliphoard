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
    }

    @MainActor
    static func run(dbPath: String, store: ClipStore, dryRun: Bool,
                    limit: Int?, since: Date?) {
        func say(_ s: String) { print(s); DebugLog.write("paste-import: \(s)") }

        say("source: \(dbPath)")
        say(dryRun ? "MODE: DRY RUN — nothing will be written" : "MODE: LIVE")

        guard !store.safeMode else {
            say("REFUSING: the store is in SAFE MODE. Importing would either fail to persist "
                + "or write rows under a key that cannot be read back. Fix the keychain first.")
            return
        }

        let rows = read(dbPath: dbPath, limit: limit, since: since, log: say)
        guard !rows.isEmpty else { return say("no rows read — nothing to do") }
        say("read \(rows.count) rows")

        var tally = Tally()
        // Signatures already present, so a re-run is idempotent rather than duplicating the
        // whole history. `store.add` dedups too, but counting here makes the report honest
        // about what was skipped rather than silently absorbing it.
        var seen = Set(store.items.map(\.signature))

        for row in rows {
            guard let item = clip(from: row, directory: store.storeDirectory,
                                  tally: &tally) else { continue }
            guard !seen.contains(item.signature) else { tally.skippedDuplicate += 1; continue }
            seen.insert(item.signature)

            item.createdAt = row.created
            item.lastUsedAt = row.created
            item.sourceApp = row.sourceApp
            item.userTags = [marker]

            tally.byKind[item.kind.rawValue, default: 0] += 1
            tally.imported += 1
            if !dryRun { store.add(item) }
        }

        say("---")
        for (kind, n) in tally.byKind.sorted(by: { $0.value > $1.value }) {
            say(String(format: "  %-8s %6d", (kind as NSString).utf8String!, n))
        }
        say("  image payload bytes: \(tally.imageBytes / 1_000_000) MB")
        say("  skipped: no preview \(tally.skippedNoPreview), unparsable "
            + "\(tally.skippedUnparsable), empty \(tally.skippedEmpty), "
            + "duplicate \(tally.skippedDuplicate)")
        say(dryRun ? "DRY RUN — \(tally.imported) clips WOULD be imported"
                   : "imported \(tally.imported) clips, each tagged '\(marker)'")
        if !dryRun {
            say("to undo: search the tag '\(marker)' and delete, or "
                + "DELETE FROM clips WHERE id IN (…) — the tag is the handle")
        }
    }

    /// Paste as a `ClipImporters` adapter. The mapping is shared with `run`; only the
    /// output shape differs, so the verified parser is not duplicated for the framework.
    @MainActor
    static func stage(path: String, tally: inout Tally) -> [ClipImporters.Staged] {
        var out: [ClipImporters.Staged] = []
        for row in read(dbPath: path, limit: nil, since: nil, log: { _ in }) {
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

    @MainActor
    private static func clip(from row: Row, directory: URL,
                             tally: inout Tally) -> ClipItem? {
        // TWO ENCODINGS, not one. Paste writes `ZRAWPREVIEW` as UTF-8 JSON for most rows
        // and as a BINARY PLIST for a minority — same keys, same schema, different
        // container. The first version of this importer assumed JSON and silently dropped
        // every plist row: 151 clips, including 2 images, counted as "unparsable" and never
        // investigated because the number looked like acceptable attrition.
        //
        // There is no way to tell which encoding a row uses except by trying, and no
        // documentation for either. Try JSON, fall back to plist, and only then give up.
        guard let json = decodePreview(row.preview) else {
            tally.skippedUnparsable += 1
            return nil
        }

        // Paste's own `type` string is trusted over ZRAWTYPE: the numeric column is
        // undocumented and the export's README calls it a hint, while the JSON names itself.
        switch json["type"] as? String {
        case "text":
            guard let text = json["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                tally.skippedEmpty += 1
                return nil
            }
            // Re-run Cliphoard's OWN kind detection rather than trusting Paste's coarse
            // "text": a URL or a hex colour copied years ago should land as .link or .color
            // here, exactly as it would if copied today. Consistency with the live capture
            // path matters more than fidelity to the source app's taxonomy.
            let kind = ClipboardMonitor.detectKind(for: text)
            let item = ClipItem(kind: kind, text: text)
            if kind == .color { item.colorHex = text.trimmingCharacters(in: .whitespaces) }
            return item

        case "link":
            guard let url = json["url"] as? String, !url.isEmpty else {
                tally.skippedEmpty += 1
                return nil
            }
            return ClipItem(kind: .link, text: url)

        case "color":
            // Paste stores a packed integer; render it the way Cliphoard stores colours so
            // the swatch and every colour-aware path work unchanged.
            guard let code = json["colorCode"] as? Int else { tally.skippedEmpty += 1; return nil }
            let hex = String(format: "#%06X", code & 0xFFFFFF)
            let item = ClipItem(kind: .color, text: hex)
            item.colorHex = hex
            return item

        case "files":
            guard let paths = json["filePaths"] as? [String], let first = paths.first else {
                tally.skippedEmpty += 1
                return nil
            }
            let item = ClipItem(kind: .file, text: first)
            item.filePath = first
            return item

        default:
            // Images arrive under several shapes; keyed on the payload rather than the label.
            if let b64 = json["imageData"] as? String,
               let raw = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) {
                return imageItem(from: raw, into: directory, tally: &tally)
            }
            tally.skippedNoPreview += 1
            return nil
        }
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
