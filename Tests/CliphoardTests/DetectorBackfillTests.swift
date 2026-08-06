import XCTest
@testable import Cliphoard

/// Two halves of the "clips that predate the detectors" gap (design §3.11, §5, §7):
///
/// 1. `ClipStore`'s one-time detector BACKFILL — clips captured before
///    `Detectors` existed were embedded with no verdict at all, so a secret
///    already in history is still a live row in the CoreML index. The backfill
///    computes their flags/shape and PURGES the vectors of anything that turns
///    out to be `.secret`/`.quarantined`.
/// 2. The `--analyze-tags` topics gate — the offline validation §3.11 requires
///    before Coarse Topic may ship, including the fact that it degrades to a
///    message (and exit 0) while the bucket library does not exist.
final class DetectorBackfillTests: XCTestCase {
    /// A PEM header is decisive on its own (§3.1) — no key material needed, so
    /// this fixture contains nothing that resembles a real secret.
    private static let pemKey = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIBOgIBAAJBAK
        -----END RSA PRIVATE KEY-----
        """

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoBackfill-\(UUID().uuidString)")
    }

    private func dbPath(in dir: URL) -> String {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ditto.sqlite").path
    }

    /// The pass is gated on a process-wide UserDefaults flag, and the whole test
    /// bundle shares one defaults domain — so every test here starts from "never
    /// run" and hands the suite back the same way.
    @MainActor
    private func resetBackfillGate() {
        UserDefaults.standard.removeObject(forKey: ClipStore.detectorBackfillDefaultsKey)
    }

    /// A clip as it would look on disk BEFORE the detectors shipped: a verdict
    /// that was never computed, and a vector that was.
    private func seedUnscanned(_ db: Database, text: String, sourceApp: String? = nil,
                               model: String = "backfill-test-sig") -> ClipItem {
        let item = ClipItem(kind: .text, text: text)
        item.sourceApp = sourceApp
        item.embeddings[model] = ModelEmbedding(vector: [1, 0, 0], tags: [3])
        XCTAssertTrue(db.insert(item))
        return item
    }

    // MARK: Backfill

    /// The core claim: an unscanned clip gets its verdict, and a clip that was
    /// already scanned is not touched (its stored verdict is authoritative, so a
    /// re-scan could only overwrite a newer build's answer with an older one).
    @MainActor
    func testBackfillScoresUnscannedClipsAndLeavesScannedOnesAlone() throws {
        resetBackfillGate()
        defer { resetBackfillGate() }
        let dir = tempDir()

        let seedDB = try XCTUnwrap(Database(path: dbPath(in: dir)))
        let unscanned = seedUnscanned(seedDB, text: "{\"user\": \"ada\", \"active\": true}")
        // Already scanned: a verdict is on the row, so the pass must skip it —
        // even though this text would produce a different one if re-scanned.
        let scanned = ClipItem(kind: .text, text: Self.pemKey)
        scanned.flags = [.pii]
        scanned.embeddings["backfill-test-sig"] = ModelEmbedding(vector: [0, 1, 0], tags: [4])
        XCTAssertTrue(seedDB.insert(scanned))

        XCTAssertTrue(ClipStore.needsDetectorBackfill(unscanned))
        XCTAssertFalse(ClipStore.needsDetectorBackfill(scanned))

        let store = ClipStore(directory: dir)
        let loadedUnscanned = try XCTUnwrap(store.items.first { $0.id == unscanned.id })
        let loadedScanned = try XCTUnwrap(store.items.first { $0.id == scanned.id })

        XCTAssertEqual(loadedUnscanned.shape, "json", "the unscanned clip is scanned now")
        XCTAssertEqual(loadedScanned.flags, [.pii], "an already-scanned verdict is left exactly as stored")
        XCTAssertFalse(loadedScanned.flags.contains(.secret), "…so its text is NOT re-scanned")
        XCTAssertFalse(loadedScanned.embeddings.isEmpty, "and nothing purges a clip the pass skipped")

        // And it is persisted, not just in memory.
        let reopened = try XCTUnwrap(Database(path: dbPath(in: dir)))
        let persisted = try XCTUnwrap(reopened.loadAll().first { $0.id == unscanned.id })
        XCTAssertEqual(persisted.shape, "json")
    }

    /// The reason the pass exists: a secret that was indexed before any detector
    /// existed must lose its vector from memory AND from the database — flagging
    /// it while leaving it searchable would badge a leak instead of closing it.
    @MainActor
    func testBackfilledSecretHasItsVectorsPurgedFromMemoryAndDisk() throws {
        resetBackfillGate()
        defer { resetBackfillGate() }
        let dir = tempDir()

        let seedDB = try XCTUnwrap(Database(path: dbPath(in: dir)))
        let secret = seedUnscanned(seedDB, text: Self.pemKey)
        let quarantined = seedUnscanned(seedDB, text: "correct horse battery staple",
                                        sourceApp: "1Password")
        let benign = seedUnscanned(seedDB, text: "meeting notes from the standup")
        XCTAssertFalse(try XCTUnwrap(seedDB.loadAll().first { $0.id == secret.id }).embeddings.isEmpty,
                       "precondition: the secret really was indexed before the detectors existed")

        let store = ClipStore(directory: dir)
        let loadedSecret = try XCTUnwrap(store.items.first { $0.id == secret.id })
        let loadedQuarantined = try XCTUnwrap(store.items.first { $0.id == quarantined.id })
        let loadedBenign = try XCTUnwrap(store.items.first { $0.id == benign.id })

        XCTAssertTrue(loadedSecret.flags.contains(.secret))
        XCTAssertTrue(loadedSecret.embeddings.isEmpty, "purged from memory")
        XCTAssertTrue(loadedQuarantined.flags.contains(.quarantined), "origin alone is enough")
        XCTAssertTrue(loadedQuarantined.embeddings.isEmpty)
        XCTAssertFalse(loadedBenign.embeddings.isEmpty, "an unflagged clip keeps its vector")

        let reopened = try XCTUnwrap(Database(path: dbPath(in: dir)))
        let rows = reopened.loadAll()
        XCTAssertTrue(try XCTUnwrap(rows.first { $0.id == secret.id }).embeddings.isEmpty,
                      "and purged from disk — this is the row that was still in the index")
        XCTAssertTrue(try XCTUnwrap(rows.first { $0.id == quarantined.id }).embeddings.isEmpty)
        XCTAssertFalse(try XCTUnwrap(rows.first { $0.id == benign.id }).embeddings.isEmpty)
        XCTAssertTrue(try XCTUnwrap(rows.first { $0.id == secret.id }).flags.contains(.secret),
                      "the verdict itself is persisted")
    }

    /// Once-only: after a completed pass the gate is set, so a later launch does
    /// no work at all — a row that appears unscanned afterwards is left alone.
    @MainActor
    func testBackfillRunsOnlyOnce() throws {
        resetBackfillGate()
        defer { resetBackfillGate() }
        let dir = tempDir()

        let seedDB = try XCTUnwrap(Database(path: dbPath(in: dir)))
        _ = seedUnscanned(seedDB, text: "{\"first\": true}")
        XCTAssertFalse(UserDefaults.standard.bool(forKey: ClipStore.detectorBackfillDefaultsKey))

        _ = ClipStore(directory: dir)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: ClipStore.detectorBackfillDefaultsKey),
                      "a completed pass marks itself done")

        // A second unscanned row, then a second launch: the gate is closed, so
        // the pass must not run again.
        let laterDB = try XCTUnwrap(Database(path: dbPath(in: dir)))
        let later = seedUnscanned(laterDB, text: "{\"second\": true}")
        let second = ClipStore(directory: dir)
        let loadedLater = try XCTUnwrap(second.items.first { $0.id == later.id })
        XCTAssertNil(loadedLater.shape, "the pass did not run a second time")
        XCTAssertEqual(loadedLater.flags, [])
    }

    // MARK: Topics gate (§3.11)

    /// Coarse Topic is probationary and lands separately: with no bucket library
    /// registered the gate reports that there is nothing to validate rather than
    /// failing. (`runTopicsAudit` turns this case into an exit 0.)
    @MainActor
    func testTopicsGateDegradesGracefullyWithoutABucketLibrary() {
        let saved = TopicBucketSource.provider
        defer { TopicBucketSource.provider = saved }
        TopicBucketSource.provider = nil

        guard case .unavailable(let message) = TagAudit.topicsGate(embedder: HashingEmbedder()) else {
            return XCTFail("with no provider the gate must report unavailable, not score")
        }
        XCTAssertTrue(message.contains("§3.11"), "the message points at the spec section")
        XCTAssertTrue(message.contains("Exiting 0"), "an absent gate is not a failed gate")

        // An empty library counts as absent too — there is nothing to validate.
        TopicBucketSource.provider = { _ in [] }
        guard case .unavailable = TagAudit.topicsGate(embedder: HashingEmbedder()) else {
            return XCTFail("an empty bucket library must not be treated as a scored gate")
        }
    }

    /// With a library installed the gate scores it: a separable bucket PASSes, a
    /// bucket that near-ties with its neighbour FAILs, and a bucket nothing lands
    /// in FAILs for want of evidence.
    @MainActor
    func testTopicsGatePassesSeparableBucketsAndFailsCoinFlips() throws {
        let saved = TopicBucketSource.provider
        defer { TopicBucketSource.provider = saved }
        let buckets = [
            TopicBucketProbe(name: "tech-code", centroid: [1, 0, 0]),
            TopicBucketProbe(name: "money-finance", centroid: [0, 1, 0]),
            TopicBucketProbe(name: "health-medical", centroid: [0, 0, 1]),
        ]
        TopicBucketSource.provider = { _ in buckets }
        guard case .available(let found) = TagAudit.topicsGate(embedder: HashingEmbedder()) else {
            return XCTFail("an installed library must be scored")
        }
        XCTAssertEqual(found.count, 3)

        // 5 clips squarely on tech-code, 5 that split almost evenly between
        // money-finance and tech-code (margin ≈ 0.01), nothing medical.
        let nearTie = HashingEmbedder.normalize([0.70, 0.71, 0])
        let vectors = Array(repeating: [Float]([1, 0, 0]), count: 5)
            + Array(repeating: nearTie, count: 5)
        let config = TagAudit.TopicsGateConfig(floor: 0.2, marginThreshold: 0.06, minSamples: 4)
        let report = TagAudit.scoreTopics(vectors: vectors, buckets: found, config: config)

        let byName = Dictionary(uniqueKeysWithValues: report.verdicts.map { ($0.name, $0) })
        let tech = try XCTUnwrap(byName["tech-code"])
        XCTAssertEqual(tech.assigned, 5)
        XCTAssertTrue(tech.passed, "a bucket that owns its clips outright clears the gate")
        let money = try XCTUnwrap(byName["money-finance"])
        XCTAssertEqual(money.assigned, 5)
        XCTAssertFalse(money.passed, "a coin-flip against its neighbour must be dropped")
        XCTAssertLessThan(money.meanMargin, config.marginThreshold)
        let health = try XCTUnwrap(byName["health-medical"])
        XCTAssertEqual(health.assigned, 0)
        XCTAssertFalse(health.passed, "an unvalidated bucket fails — the gate clears on evidence only")
        XCTAssertEqual(report.scored, 10)
        XCTAssertEqual(report.unassigned, 0)

        XCTAssertTrue(report.recommendation.contains("tech-code"))
        XCTAssertTrue(report.recommendation.contains("DROP BEFORE SHIP"))
        let table = TagAudit.topicsTable(report)
        XCTAssertTrue(table.contains("PASS"))
        XCTAssertTrue(table.contains("FAIL"))

        // Raise the floor above every top-1 and nothing is assigned at all —
        // blank is a valid result (§3.11), not a bucket.
        let strict = TagAudit.scoreTopics(vectors: vectors, buckets: found,
                                          config: TagAudit.TopicsGateConfig(floor: 0.99, marginThreshold: 0.06,
                                                                            minSamples: 4))
        XCTAssertEqual(strict.unassigned, 5, "only the exact-match clips clear a 0.99 floor")
        XCTAssertEqual(strict.passing.map(\.name), ["tech-code"])
        XCTAssertTrue(strict.recommendation.contains("ship"))
    }
}
