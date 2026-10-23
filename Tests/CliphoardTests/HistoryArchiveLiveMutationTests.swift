import XCTest
import SQLite3
@testable import Cliphoard

/// The startup token describes the startup database, not the history after a capture.
/// Exercise real SQLite writes and failures without reloading the store to repair it.
@MainActor
final class HistoryArchiveLiveMutationTests: ArchiveTestCase {
    private let passphrase = "a sufficiently long archive test passphrase"
    private var savedSoundEnabled: Any?

    override func setUp() {
        savedSoundEnabled = UserDefaults.standard.object(forKey: "soundEnabled")
        super.setUp()
        DeepSearch.level = .off
    }

    override func tearDown() {
        if let savedSoundEnabled {
            UserDefaults.standard.set(savedSoundEnabled, forKey: "soundEnabled")
        } else {
            UserDefaults.standard.removeObject(forKey: "soundEnabled")
        }
        savedSoundEnabled = nil
        super.tearDown()
    }

    private func store(_ rows: [ArchiveFixture.Row]) throws -> (ClipStore, URL) {
        try skipIfKeychainUnreachable()
        let dir = directory("source")
        try ArchiveFixture.write(rows, to: dir)
        let store = ClipStore(directory: dir)
        XCTAssertFalse(store.safeMode)
        XCTAssertTrue(store.storageComplete)
        XCTAssertNotNil(store.archiveProof)
        return (store, dir)
    }

    private func sql(_ sql: String, in dir: URL) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(dir.appendingPathComponent("ditto.sqlite").path,
                                      &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close_v2(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK,
                       String(cString: sqlite3_errmsg(db)))
    }

