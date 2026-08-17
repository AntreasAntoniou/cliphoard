import Foundation
import AppKit
import CryptoKit
import SQLite3

/// Importers for the macOS clipboard managers people actually migrate FROM.
///
/// HONESTY ABOUT VERIFICATION, because it is the most important thing in this file.
/// Exactly one of these adapters has been run against real data: Paste, over 7,775 rows.
/// The rest are written from each app's own source or published schema and have NEVER been
/// executed against a real store, because none of those apps is installed here. They are
/// marked `.unverified` and every unverified adapter DEFAULTS TO DRY RUN — you must pass
/// `--force` to make one write. An importer that silently fills someone's clipboard with
/// mis-parsed garbage is worse than no importer, and "it compiled" is not evidence.
///
/// The other half of the answer to "support the top ten" is `probe(path:)`. Nine adapters
/// I cannot test is not coverage; a tool that opens an unknown store and REPORTS its tables,
/// columns, row counts and likely content columns is, because it turns an unknown app into
/// a fifteen-minute adapter. That is how Paste itself was worked out.
enum ClipImporters {

    enum Confidence: String {
        /// Run against real data in this repo, row counts reconciled.
        case verified
        /// Schema taken from the app's own source code; never executed.
        case fromSource
        /// Schema from documentation or community reverse-engineering.
        case documented
        /// Known to exist, format not established — use `probe`.
        case unknown
    }

    struct Source {
        let id: String
        let name: String
        /// Where the store lives, `~` allowed. First existing path wins.
        let candidatePaths: [String]
        let confidence: Confidence
        let note: String
        /// nil for sources with no adapter yet; `probe` is the path forward.
        /// @MainActor: adapters call `ClipboardMonitor.detectKind` and build model
        /// objects, both of which are main-actor bound.
        let read: (@MainActor (String, inout PasteImport.Tally) -> [Staged])?
    }

    /// One clip, source-agnostic. Adapters produce these; a single writer consumes them, so
    /// sealing, dedup, detector veto and payload handling exist ONCE rather than per app.
    struct Staged {
        var kind: ClipKind
        var text: String
        var created: Date
        var sourceApp: String?
        var filePath: String?
        var colorHex: String?
        /// Decoded image bytes, if any. Sealed and written by the shared writer.
        var imageData: Data?
    }

    // MARK: - The catalogue

