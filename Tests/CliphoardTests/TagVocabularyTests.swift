import XCTest
@testable import Cliphoard

/// Guards on the tag VOCABULARY itself.
///
/// The migration these once guarded is gone: tag ids are no longer stored, so
/// there is nothing to migrate and no marker that could claim a pass ran when it
/// did not. What survives here are the properties that outlive that mechanism —
/// the fingerprint still keys the tag-vector cache, and the vocabulary must never
/// carry a positive safety label.
@MainActor
final class TagVocabularyTests: XCTestCase {

    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("CliphoardVocab-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    override func setUp() { super.setUp(); TagBaskets.overlayID = nil }
    override func tearDown() { TagBaskets.overlayID = nil; super.tearDown() }



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