    /// Includes rows in the WAL, unlike a snapshot of only the database file. Keep types
    /// and raw blob bytes so a failed export cannot hide a reseal or metadata rewrite.
    private func databaseSnapshot(_ dir: URL) throws -> [String: [[String]]] {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(dir.appendingPathComponent("ditto.sqlite").path,
                                      &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close_v2(db) }
        var snapshot: [String: [[String]]] = [:]
        for table in ["clips", "embeddings", "image_features", "user_tag_dismissals",
                      "sqlite_master"] {
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT * FROM \(table) ORDER BY rowid;",
                                              -1, &statement, nil), SQLITE_OK)
            let stmt = try XCTUnwrap(statement)
            defer { sqlite3_finalize(stmt) }
            var rows: [[String]] = []
            var rc = sqlite3_step(stmt)
            while rc == SQLITE_ROW {
                rows.append((0..<sqlite3_column_count(stmt)).map { column in
                    switch sqlite3_column_type(stmt, column) {
                    case SQLITE_NULL: return "null"
                    case SQLITE_INTEGER: return "int:\(sqlite3_column_int64(stmt, column))"
                    case SQLITE_FLOAT:
                        return "double:\(sqlite3_column_double(stmt, column).bitPattern)"
                    default:
                        let size = Int(sqlite3_column_bytes(stmt, column))
                        let data = sqlite3_column_blob(stmt, column).map {
                            Data(bytes: $0, count: size)
                        } ?? Data()
                        return "\(sqlite3_column_type(stmt, column)):\(data.base64EncodedString())"
                    }
                })
                rc = sqlite3_step(stmt)
            }
            XCTAssertEqual(rc, SQLITE_DONE)
            snapshot[table] = rows
        }
        return snapshot
    }

    private struct LiveState: Equatable {
        let clips: [HistoryArchive.Clip]
        let features: [HistoryArchive.FeatureRecord?]
        let objectIDs: [ObjectIdentifier]
        let storedCount: Int?
        let payloads: Set<String>?
        let imagePayloads: [UUID: String]?
        let unreadable: Set<UUID>?
        let complete: Bool
        let safeMode: Bool
        let unsaved: Int
    }

    private func state(_ store: ClipStore) -> LiveState {
        LiveState(clips: store.items.map(HistoryArchiveIO.archiveClip),
                  features: store.items.map { item in
                      item.imageFeature.map {
                          HistoryArchive.FeatureRecord(revision: $0.revision,
                              vectorB64: HistoryArchive.vectorBase64($0.vector))
                      }
                  }, objectIDs: store.items.map(ObjectIdentifier.init),
                  storedCount: store.archiveProof?.storedCount,
                  payloads: store.archiveProof?.referencedPayloads,
                  imagePayloads: store.archiveProof?.imagePayloadsByClip,
                  unreadable: store.archiveProof?.unreadableClipIDs,
                  complete: store.storageComplete, safeMode: store.safeMode,
                  unsaved: store.unsavedClipCount)
    }

    @discardableResult
    private func exportedClips(_ store: ClipStore, in dir: URL) throws -> [HistoryArchive.Clip] {
        let before = state(store)
        let databaseBefore = try databaseSnapshot(dir)
        let file = tempRoot.appendingPathComponent("export-\(UUID()).cliphoard")
        let report = try store.exportArchive(to: file, passphrase: passphrase).get()
        XCTAssertEqual(report.clipCount, store.items.count)
        XCTAssertEqual(state(store), before, "export must not refresh the live store or startup token")
        XCTAssertEqual(try databaseSnapshot(dir), databaseBefore)

        // Decode the complete encrypted stream, not merely the unauthenticated filename
        // or its summary. The current live projections must be exactly what was exported.
        let opened = try HistoryArchive.open(
            source: HistoryArchive.DataByteSource(Data(contentsOf: file)), passphrase: passphrase)
        let reader = HistoryArchive.RecordReader(chunks: HistoryArchive.ChunkReader(
            source: opened.source, key: opened.key, header: opened.header))
        var clips: [HistoryArchive.Clip] = []
        var features: [String: HistoryArchive.FeatureRecord] = [:]
        while true {
            let record = try reader.next()
            if record.type == HistoryArchive.RecordType.end.rawValue { break }
            if record.type == HistoryArchive.RecordType.clip.rawValue {
                clips.append(try JSONDecoder().decode(HistoryArchive.Clip.self, from: record.body))
            } else if record.type == HistoryArchive.RecordType.imageFeature.rawValue {
                features[record.name] = try JSONDecoder().decode(
                    HistoryArchive.FeatureRecord.self, from: record.body)
            }
        }
        XCTAssertEqual(clips.sorted { $0.id < $1.id }, before.clips.sorted { $0.id < $1.id })
        for item in store.items {
            let expected = item.imageFeature.flatMap { feature -> HistoryArchive.FeatureRecord? in
                guard !feature.vector.isEmpty else { return nil }
                return HistoryArchive.FeatureRecord(revision: feature.revision,
                    vectorB64: HistoryArchive.vectorBase64(feature.vector))
            }
            XCTAssertEqual(features[item.id.uuidString], expected)
        }
        return clips
    }

    private func assertRefused(_ store: ClipStore, in dir: URL,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let before = state(store)
        let databaseBefore = try databaseSnapshot(dir)
        let sourceEntries = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        for existing in [false, true] {
            let output = tempRoot.appendingPathComponent("refused-\(existing).cliphoard")
            let canary = Data("previous encrypted backup must survive".utf8)
            if existing { try canary.write(to: output) }
            let entries = try FileManager.default.contentsOfDirectory(atPath: tempRoot.path).sorted()
            switch store.exportArchive(to: output, passphrase: passphrase) {
            case .success: XCTFail("a divergent or incomplete history was exported", file: file, line: line)
            case .failure(let error):
                XCTAssertEqual(error, .historyNotProvenComplete, file: file, line: line)
            }
            if existing {
                XCTAssertEqual(try Data(contentsOf: output), canary, file: file, line: line)
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), file: file, line: line)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempRoot.path).sorted(),
                           entries, file: file, line: line)
            XCTAssertEqual(state(store), before, file: file, line: line)
            XCTAssertEqual(try databaseSnapshot(dir), databaseBefore, file: file, line: line)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
                           sourceEntries, file: file, line: line)
        }
    }

    func testCaptureThenExportWithoutRelaunchIncludesTheNewClip() throws {
        let (store, dir) = try store([ArchiveFixture.Row(text: "retained clip")])
        store.add(ClipItem(kind: .text, text: "fresh capture"))
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.archiveProof?.storedCount, 1, "the startup proof is intentionally stale")
        try exportedClips(store, in: dir)
    }

    func testExportUsesDetachedSnapshotIfProgressCallbackChangesALiveObject() throws {
        let (store, _) = try store([ArchiveFixture.Row(text: "the verified snapshot")])
        let live = try XCTUnwrap(store.items.first)
        let original = HistoryArchiveIO.archiveClip(live)
        let file = tempRoot.appendingPathComponent("snapshot.cliphoard")
        _ = try store.exportArchive(to: file, passphrase: passphrase) { _, _ in
            live.text = "changed after verification"
            live.pinned = true
        }.get()
        let staged = try HistoryArchiveIO.stage(url: file, passphrase: passphrase,
            into: directory("preview"), safeMode: false, storageComplete: true,
            hasProof: true).get()
        defer { HistoryArchiveIO.discard(staged) }
        XCTAssertEqual(staged.clips.map(HistoryArchiveIO.archiveClip), [original])
        XCTAssertEqual(live.text, "changed after verification")
        XCTAssertTrue(live.pinned)
    }

    func testDuplicateCaptureExportsTheSameIDWithItsNewRecency() throws {
        let row = ArchiveFixture.Row(text: "capture this again")
        let (store, dir) = try store([row, ArchiveFixture.Row(text: "a newer clip", lastUsedAt: 700_000_001)])
        store.add(ClipItem(kind: .text, text: row.text))
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.items.first?.id, row.id)
        XCTAssertGreaterThan(try XCTUnwrap(store.items.first).lastUsedAt.timeIntervalSinceReferenceDate,
                             row.lastUsedAt)
        try exportedClips(store, in: dir)
    }

    func testCaptureAtCapacityExportsNewAndPinnedRowsWithoutTheEvictedRow() throws {
        let pinned = ArchiveFixture.Row(text: "pinned oldest", lastUsedAt: 699_999_999, pinned: true)
        let oldest = ArchiveFixture.Row(text: "evict this")
        let newer = ArchiveFixture.Row(text: "retain this", lastUsedAt: 700_000_001)
        let (store, dir) = try store([pinned, oldest, newer])
        store.historyLimit = 2
        let added = ClipItem(kind: .text, text: "newest capture")
        store.add(added)
        XCTAssertEqual(Set(store.items.map(\.id)), Set([pinned.id, newer.id, added.id]))
        try exportedClips(store, in: dir)
    }

    func testDeleteThenExportWithoutRelaunchOmitsOnlyTheDeletedRow() throws {
        let (store, dir) = try store([ArchiveFixture.Row(text: "keep"), ArchiveFixture.Row(text: "delete")])
        store.delete(try XCTUnwrap(store.items.first { $0.text == "delete" }))
        XCTAssertEqual(store.items.map(\.text), ["keep"])
        try exportedClips(store, in: dir)
    }

    func testClearUnpinnedThenExportKeepsPinnedHistory() throws {
        let (store, dir) = try store([ArchiveFixture.Row(text: "pin", pinned: true),
                                      ArchiveFixture.Row(text: "clear")])
        store.clearUnpinned()
        XCTAssertEqual(store.items.map(\.text), ["pin"])
        try exportedClips(store, in: dir)
    }

    func testLoweringLimitThenExportIncludesOnlyRetainedRows() throws {
        let rows = (0..<4).map { ArchiveFixture.Row(text: "clip \($0)", lastUsedAt: 700_000_000 + Double($0)) }
        let (store, dir) = try store(rows)
        store.historyLimit = 1
        XCTAssertEqual(store.items.map(\.id), [rows[3].id])
        try exportedClips(store, in: dir)
    }

    func testFailedInsertRefusesRatherThanOmittingAnUnsavedCapture() throws {
        let (store, dir) = try store([ArchiveFixture.Row(text: "persisted")])
        try sql("CREATE TRIGGER refuse_insert BEFORE INSERT ON clips BEGIN SELECT RAISE(ABORT, 'test insert'); END;", in: dir)
        store.add(ClipItem(kind: .text, text: "unsaved capture"))
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(try databaseSnapshot(dir)["clips"]?.count, 1)
        try assertRefused(store, in: dir)
    }

    func testFailedDeleteRefusesRatherThanExportingTheOldPersistedSet() throws {
        let (store, dir) = try store([ArchiveFixture.Row(text: "one"), ArchiveFixture.Row(text: "two")])
        try sql("CREATE TRIGGER refuse_delete BEFORE DELETE ON clips BEGIN SELECT RAISE(ABORT, 'test delete'); END;", in: dir)
        store.delete(try XCTUnwrap(store.items.first))
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(try databaseSnapshot(dir)["clips"]?.count, 2)
        try assertRefused(store, in: dir)
    }

    func testFailedMetadataUpdateRefusesEvenWhenCountsAndIDsMatch() throws {
        let (store, dir) = try store([ArchiveFixture.Row(text: "pin update fails")])
        try sql("CREATE TRIGGER refuse_update BEFORE UPDATE ON clips BEGIN SELECT RAISE(ABORT, 'test update'); END;", in: dir)
        store.togglePin(try XCTUnwrap(store.items.first))
        XCTAssertTrue(try XCTUnwrap(store.items.first).pinned)
        try assertRefused(store, in: dir)
    }

    func testMalformedRowAddedAfterHealthyStartupRefuses() throws {
        let (store, dir) = try store([ArchiveFixture.Row(text: "loaded")])
        try ArchiveFixture.write([ArchiveFixture.Row(rawID: "invalid UUID", text: "unloadable")], to: dir)
        try assertRefused(store, in: dir)
    }

    func testSameCountWithDifferentPersistedIDRefuses() throws {
        let (store, dir) = try store([ArchiveFixture.Row(text: "same bytes, replaced identity")])
        try sql("UPDATE clips SET id = '\(UUID().uuidString)';", in: dir)
        XCTAssertEqual(try databaseSnapshot(dir)["clips"]?.count, store.items.count)
        try assertRefused(store, in: dir)
    }

    func testSameCountWithDuplicateNormalizedPersistedIDsRefusesWithoutTrapping() throws {
        let id = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let other = ArchiveFixture.Row(text: "other identity")
        let (store, dir) = try store([ArchiveFixture.Row(id: id, text: "first identity"), other])
        try sql("UPDATE clips SET id = '\(id.uuidString.lowercased())' WHERE id = '\(other.id.uuidString)';", in: dir)
        XCTAssertEqual(try databaseSnapshot(dir)["clips"]?.count, 2)
        try assertRefused(store, in: dir)
    }

    func testDuplicateLiveIDsAlsoRefuseWithoutTrapping() throws {
        let id = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let (store, dir) = try store([ArchiveFixture.Row(id: id, text: "upper"),
                                      ArchiveFixture.Row(rawID: id.uuidString.lowercased(), text: "lower")])
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(Set(store.items.map(\.id)).count, 1)
        try assertRefused(store, in: dir)
    }

    func testChangedFeatureRevisionOrVectorRefuses() throws {
        let (store, dir) = try store([ArchiveFixture.Row(text: "feature owner",
                                                       imageFeature: (2, [1, 2, 3]))])
        let item = try XCTUnwrap(store.items.first)
        for feature in [(revision: 3, vector: [Float(1), 2, 3]), (revision: 2, vector: [Float(1), 2, 4])] {
            item.imageFeature = feature
            try assertRefused(store, in: dir)
        }
    }

    func testFeatureBitPatternsAndNonArchivedCachesDoNotCauseFalseDivergence() throws {
        let vector: [Float] = [Float(bitPattern: 0x7fc01234), -0.0, 1]
        let (store, dir) = try store([ArchiveFixture.Row(text: "feature owner", imageFeature: (2, vector))])
        let item = try XCTUnwrap(store.items.first)
        item.embeddings = ["unsaved derived cache": ModelEmbedding(vector: [42])]
        item.imageHash = "a derived cache not in the archive"
        try exportedClips(store, in: dir)
    }

    func testAnEmptyFeatureIsOmittedJustLikeNoFeature() throws {
        let (store, dir) = try store([ArchiveFixture.Row(text: "no feature")])
        try XCTUnwrap(store.items.first).imageFeature = (revision: 99, vector: [])
        try exportedClips(store, in: dir)
    }
}