    /// The ten managers worth supporting, by how often people actually migrate from them.
    /// Ordering is a judgement call; the STATUS column is not.
    static let all: [Source] = [
        Source(id: "paste", name: "Paste (Setapp)",
               candidatePaths: ["~/Library/Application Support/com.wiheads.paste-setapp/db.sqlite",
                                "~/Library/Containers/com.wiheads.paste-setapp/Data/Library/Application Support/com.wiheads.paste-setapp/db.sqlite"],
               confidence: .verified,
               note: "Core Data. ZITEMENTITY.ZRAWPREVIEW is JSON *or* binary plist — both.",
               read: PasteImport.stage),

        Source(id: "maccy", name: "Maccy",
               candidatePaths: ["~/Library/Application Support/Maccy/Storage.sqlite"],
               confidence: .fromSource,
               note: "SwiftData. Storage.swift pins the path; HistoryItemContent is "
                   + "(type: UTI string, value: Data). Tables ZHISTORYITEM / ZHISTORYITEMCONTENT.",
               read: stageMaccy),

        Source(id: "alfred", name: "Alfred (Powerpack)",
               candidatePaths: ["~/Library/Application Support/Alfred/Databases/clipboard.alfdb"],
               confidence: .documented,
               note: "Plain sqlite, table `clipboard`, columns item/ts/app/apppath/dataType.",
               read: stageAlfred),

        Source(id: "flycut", name: "Flycut",
               candidatePaths: ["~/Library/Preferences/com.generalarcade.flycut.plist",
                                "~/Library/Containers/com.generalarcade.flycut/Data/Library/Preferences/com.generalarcade.flycut.plist"],
               confidence: .documented,
               note: "Preferences plist, `store` -> `jcList` array of {Contents, Type, Application}. "
                   + "Text only by design — Flycut never stored images.",
               read: stageFlycut),

        Source(id: "raycast", name: "Raycast",
               candidatePaths: ["~/Library/Application Support/com.raycast.macos/raycast.sqlite"],
               confidence: .unknown,
               note: "sqlite, schema not established. Run `--import-probe` against it.",
               read: nil),

        Source(id: "pastebot", name: "Pastebot (Tapbots)",
               candidatePaths: ["~/Library/Containers/com.tapbots.Pastebot2Mac/Data/Library/Application Support/Pastebot"],
               confidence: .unknown,
               note: "Sandboxed Core Data; container name confirmed, schema not. Probe it.",
               read: nil),

        Source(id: "copyem", name: "Copy'em Paste",
               candidatePaths: ["~/Library/Containers/com.fiplab.clipboardmanager/Data/Library/Application Support"],
               confidence: .unknown,
               note: "Sandboxed. Probe it.", read: nil),

        Source(id: "clipy", name: "Clipy",
               candidatePaths: ["~/Library/Application Support/com.clipy-app.Clipy/default.realm"],
               confidence: .unknown,
               note: "REALM, not sqlite — needs the Realm library to read, so no adapter is "
                   + "possible without adding that dependency. Clipy can export to a folder; "
                   + "import that instead.",
               read: nil),

        Source(id: "copyclip", name: "CopyClip",
               candidatePaths: ["~/Library/Containers/com.fiplab.copyclip2/Data/Library/Application Support"],
               confidence: .unknown, note: "Sandboxed. Probe it.", read: nil),

        Source(id: "launchbar", name: "LaunchBar",
               candidatePaths: ["~/Library/Application Support/LaunchBar/Clipboard History"],
               confidence: .unknown,
               note: "Stores a folder of files rather than a database. Probe the directory.",
               read: nil),
    ]

    // MARK: - Discovery

    @MainActor
    static func scan() {
        // Plain Swift padding, not String(format:). The first version used printf `%s`,
        // which expects a C string pointer — passing a Swift String there is undefined and
        // silently produced NO output at all, so the command appeared to succeed and print
        // nothing. `%@` would work; padding avoids the question entirely.
        func pad(_ s: String, _ n: Int) -> String {
            s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
        }
        print("macOS clipboard managers Cliphoard can import from\n")
        print("  " + pad("ID", 11) + pad("APP", 23) + pad("STATUS", 12) + "STORE FOUND HERE")
        for source in all {
            print("  " + pad(source.id, 11) + pad(source.name, 23)
                  + pad(source.confidence.rawValue, 12) + (resolve(source) ?? "—"))
        }
        print("")
        for source in all where source.confidence != .verified {
            print("  \(source.id): \(source.note)")
        }
        print("""

        verified   run against real data, row counts reconciled
        fromSource schema read from the app's own source; NEVER executed
        documented schema from docs/community; NEVER executed
        unknown    no adapter — use --import-probe <path> to establish the schema

        Anything not `verified` DRY RUNS unless you pass --force.

          --import-scan
          --import-probe <path-to-sqlite>
          --import-from <id> [path] [--force]
        """)
    }

    static func resolve(_ s: Source) -> String? {
        for p in s.candidatePaths {
            let expanded = (p as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) { return expanded }
        }
        return nil
    }

    /// Open an UNKNOWN sqlite store and describe it, so a new adapter is a short read rather
    /// than a reverse-engineering project. Reports tables, row counts, columns, and — the
    /// useful part — which columns actually hold bytes worth importing, with a sample.
    static func probe(path: String) {
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?mode=ro&immutable=1", &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            return print("cannot open \(path) as sqlite")
        }
        defer { sqlite3_close(db) }

