import XCTest
import AppKit
import SQLite3
@testable import Cliphoard

/// Shared fixture for the four `HistoryArchive*` test files.
///
/// It writes a RAW 1.0-schema database with `sqlite3` directly, the way
/// `SourceAppEncryptionTests` does, because the archive tests need exact control over
/// columns no public API lets a test set: a NULL `ocr_text` versus an empty one, an
/// unknown high `flags` bit, a row sealed under a key this process does not hold. Building
/// the fixture through `ClipStore.add` would run the detectors over every one of those and
/// hand back whatever they decided, which is the opposite of a fixture.
///
/// Kept in its own file rather than copied into three, on the precedent of
/// `FrozenStoreSkip.swift`.
@MainActor
enum ArchiveFixture {

    /// Every other one-shot pass is retired for the duration of a test, so the store under
    /// test runs nothing that rewrites rows behind the assertions.
    static let retiredDefaults = ["dbEncryptedV1", "reKeySEv2", "imagesEncryptedV1",
                                  "detectorBackfillV1", "sourceAppEncryptedV1"]
    /// Saved and restored around every test: they are process-wide `UserDefaults`, and the
    /// history limit in particular is mutated by the import under test.
    static let mutatedDefaults = ["historyLimit", "imageUnderstandingEnabled", "deepSearchLevel"]

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    struct Row {
        var id = UUID()
        /// Written into the `id` column verbatim when set, so a test can plant a row the
        /// loader will SKIP (`guard let id = UUID(uuidString:)`) and thereby force a short
        /// read — the one condition that makes `loadAllStatus` report `.short`.
        var rawID: String?
        var kind: ClipKind = .text
        var text: String = ""
        var rtf: Data?
        var payloadFile: String?
        var filePath: String?
        var colorHex: String?
        var createdAt: Double = 700_000_000
        var lastUsedAt: Double = 700_000_000
        var pinned = false
        var sourceApp: String?
        var useCount = 0
        var userTags: [String] = []
        var flags: Int = 0
        var shape: String?
        /// `nil` writes SQL NULL — "never analysed". `""` seals to real ciphertext that
        /// opens back to "" — "analysed, deliberately withheld". The distinction is the
        /// point of several tests here.
        var ocrText: String?
        /// When false the `text` column is written VERBATIM, so a test can plant a row
        /// sealed under a key this process does not hold.
        var sealText = true
        var imageFeature: (revision: Int, vector: [Float])?
        /// Per-model text/pixel vectors, so a fixture can carry the 71% of a real database
        /// the archive deliberately leaves out.
        var embeddings: [String: [Float]] = [:]
    }

    // MARK: - Building a store directory

