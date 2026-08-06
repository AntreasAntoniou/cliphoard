import XCTest
import SQLite3
@testable import Cliphoard

/// Wiring for the Tier-1 detector verdict (design §5): the pass runs
/// synchronously at capture, *before* the embed and the SQLite write; the verdict
/// is persisted on the clip; and `.secret` / `.quarantined` VETO indexing — at
/// ingest and on every later re-index/reclassify pass.
///
/// `DetectorTests` proves the rules themselves. This file only proves they are
/// plugged in, in the right order, and that the wire format survives an upgrade.
final class DetectorWiringTests: XCTestCase {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// A PEM header is decisive on its own (§3.1) — no key material needed, so
    /// this fixture contains nothing that resembles a real secret.
    private static let pemKey = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIBOgIBAAJBAK
        -----END RSA PRIVATE KEY-----
        """
    /// A syntactically-shaped AWS access key id (AKIA + 16 uppercase alnum).
    /// Copied on its own, which is how a key reaches a clipboard — the signature
    /// only ever matches at a token start, by design.
    private static let awsKey = "AKIA" + "IOSFODNN7EXAMPLE"

    private func tempPath() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoDetectorWiring-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("t.sqlite").path
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoDetectorWiringStore-\(UUID().uuidString)")
    }

    private func columns(ofTable table: String, path: String) -> [String] {
        var raw: OpaquePointer?
        guard sqlite3_open_v2(path, &raw, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close_v2(raw) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(raw, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK else { return [] }
        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 1) {
            names.append(String(cString: c))
        }
        return names
    }

    /// Force a raw `flags` value onto a row through an independent connection —
    /// how a NEWER build's bits would look to this one.
    private func writeRawFlags(_ value: Int64, id: UUID, path: String) {
        var raw: OpaquePointer?
        guard sqlite3_open_v2(path, &raw, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            return XCTFail("could not reopen database for a raw write")
        }
        defer { sqlite3_close_v2(raw) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_prepare_v2(raw, "UPDATE clips SET flags=? WHERE id=?;", -1, &stmt, nil), SQLITE_OK)
        sqlite3_bind_int64(stmt, 1, value)
        sqlite3_bind_text(stmt, 2, id.uuidString, -1, Self.transient)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
    }

    // MARK: Capture-time veto

    /// The whole point of the §5 ordering: a Tier-1 secret is flagged, persisted,
    /// and has NO vector for the active model — the detector vetoed the embed.
    @MainActor
    func testSecretIsFlaggedPersistedAndNeverEmbedded() throws {
        Feedback.soundEnabled = false
        DeepSearch.level = .normal          // ingest WOULD embed, if not vetoed
        defer { DeepSearch.level = .off }
        let dir = tempDir()

        var store: ClipStore? = ClipStore(directory: dir)
        let pem = ClipItem(kind: .text, text: Self.pemKey)
        let aws = ClipItem(kind: .text, text: "aws key \(Self.awsKey)")
        store?.add(pem)
        store?.add(aws)

        for secret in [pem, aws] {
            XCTAssertTrue(secret.flags.contains(.secret), "Tier-1 credential must set .secret")
            // No vector under ANY signature — a stronger (and swap-proof) claim
            // than "none for the currently active model".
            XCTAssertTrue(secret.embeddings.isEmpty,
                          "a secret must never be sent through the model (§5 veto)")
        }
        // Vetoed ≠ dropped: it is still in history, and still on disk.
        XCTAssertEqual(store?.items.count, 2)
        store = nil

        let reloaded = ClipStore(directory: dir)
        XCTAssertEqual(reloaded.items.count, 2, "vetoed clips are still stored")
        for item in reloaded.items {
            XCTAssertTrue(item.flags.contains(.secret), ".secret survives the round-trip")
            XCTAssertTrue(item.embeddings.isEmpty, "and still has no vector after a reload")
        }
    }

    /// A clip from a denylisted password manager is quarantined by ORIGIN and is
    /// vetoed on that alone, even though its content is unremarkable.
    @MainActor
    func testQuarantinedSourceIsVetoedOnOriginAlone() {
        Feedback.soundEnabled = false
        DeepSearch.level = .normal
        defer { DeepSearch.level = .off }

        let store = ClipStore(directory: tempDir())
        let item = ClipItem(kind: .text, text: "correct horse battery staple")
        item.sourceApp = "1Password"
        store.add(item)

        XCTAssertTrue(item.flags.contains(.quarantined))
        XCTAssertFalse(item.flags.contains(.secret), "origin is not a content claim")
        XCTAssertTrue(item.embeddings.isEmpty, "a quarantined clip is excluded from the index")
    }

    /// The complement: an ordinary clip is embedded exactly as before, carries no
    /// flags, and gets a shape only when it genuinely has one.
    @MainActor
    func testBenignClipIsIndexedNormallyAndCarriesNoFlags() throws {
        Feedback.soundEnabled = false
        DeepSearch.level = .normal
        defer { DeepSearch.level = .off }

        let store = ClipStore(directory: tempDir())
        let prose = ClipItem(kind: .text, text: "remember to buy oat milk on the way home")
        let json = ClipItem(kind: .text, text: "{\"user\": \"ada\", \"active\": true}")
        // Captured between construction and the adds so no other test's async
        // model load can swap the embedder underneath the assertion: a signature
        // grabbed at the top of the method is not guaranteed to still be active.
        let sig = EmbedderProvider.active.signature
        store.add(prose)
        store.add(json)

        for item in [prose, json] {
            XCTAssertEqual(item.flags, [], "nothing fired — and no positive label either")
            XCTAssertFalse(item.isIndexVetoed)
            XCTAssertFalse(item.embeddings.isEmpty, "a benign clip is indexed normally")
            XCTAssertNotNil(item.embeddings[sig], "…under the signature active at capture")
        }
        XCTAssertNil(prose.shape, "prose has no shape (§3.4: blank is a valid result)")
        XCTAssertEqual(json.shape, "json")
    }

    /// A background re-index must not quietly undo the veto.
    @MainActor
    func testReindexPassSkipsVetoedClips() async throws {
        Feedback.soundEnabled = false
        DeepSearch.level = .normal
        defer { DeepSearch.level = .off }

        let store = ClipStore(directory: tempDir())
        let secret = ClipItem(kind: .text, text: Self.pemKey)
        let benign = ClipItem(kind: .text, text: "meeting notes from the standup")
        store.add(secret)
        store.add(benign)
        XCTAssertTrue(secret.embeddings.isEmpty)

        // Strip the benign clip's vector so the pass has genuine work to do; the
        // secret is permanently stale by construction.
        benign.embeddings.removeAll()
        store.refreshForActiveModel()
        // Let the background pass run to completion.
        for _ in 0..<200 where store.indexing != nil { await Task.yield() }

        XCTAssertFalse(benign.embeddings.isEmpty, "the stale benign clip is re-indexed")
        XCTAssertTrue(secret.embeddings.isEmpty, "the veto holds across a re-index pass")

        // …and the reclassify path too (it recomputes tags from cached vectors).
        store.reclassifyAllTags()
        for _ in 0..<200 where store.indexing != nil { await Task.yield() }
        XCTAssertTrue(secret.embeddings.isEmpty, "reclassify must not resurrect a vetoed clip")
    }

    // MARK: Persistence

    func testFlagsAndShapeRoundTripThroughTheDatabase() throws {
        let path = tempPath()
        let db = try XCTUnwrap(Database(path: path))
        let item = ClipItem(kind: .text, text: "GET /v1/things")
        item.flags = [.secret, .pii, .otp]
        item.shape = "command"
        XCTAssertTrue(db.insert(item))

        let loaded = try XCTUnwrap(db.loadAll().first)
        XCTAssertEqual(loaded.flags, [.secret, .pii, .otp])
        XCTAssertEqual(loaded.shape, "command")

        // A clip with no verdict round-trips as "nothing fired" / no shape.
        let plain = ClipItem(kind: .text, text: "plain")
        XCTAssertTrue(db.insert(plain))
        let reloadedPlain = try XCTUnwrap(db.loadAll().first { $0.id == plain.id })
        XCTAssertEqual(reloadedPlain.flags, [])
        XCTAssertNil(reloadedPlain.shape)
    }

    /// Additive, guarded migration — the same contract `user_tags` has.
    func testPreDetectorDatabaseGainsColumnsAndReadsEmptyVerdict() throws {
        let path = tempPath()
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, """
            CREATE TABLE clips (
                id TEXT PRIMARY KEY, kind TEXT NOT NULL, text TEXT NOT NULL,
                rtf BLOB, payload_file TEXT, file_path TEXT, color_hex TEXT,
                created_at REAL NOT NULL, last_used_at REAL NOT NULL,
                pinned INTEGER NOT NULL, source_app TEXT, use_count INTEGER NOT NULL,
                user_tags TEXT);
            """, nil, nil, nil), SQLITE_OK)
        let legacyID = UUID()
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(raw, """
            INSERT INTO clips (id, kind, text, created_at, last_used_at, pinned, use_count)
            VALUES (?, 'text', 'legacy row', 1, 1, 0, 0);
            """, -1, &stmt, nil), SQLITE_OK)
        sqlite3_bind_text(stmt, 1, legacyID.uuidString, -1, Self.transient)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        sqlite3_finalize(stmt)
        sqlite3_close_v2(raw)

        let db = try XCTUnwrap(Database(path: path))
        let names = columns(ofTable: "clips", path: path)
        XCTAssertTrue(names.contains("flags"), "opening an old database ADDs the column")
        XCTAssertTrue(names.contains("shape"))

        let loaded = try XCTUnwrap(db.loadAll().first)
        XCTAssertEqual(loaded.id, legacyID, "the pre-existing row survives")
        XCTAssertEqual(loaded.text, "legacy row")
        XCTAssertEqual(loaded.flags, [], "a NULL flags column reads as nothing-fired")
        XCTAssertNil(loaded.shape)

        // Re-opening is idempotent (the guard must not ALTER twice).
        XCTAssertNotNil(Database(path: path))
        let again = columns(ofTable: "clips", path: path)
        XCTAssertEqual(again.filter { $0 == "flags" }.count, 1)
        XCTAssertEqual(again.filter { $0 == "shape" }.count, 1)
    }

    /// Bit-stability: a flag a FUTURE build wrote must survive being loaded and
    /// re-saved by this one. Masking the raw value down to known bits would
    /// silently downgrade someone's protections after a rollback.
    func testUnknownFutureBitsSurviveALoadSaveRoundTrip() throws {
        let path = tempPath()
        let db = try XCTUnwrap(Database(path: path))
        let item = ClipItem(kind: .text, text: "from the future")
        XCTAssertTrue(db.insert(item))

        // .secret (bit 0) plus two bits this build has no name for.
        let futureRaw: Int64 = (1 << 0) | (1 << 40) | (1 << 41)
        writeRawFlags(futureRaw, id: item.id, path: path)

        let loaded = try XCTUnwrap(db.loadAll().first)
        XCTAssertEqual(loaded.flags.rawValue, Int(futureRaw), "unknown bits are not stripped on read")
        XCTAssertTrue(loaded.flags.contains(.secret), "known bits still decode")
        XCTAssertEqual(loaded.flags.names, ["secret"], "unknown bits render as no badge, not a wrong one")

        XCTAssertTrue(db.insert(loaded))   // save it back
        let again = try XCTUnwrap(db.loadAll().first)
        XCTAssertEqual(again.flags.rawValue, Int(futureRaw), "unknown bits are not stripped on write")
    }

    /// The JSON path (legacy `history.json`) is equally forward/backward tolerant.
    func testCodableDecodesOlderClipsWithoutTheNewFields() throws {
        let legacy = Data("""
            [{"id":"\(UUID().uuidString)","kind":"text","text":"old clip",
              "createdAt":0,"lastUsedAt":0,"pinned":false,"useCount":0}]
            """.utf8)
        let decoded = try JSONDecoder().decode([ClipItem].self, from: legacy)
        let item = try XCTUnwrap(decoded.first)
        XCTAssertEqual(item.flags, [])
        XCTAssertNil(item.shape)

        item.flags = [.financial, .piiSensitive]
        item.shape = "value"
        let reDecoded = try JSONDecoder().decode(
            [ClipItem].self, from: try JSONEncoder().encode([item]))
        XCTAssertEqual(reDecoded.first?.flags, [.financial, .piiSensitive])
        XCTAssertEqual(reDecoded.first?.shape, "value")
    }
}
