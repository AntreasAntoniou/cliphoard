import XCTest
@testable import Cliphoard

/// Athena's required guards for the tag-id migration — the highest-severity
/// defect in Wave 4, and (per her review) a corruption path that was ALREADY
/// live before this wave: switching the overlay basket has always renumbered the
/// ids, and the reclassify that repairs them is an async task that, before this
/// change, had no completion marker. Quitting mid-pass left clips permanently
/// carrying a mix of old and new ids with nothing able to detect it.
@MainActor
final class TagVocabularyMigrationTests: XCTestCase {

    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("CliphoardVocab-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    override func setUp() {
        super.setUp()
        TagBaskets.overlayID = nil
        TagBasket.persistedVocabulary = nil
    }
    override func tearDown() {
        TagBasket.persistedVocabulary = nil
        TagBaskets.overlayID = nil
        super.tearDown()
    }

    /// Ids minted against a DIFFERENT vocabulary are DISCARDED, never reinterpreted.
    ///
    /// This is the whole point: id 12 meant "personal" under the old 48-tag
    /// General and would silently mean "password" under a 16-tag one. Since half
    /// the retired vocabulary has no successor at all, a remap table could only
    /// invent meaning — so the ids go, and are recomputed from the cached vector.
    func testStaleTagIDsAreDiscardedNotRemapped() {
        let dir = tempDir()
        let sig = EmbedderProvider.active.signature
        let db = Database(path: dir.appendingPathComponent("ditto.sqlite").path)
        let item = ClipItem(kind: .text, text: "a note about something personal")
        XCTAssertNotNil(db)
        _ = db?.insert(item)
        // Ids minted against a vocabulary that no longer exists: 12 meant
        // "personal"; under a smaller General it would resolve to another word,
        // and 27/40 fall off the end entirely.
        _ = db?.upsertEmbedding(clipID: item.id, model: sig, embedding: ModelEmbedding(
            vector: HashingEmbedder().embed("a note about something personal"),
            tags: [0, 12, 27, 40]))
        TagBasket.persistedVocabulary = "general:48:deadbeef"

        let reloaded = ClipStore(directory: dir)
        XCTAssertFalse(reloaded.items.isEmpty, "precondition: the clip was stored")
        for clip in reloaded.items {
            let tags = clip.embeddings[sig]?.tags ?? []
            XCTAssertTrue(tags.allSatisfy { $0 < TagSpace.count },
                          "no id may survive that points outside the current vocabulary")
        }
    }

    /// A MATCHING stamp must leave everything alone — the migration is
    /// conditional, not an unconditional wipe on every launch.
    func testAMatchingStampSkipsTheMigration() {
        let dir = tempDir()
        _ = ClipStore(directory: dir)                       // establishes the stamp
        let stamped = TagBasket.persistedVocabulary
        XCTAssertEqual(stamped, TagBaskets.active.fingerprint,
                       "a completed pass records the vocabulary it produced")

        _ = ClipStore(directory: dir)                       // second launch
        XCTAssertEqual(TagBasket.persistedVocabulary, stamped,
                       "an unchanged vocabulary must not re-run the migration")
    }

    /// The fingerprint must actually TRACK the vocabulary, or the marker is
    /// decorative and the migration never fires when it must.
    func testFingerprintDistinguishesVocabularies() {
        let bare = TagBaskets.active.fingerprint
        TagBaskets.overlayID = "dev"
        let dev = TagBaskets.active.fingerprint
        XCTAssertNotEqual(bare, dev, "switching the overlay must change the fingerprint")
        TagBaskets.overlayID = nil
        XCTAssertEqual(TagBaskets.active.fingerprint, bare)
    }

    /// The regression fence for spec principle 3. `ClipFlags` already forbids a
    /// positive safety label; the VOCABULARY must too. Before Wave 4, General's
    /// Sensitivity axis emitted `public` on 52 of 202 real clips — a positive
    /// safety claim, on a 0.04 margin, rendered in the inspector.
    func testNoBasketVocabularyCarriesAPositiveSafetyLabel() {
        let banned: Set<String> = ["public", "internal", "aggregated", "safe", "clean", "benign"]
        for basket in TagBaskets.builtIn {
            let offending = Set(basket.tags).intersection(banned)
            XCTAssertTrue(offending.isEmpty,
                          "\(basket.id) claims safety it cannot prove: \(offending.sorted())")
        }
    }

    /// General must produce no model-guessed labels at all — an empty vocabulary
    /// is the only configuration whose correctness needs no corpus to verify.
    func testGeneralEmitsNoModelDerivedTags() {
        XCTAssertTrue(TagBaskets.general.tags.isEmpty)
        XCTAssertTrue(TagSpace.topicalRange.isEmpty)
        let e = HashingEmbedder()
        for text in ["https://example.com/a", "SELECT 1 FROM t",
                     "colorectal cancer screening", "hello there"] {
            XCTAssertTrue(ClipIndexer.tags(for: e.embed(text), embedder: e).isEmpty,
                          "General must not guess a label for: \(text)")
        }
    }
}