    /// Write `rows` (and their payload files) into `dir` as a real Cliphoard store.
    static func write(_ rows: [Row], dismissals: [(tag: String, clipID: UUID)] = [],
                      payloads: [String: Data] = [:], to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        for (name, png) in payloads {
            let sealed = try XCTUnwrap(Crypto.sealStrict(png))
            try sealed.write(to: dir.appendingPathComponent(name), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: dir.appendingPathComponent(name).path)
        }
        var raw: OpaquePointer?
        let path = dir.appendingPathComponent("ditto.sqlite").path
        XCTAssertEqual(sqlite3_open_v2(path, &raw,
                                       SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil),
                       SQLITE_OK)
        defer { sqlite3_close_v2(raw) }
        exec(raw, """
            CREATE TABLE IF NOT EXISTS clips (
                id TEXT PRIMARY KEY, kind TEXT NOT NULL, text TEXT NOT NULL,
                rtf BLOB, payload_file TEXT, file_path TEXT, color_hex TEXT,
                created_at REAL NOT NULL, last_used_at REAL NOT NULL,
                pinned INTEGER NOT NULL, source_app TEXT, use_count INTEGER NOT NULL,
                user_tags TEXT, flags INTEGER, shape TEXT, ocr_text TEXT);
            """)
        exec(raw, """
            CREATE TABLE IF NOT EXISTS image_features (
                clip_id TEXT NOT NULL PRIMARY KEY, revision INTEGER NOT NULL,
                vector BLOB NOT NULL);
            """)
        exec(raw, """
            CREATE TABLE IF NOT EXISTS embeddings (
                clip_id TEXT NOT NULL, model TEXT NOT NULL, vector BLOB NOT NULL,
                PRIMARY KEY (clip_id, model));
            """)
        exec(raw, """
            CREATE TABLE IF NOT EXISTS user_tag_dismissals (
                tag TEXT NOT NULL, clip_id TEXT NOT NULL, PRIMARY KEY (tag, clip_id));
            """)
        for row in rows {
            var stmt: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(raw, """
                INSERT INTO clips (id, kind, text, rtf, payload_file, file_path, color_hex,
                                   created_at, last_used_at, pinned, source_app, use_count,
                                   user_tags, flags, shape, ocr_text)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, -1, &stmt, nil), SQLITE_OK)
            bind(stmt, 1, row.rawID ?? row.id.uuidString)
            bind(stmt, 2, row.kind.rawValue)
            bind(stmt, 3, row.sealText ? try XCTUnwrap(Crypto.sealStrict(row.text)) : row.text)
            if let rtf = row.rtf {
                let sealed = try XCTUnwrap(Crypto.sealStrict(rtf))
                _ = sealed.withUnsafeBytes {
                    sqlite3_bind_blob(stmt, 4, $0.baseAddress, Int32(sealed.count), transient)
                }
            } else { sqlite3_bind_null(stmt, 4) }
            bind(stmt, 5, row.payloadFile)
            bind(stmt, 6, try row.filePath.map { try XCTUnwrap(Crypto.sealStrict($0)) })
            bind(stmt, 7, try row.colorHex.map { try XCTUnwrap(Crypto.sealStrict($0)) })
            sqlite3_bind_double(stmt, 8, row.createdAt)
            sqlite3_bind_double(stmt, 9, row.lastUsedAt)
            sqlite3_bind_int(stmt, 10, row.pinned ? 1 : 0)
            bind(stmt, 11, try row.sourceApp.map { try XCTUnwrap(Crypto.sealStrict($0)) })
            sqlite3_bind_int(stmt, 12, Int32(row.useCount))
            bind(stmt, 13, try XCTUnwrap(Crypto.sealStrict(row.userTags.joined(separator: "\n"))))
            sqlite3_bind_int64(stmt, 14, Int64(row.flags))
            bind(stmt, 15, row.shape)
            bind(stmt, 16, try row.ocrText.map { try XCTUnwrap(Crypto.sealStrict($0)) })
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
            sqlite3_finalize(stmt)

            for (model, vector) in row.embeddings {
                let sealed = try XCTUnwrap(
                    Crypto.sealStrict(Database.blob(fromVector: vector)))
                var estmt: OpaquePointer?
                XCTAssertEqual(sqlite3_prepare_v2(raw, """
                    INSERT INTO embeddings (clip_id, model, vector) VALUES (?,?,?);
                    """, -1, &estmt, nil), SQLITE_OK)
                bind(estmt, 1, row.id.uuidString)
                bind(estmt, 2, model)
                _ = sealed.withUnsafeBytes {
                    sqlite3_bind_blob(estmt, 3, $0.baseAddress, Int32(sealed.count), transient)
                }
                XCTAssertEqual(sqlite3_step(estmt), SQLITE_DONE)
                sqlite3_finalize(estmt)
            }
            if let fp = row.imageFeature {
                let sealed = try XCTUnwrap(
                    Crypto.sealStrict(Database.blob(fromVector: fp.vector)))
                var fstmt: OpaquePointer?
                XCTAssertEqual(sqlite3_prepare_v2(raw, """
                    INSERT INTO image_features (clip_id, revision, vector) VALUES (?,?,?);
                    """, -1, &fstmt, nil), SQLITE_OK)
                bind(fstmt, 1, row.id.uuidString)
                sqlite3_bind_int(fstmt, 2, Int32(fp.revision))
                _ = sealed.withUnsafeBytes {
                    sqlite3_bind_blob(fstmt, 3, $0.baseAddress, Int32(sealed.count), transient)
                }
                XCTAssertEqual(sqlite3_step(fstmt), SQLITE_DONE)
                sqlite3_finalize(fstmt)
            }
        }
        for dismissal in dismissals {
            var stmt: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(raw, """
                INSERT INTO user_tag_dismissals (tag, clip_id) VALUES (?,?);
                """, -1, &stmt, nil), SQLITE_OK)
            bind(stmt, 1, try XCTUnwrap(Crypto.sealStrict(dismissal.tag)))
            bind(stmt, 2, dismissal.clipID.uuidString)
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
            sqlite3_finalize(stmt)
        }
    }

    private static func exec(_ db: OpaquePointer?, _ sql: String) {
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    private static func bind(_ stmt: OpaquePointer?, _ i: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(stmt, i, value, -1, transient) }
        else { sqlite3_bind_null(stmt, i) }
    }

    // MARK: - The standard ~50-clip fixture

    /// A real PNG. Deterministic for a given `seed`, so its content hash — and therefore
    /// its file name — is stable across a rebuild of the fixture.
    static func png(seed: Int, size: Int = 24) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: size * 4, bitsPerPixel: 32)!
        // Written straight into the bitmap plane rather than through `setColor`, which
        // round-trips every pixel through a colour space and floods the log.
        if let plane = rep.bitmapData {
            for y in 0..<size {
                for x in 0..<size {
                    let i = (y * size + x) * 4
                    plane[i] = UInt8((seed &* 37 &+ x) % 256)
                    plane[i + 1] = UInt8((y &* 11 &+ seed) % 256)
                    plane[i + 2] = UInt8((x &* y &+ seed) % 256)
                    plane[i + 3] = 255
                }
            }
        }
        return rep.representation(using: .png, properties: [:])!
    }

    struct Standard {
        var rows: [Row]
        var payloads: [String: Data]
        var dismissals: [(tag: String, clipID: UUID)]
        /// The clip whose `ocr_text` is SQL NULL — "never analysed".
        var neverAnalysedImageID: UUID
        /// The clip whose `ocr_text` is `""` — "analysed, deliberately withheld".
        var withheldImageID: UUID
        /// The quarantined clip.
        var quarantinedID: UUID
        /// The clip carrying a flag bit no build knows.
        var unknownFlagID: UUID
        /// The clip whose literal text begins with the seal marker.
        var markerLookalikeID: UUID
        var imageIDsWithPrints: [UUID]
    }

    /// Fifty clips across all five kinds: three real PNGs (one with a Vision print), RTF,
    /// emoji, CJK, combining marks, an NFC/NFD pair, a clip whose text literally begins
    /// `enc1:`, pins, use counts, multi-word tags, a quarantined clip, an unknown high
    /// flag bit, one `ocrText == ""` and one `ocrText == nil`, and one dismissal.
    static func standard() -> Standard {
        var rows: [Row] = []
        var payloads: [String: Data] = [:]

        for n in 0..<28 {
            rows.append(Row(kind: .text, text: "plain clip number \(n) — ordinary text",
                            createdAt: 700_000_000 + Double(n),
                            lastUsedAt: 700_000_100 + Double(n),
                            pinned: n % 9 == 0,
                            sourceApp: n % 3 == 0 ? "com.apple.Safari" : nil,
                            useCount: n,
                            userTags: n % 5 == 0 ? ["work notes", "keep"] : []))
        }
        rows.append(Row(kind: .text, text: "emoji 🧪🔐 and CJK 日本語テキスト and Ελληνικά",
                        createdAt: 700_000_200, lastUsedAt: 700_000_200))
        // An NFC/NFD pair: the SAME grapheme, two byte sequences. If anything in the path
        // normalises text, these two collapse into one and the count changes.
        rows.append(Row(kind: .text, text: "cafe\u{0301} decomposed",
                        createdAt: 700_000_201, lastUsedAt: 700_000_201))
        rows.append(Row(kind: .text, text: "caf\u{00E9} composed",
                        createdAt: 700_000_202, lastUsedAt: 700_000_202))
        rows.append(Row(kind: .text, text: "combining mark a\u{0308}o\u{030A}u\u{0302}",
                        createdAt: 700_000_203, lastUsedAt: 700_000_203))

        // Text carrying the seal marker in the MIDDLE. A clip whose text BEGINS with the
        // marker is a different and much harder case — `Crypto.open` fails open, so the
        // whole app (not just the archive) reads it as ciphertext it could not decrypt —
        // and it gets its own test in `HistoryArchiveSafetyTests` rather than being folded
        // in here, where it would make every round trip run down the unreadable path.
        let markerLookalike = Row(kind: .text,
                                  text: "the literal marker enc1:AAAA sits inside this clip",
                                  createdAt: 700_000_204, lastUsedAt: 700_000_204)
        rows.append(markerLookalike)

        let rtf = try! NSAttributedString(string: "styled text",
                                          attributes: [.font: NSFont.systemFont(ofSize: 14)])
            .data(from: NSRange(location: 0, length: 11),
                  documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        rows.append(Row(kind: .text, text: "styled text", rtf: rtf,
                        createdAt: 700_000_205, lastUsedAt: 700_000_205))

        for n in 0..<6 {
            rows.append(Row(kind: .link, text: "https://example.com/page/\(n)",
                            createdAt: 700_000_300 + Double(n),
                            lastUsedAt: 700_000_300 + Double(n)))
        }
        for n in 0..<3 {
            rows.append(Row(kind: .color, text: "#FF88\(n)0", colorHex: "#FF88\(n)0",
                            createdAt: 700_000_400 + Double(n),
                            lastUsedAt: 700_000_400 + Double(n)))
        }
        for n in 0..<3 {
            rows.append(Row(kind: .file, text: "/Users/someone/Documents/file\(n).pdf",
                            filePath: "/Users/someone/Documents/file\(n).pdf",
                            createdAt: 700_000_500 + Double(n),
                            lastUsedAt: 700_000_500 + Double(n)))
        }

        // Three real PNGs.
        var imageIDs: [UUID] = []
        var neverAnalysed = UUID(), withheld = UUID()
        for n in 0..<3 {
            let bytes = png(seed: n)
            let name = HistoryArchive.sha256Hex(bytes) + ".png"
            payloads[name] = bytes
            var row = Row(kind: .image, text: "Image 24×24", payloadFile: name,
                          createdAt: 700_000_600 + Double(n),
                          lastUsedAt: 700_000_600 + Double(n))
            switch n {
            case 0:
                // Analysed, with recognised text AND a Vision print — the clip that proves
                // §1.1: nothing on the destination will ever recompute this print, because
                // `needsImageUnderstanding` is false the moment `ocrText` is non-nil.
                row.ocrText = "RECOGNISED WORDS IN THE SCREENSHOT"
                row.imageFeature = (revision: 2, vector: (0..<768).map { Float($0) * 0.001 })
            case 1:
                // Analysed, deliberately withheld.
                row.ocrText = ""
                withheld = row.id
            default:
                // Never analysed — SQL NULL.
                row.ocrText = nil
                neverAnalysed = row.id
            }
            imageIDs.append(row.id)
            rows.append(row)
        }

        // A quarantined clip: stored, visible, never indexed.
        var quarantined = Row(kind: .text, text: "hunter2 from the vault",
                              createdAt: 700_000_700, lastUsedAt: 700_000_700,
                              sourceApp: "com.bitwarden.desktop")
        quarantined.flags = ClipFlags.quarantined.rawValue
        rows.append(quarantined)

        // A flag bit no build knows. `Database.insert` writes the raw value verbatim so a
        // newer version's bit survives a round trip through an older one; the archive has
        // to do the same or it is the weakest link in that chain.
        var unknownFlag = Row(kind: .text, text: "written by a newer Cliphoard",
                              createdAt: 700_000_701, lastUsedAt: 700_000_701)
        unknownFlag.flags = 1 << 30
        unknownFlag.shape = "json"
        rows.append(unknownFlag)

        let dismissals = [(tag: "receipts", clipID: rows[0].id)]
        return Standard(rows: rows, payloads: payloads, dismissals: dismissals,
                        neverAnalysedImageID: neverAnalysed,
                        withheldImageID: withheld,
                        quarantinedID: quarantined.id,
                        unknownFlagID: unknownFlag.id,
                        markerLookalikeID: markerLookalike.id,
                        imageIDsWithPrints: [imageIDs[0]])
    }
}

/// Save/restore of every `UserDefaults` key the archive tests disturb, plus a per-test
/// temp directory. Modelled on `SourceAppEncryptionTests`.
@MainActor
class ArchiveTestCase: XCTestCase {
    var savedDefaults: [String: Any?] = [:]
    var tempRoot: URL!

    override func setUp() {
        super.setUp()
        Feedback.soundEnabled = false
        let keys = ArchiveFixture.retiredDefaults + ArchiveFixture.mutatedDefaults
        for key in keys { savedDefaults[key] = UserDefaults.standard.object(forKey: key) }
        for key in ArchiveFixture.retiredDefaults {
            UserDefaults.standard.set(true, forKey: key)
        }
        // Recognition off: it is a background pass that rewrites `ocr_text` and would race
        // every assertion here. The archive's job is to carry what is stored, not to make
        // more of it.
        UserDefaults.standard.set(false, forKey: "imageUnderstandingEnabled")
        UserDefaults.standard.set(0, forKey: "historyLimit")
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CliphoardArchive-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for (key, value) in savedDefaults {
            if let value = value ?? nil { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        savedDefaults = [:]
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        super.tearDown()
    }

    func directory(_ name: String) -> URL {
        let url = tempRoot.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The repo root, for the source-text assertions the UI tests make.
    var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func source(_ path: String) throws -> String {
        try String(contentsOf: sourceRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// The body of a member, from its declaration to the earliest NEXT declaration — never
    /// a character count, so an unrelated later call cannot satisfy an assertion.
    func body(of decl: String, in src: String) -> String? {
        guard let start = src.range(of: decl) else { return nil }
        let rest = src[start.upperBound...]
        let ends = ["\n    private ", "\n    static func ", "\n    func ", "\n    // MARK:",
                    "\n    @objc ", "\n    override ", "\n    var ", "\n    @discardableResult",
                    "\n    @Published", "\n    struct ", "\n    init("]
            .compactMap { rest.range(of: $0)?.lowerBound }
        return String(rest[..<(ends.min() ?? rest.endIndex)])
    }
}