        func query(_ sql: String) -> [[String]] {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var rows: [[String]] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                var row: [String] = []
                for c in 0..<sqlite3_column_count(stmt) {
                    row.append(sqlite3_column_text(stmt, c).map { String(cString: $0) } ?? "")
                }
                rows.append(row)
            }
            return rows
        }

        print("probing \(path)\n")
        let tables = query("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;")
            .compactMap(\.first)
        for table in tables where !table.hasPrefix("sqlite_") {
            let n = query("SELECT COUNT(*) FROM \"\(table)\";").first?.first ?? "?"
            guard let count = Int(n), count > 0 else { continue }
            print("  \(table)  (\(count) rows)")
            for col in query("PRAGMA table_info(\"\(table)\");") where col.count > 2 {
                let name = col[1], type = col[2]
                // A column matters if it actually carries content. Report the widest sample
                // rather than the first: a text column is often empty in early rows.
                let sample = query("""
                    SELECT length("\(name)"), substr(CAST("\(name)" AS TEXT),1,60)
                    FROM "\(table)" WHERE "\(name)" IS NOT NULL
                    ORDER BY length("\(name)") DESC LIMIT 1;
                    """).first
                let len = sample?.first ?? "0"
                let peek = (sample?.count ?? 0) > 1 ? sample![1] : ""
                let flag = (Int(len) ?? 0) > 40 ? "  <-- content?" : ""
                print(String(format: "      %-26s %-10s max=%-8s %@%@",
                             (name as NSString).utf8String!, (type as NSString).utf8String!,
                             (len as NSString).utf8String!,
                             peek.replacingOccurrences(of: "\n", with: " "), flag))
            }
            print("")
        }
        print("""
        Next: find the table whose row count matches the app's clip count, identify the
        content column (widest, marked above) and the timestamp column, then copy an
        existing adapter in ClipImporters.swift. Core Data stores timestamps as seconds
        since 2001-01-01; a 31-year offset means you used the Unix epoch.
        """)
    }

    // MARK: - Adapters

    /// Maccy. SwiftData persists to Core Data tables, so `HistoryItemContent(type:value:)`
    /// lands as ZHISTORYITEMCONTENT(ZTYPE, ZVALUE) joined to ZHISTORYITEM.
    ///
    /// The `type` is a pasteboard UTI, which is better than any other source here: it says
    /// exactly what the bytes are instead of leaving it to be guessed from a numeric code.
    /// One item may carry SEVERAL representations (plain text AND rtf AND html); the richest
    /// is not wanted — the plain one is, because that is what Cliphoard indexes.
    @MainActor
    private static func stageMaccy(path: String, tally: inout PasteImport.Tally) -> [Staged] {
        var out: [Staged] = []
        forEachRow(path, """
            SELECT i.Z_PK, i.ZFIRSTCOPIEDAT, i.ZAPPLICATION, c.ZTYPE, c.ZVALUE
            FROM ZHISTORYITEMCONTENT c
            JOIN ZHISTORYITEM i ON i.Z_PK = c.ZITEM
            ORDER BY i.ZFIRSTCOPIEDAT ASC
            """) { stmt in
            let created = appleDate(sqlite3_column_double(stmt, 1))
            let app = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            let uti = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            guard let bytes = sqlite3_column_blob(stmt, 4) else { return }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 4)))

            switch uti {
            case "public.utf8-plain-text", "public.plain-text", "NSStringPboardType":
                guard let text = String(data: data, encoding: .utf8),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    tally.skippedEmpty += 1; return
                }
                out.append(Staged(kind: ClipboardMonitor.detectKind(for: text), text: text,
                                  created: created, sourceApp: app, filePath: nil,
                                  colorHex: nil, imageData: nil))
            case "public.png", "public.tiff", "public.jpeg":
                out.append(Staged(kind: .image, text: "Image", created: created,
                                  sourceApp: app, filePath: nil, colorHex: nil, imageData: data))
            case "public.file-url":
                guard let s = String(data: data, encoding: .utf8),
                      let url = URL(string: s) else { tally.skippedEmpty += 1; return }
                out.append(Staged(kind: .file, text: url.path, created: created,
                                  sourceApp: app, filePath: url.path, colorHex: nil,
                                  imageData: nil))
            default:
                // rtf/html/etc: skipped rather than imported as markup. The same item almost
                // always carries a plain-text representation, which the case above takes.
                tally.skippedUnparsable += 1
            }
        }
        return out
    }

    /// Alfred. A plain sqlite table rather than Core Data, so timestamps are UNIX seconds —
    /// the one adapter here that must not use the Apple epoch.
    @MainActor
    private static func stageAlfred(path: String, tally: inout PasteImport.Tally) -> [Staged] {
        var out: [Staged] = []
        forEachRow(path, "SELECT item, ts, app FROM clipboard ORDER BY ts ASC;") { stmt in
            guard let raw = sqlite3_column_text(stmt, 0) else { tally.skippedEmpty += 1; return }
            let text = String(cString: raw)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                tally.skippedEmpty += 1; return
            }
            // `ts` is stored as text in some versions and a number in others; take whichever
            // parses rather than assuming, because a wrong epoch is silent.
            let tsText = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let seconds = Double(tsText) ?? ISO8601DateFormatter().date(from: tsText)?
                .timeIntervalSince1970 ?? 0
            let created = seconds > 0 ? Date(timeIntervalSince1970: seconds) : Date()
            let app = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            out.append(Staged(kind: ClipboardMonitor.detectKind(for: text), text: text,
                              created: created, sourceApp: app, filePath: nil,
                              colorHex: nil, imageData: nil))
        }
        return out
    }

    /// Flycut. A preferences plist, not a database. Text only — Flycut never stored images,
    /// so an empty image count here is correct rather than a failure.
    @MainActor
    private static func stageFlycut(path: String, tally: inout PasteImport.Tally) -> [Staged] {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [],
                                                                      format: nil) as? [String: Any],
              let store = plist["store"] as? [String: Any],
              let list = store["jcList"] as? [[String: Any]] else {
            return []
        }
        var out: [Staged] = []
        for entry in list {
            guard let text = entry["Contents"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                tally.skippedEmpty += 1; continue
            }
            // Flycut keeps no timestamp per entry. Ordering is all it preserves, so the
            // list position becomes a synthetic descending time — stated rather than hidden,
            // because "imported clips all share one date" surprises people otherwise.
            let created = Date().addingTimeInterval(-Double(out.count) * 60)
            out.append(Staged(kind: ClipboardMonitor.detectKind(for: text), text: text,
                              created: created,
                              sourceApp: entry["Application"] as? String,
                              filePath: nil, colorHex: nil, imageData: nil))
        }
        return out
    }

    // MARK: - Shared plumbing

    static func appleDate(_ interval: Double) -> Date {
        Date(timeIntervalSince1970: 978_307_200).addingTimeInterval(interval)
    }

    static func forEachRow(_ path: String, _ sql: String, _ body: (OpaquePointer?) -> Void) {
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?mode=ro&immutable=1", &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("Cliphoard import: query failed — \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { body(stmt) }
    }

    /// The single writer. Every adapter's output goes through here, so sealing, the detector
    /// veto, dedup and payload handling exist once — and a new adapter cannot get any of
    /// them subtly wrong, because it never touches them.
    @MainActor
    static func write(_ staged: [Staged], marker: String, store: ClipStore,
                      dryRun: Bool, tally: inout PasteImport.Tally) {
        var seen = Set(store.items.map(\.signature))
        for s in staged {
            let item: ClipItem
            if let png = s.imageData {
                guard let made = PasteImport.imageItem(from: png,
                                                       into: store.storeDirectory,
                                                       tally: &tally) else { continue }
                item = made
            } else {
                item = ClipItem(kind: s.kind, text: s.text)
                item.filePath = s.filePath
                item.colorHex = s.colorHex
            }
            guard !seen.contains(item.signature) else { tally.skippedDuplicate += 1; continue }
            seen.insert(item.signature)
            item.createdAt = s.created
            item.lastUsedAt = s.created
            item.sourceApp = s.sourceApp
            item.userTags = [marker]
            tally.byKind[item.kind.rawValue, default: 0] += 1
            tally.imported += 1
            if !dryRun { store.add(item) }
        }
    }
}
