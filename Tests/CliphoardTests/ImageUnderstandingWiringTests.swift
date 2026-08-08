import XCTest
@testable import Cliphoard

/// TP-17: the assignment point.
///
/// Recognition converts inert pixels into indexed, embedded, substring-searchable text.
/// That is a categorical change in exposure, not an incremental one — a screenshot of a
/// password manager is unreadable today and findable tomorrow. Everything here exists to
/// pin the ordering that keeps it safe: scan → union → decide → assign → purge → persist
/// → index, with no suspension between the scan and the assignment.
///
/// All of it runs through the `ImageUnderstanding.analyze` seam, so no test depends on
/// what Apple's recognizer happens to return this OS release.
@MainActor
final class ImageUnderstandingWiringTests: XCTestCase {

    override func tearDown() {
        ImageUnderstanding.resetAnalyzer()
        super.tearDown()
    }

    private func tempStore() -> ClipStore {
        ClipStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iu-\(UUID().uuidString)"))
    }

    private func imageClip(source: String? = nil) -> ClipItem {
        let item = ClipItem(kind: .image, text: "Image 1920×1080")
        item.payloadFile = "\(UUID().uuidString).png"
        item.sourceApp = source
        return item
    }

    private func result(_ text: String, print: [Float] = [1, 0, 0]) -> ImageUnderstanding.Result {
        ImageUnderstanding.Result(text: text, featurePrint: print, featurePrintRevision: 2)
    }

    // MARK: - The core safety property

    /// A recognised credential must be withheld, its derived data purged, and it must be
    /// invisible to EVERY search path — including the substring paths, which carry no
    /// veto of their own. That last part is the whole reason the withhold marker is `""`
    /// rather than the text with a flag beside it.
    func testRecognisedSecretIsWithheldPurgedAndUnsearchable() {
        let store = tempStore()
        let item = imageClip()
        store.add(item)

        store.applyImageUnderstanding(result("AKIA" + "IOSFODNN7EXAMPLE"), to: item)

        XCTAssertTrue(item.flags.contains(.secret), "the detector must fire on the recognised text")
        XCTAssertEqual(item.ocrText, "", "a withheld result stores the empty marker, never the text")
        XCTAssertTrue(item.embeddings.isEmpty, "vectors must be purged once the clip becomes vetoed")
        XCTAssertNil(item.imageFeature, "the perceptual print must be purged too")

        // The three veto-free substring paths all read `searchText`, which falls back to
        // the caption when the marker is empty. So none of them can see it.
        XCTAssertEqual(SemanticRanker.searchText(item), "Image 1920×1080")
        XCTAssertFalse(SemanticRanker.searchText(item).lowercased().contains("akia"))
        XCTAssertTrue(store.filtered(kind: nil, query: "AKIA" + "IOSFODNN7EXAMPLE", pinnedOnly: false).isEmpty,
                      "exact substring search must not surface a withheld screenshot")
    }

    /// The lower-confidence bits withhold WITHOUT vetoing: nothing is destroyed, the clip
    /// keeps whatever it already had. Withholding and vetoing are different actions and
    /// this is what keeps a false positive cheap.
    func testEntropyWithholdsButDoesNotDestroy() {
        let store = tempStore()
        let item = imageClip()
        store.add(item)
        let before = item.embeddings

        // A long high-entropy token: trips the entropy heuristic, not the exact signatures.
        store.applyImageUnderstanding(result("xQ7fLm2ZpR9vK4bN8sT1wY6cH3jD5gA0eU"), to: item)

        XCTAssertEqual(item.ocrText, "", "an entropy hit must withhold the text")
        XCTAssertFalse(item.isIndexVetoed,
                       "entropy must NOT veto — it is the low-confidence tier and may not "
                       + "drive a destructive action")
        XCTAssertEqual(item.embeddings.count, before.count,
                       "withholding destroys nothing: pre-existing vectors must survive")
    }

    // MARK: - The idiom that would silently bypass everything

    /// `add` assigns flags (`item.flags = verdict.flags`). Copying that idiom here would
    /// clear `.quarantined` from a password-manager screenshot the moment recognition
    /// finished — a total veto bypass, in code that reads perfectly correct.
    func testFlagsAreUnionedNotReplaced() {
        let store = tempStore()
        let item = imageClip()
        store.add(item)
        item.flags.insert(.quarantined)

        store.applyImageUnderstanding(result("perfectly ordinary caption text"), to: item)

        XCTAssertTrue(item.flags.contains(.quarantined),
                      "the origin quarantine was CLEARED by recognition — flags must be "
                      + "unioned, never assigned")
        XCTAssertTrue(item.isIndexVetoed)
        XCTAssertEqual(item.ocrText, "", "a quarantined clip stores nothing")
    }

    // MARK: - The pass

    /// Cheapest possible protection: an already-vetoed clip's pixels are never decoded.
    func testQuarantinedClipIsNeverHandedToTheAnalyzer() async {
        let store = tempStore()
        let item = imageClip(source: "1Password")
        store.add(item)
        XCTAssertTrue(item.isIndexVetoed, "precondition: a sensitive source must quarantine")

        var calls = 0
        ImageUnderstanding.analyze = { _ in calls += 1; return self.result("should never run") }
        store.scheduleImageUnderstanding()
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(calls, 0, "a vetoed clip must not be analysed at all")
        XCTAssertEqual(item.ocrText, "", "it must still be MARKED analysed, or it retries forever")
    }

    /// NOT TESTED BEHAVIOURALLY, and worth saying so rather than leaving a silent gap:
    /// safe mode forbids bulk rewrites of existing rows, and this pass is exactly that.
    /// `safeMode` is `private(set)` and is only ever set inside `init` from the ratio of
    /// unreadable clips, so forcing it from a unit test would mean widening the API purely
    /// for the test — which is the kind of change that makes the production type weaker to
    /// make a test easier.
    ///
    /// The protection is instead STRUCTURAL and checked here by source: the guard exists,
    /// and the `init` call site sits after the safe-mode early return, so in safe mode the
    /// scheduling line is never reached at all. Two independent reasons, neither relying
    /// on a test remembering to assert it.
    func testSafeModeProtectionIsStructural() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Cliphoard/Clipboard/ClipStore.swift"),
            encoding: .utf8)
        let lines = source.components(separatedBy: .newlines)

        XCTAssertTrue(source.contains("guard !safeMode, Self.imageUnderstandingEnabled"),
                      "scheduleImageUnderstanding lost its safe-mode guard")

        guard let earlyReturn = lines.firstIndex(where: { $0.contains("rebuildUserTagIndex()") }),
              let scheduleInInit = lines.firstIndex(where: { $0.contains("scheduleImageUnderstanding()") })
        else { return XCTFail("could not locate the init ordering") }
        XCTAssertGreaterThan(scheduleInInit, earlyReturn,
                             "the schedule call moved ABOVE the safe-mode early return, so a "
                             + "store in safe mode would now start rewriting rows")
    }

    func testDisabledSettingPerformsNoRecognition() async {
        let store = tempStore()
        store.add(imageClip())
        let previous = ClipStore.imageUnderstandingEnabled
        defer { ClipStore.imageUnderstandingEnabled = previous }
        ClipStore.imageUnderstandingEnabled = false

        var calls = 0
        ImageUnderstanding.analyze = { _ in calls += 1; return self.result("x") }
        store.scheduleImageUnderstanding()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(calls, 0, "the opt-out must actually stop the pass")
    }

    /// The selection predicate is the whole backfill design: the column is its own marker,
    /// so an analysed clip is never revisited and an unanalysed one always is.
    func testSelectionPredicateIsTheColumnItself() {
        let never = imageClip()
        XCTAssertTrue(ClipStore.needsImageUnderstanding(never), "nil means never analysed")

        let withheld = imageClip(); withheld.ocrText = ""
        XCTAssertFalse(ClipStore.needsImageUnderstanding(withheld),
                       "\"\" means analysed — revisiting it would retry a withheld secret forever")

        let analysed = imageClip(); analysed.ocrText = "some text"
        XCTAssertFalse(ClipStore.needsImageUnderstanding(analysed))

        let text = ClipItem(kind: .text, text: "not an image")
        XCTAssertFalse(ClipStore.needsImageUnderstanding(text))

        let noPayload = ClipItem(kind: .image, text: "Image")
        XCTAssertFalse(ClipStore.needsImageUnderstanding(noPayload), "nothing to decode")
    }

    // MARK: - The happy path

    func testCleanRecognitionBecomesSearchableAndKeepsItsPrint() {
        let store = tempStore()
        let item = imageClip()
        store.add(item)

        store.applyImageUnderstanding(result("validation accuracy by epoch"), to: item)

        XCTAssertEqual(item.ocrText, "validation accuracy by epoch")
        XCTAssertEqual(SemanticRanker.searchText(item), "validation accuracy by epoch",
                       "clean recognised text must reach the search pipeline")
        XCTAssertEqual(item.imageFeature?.vector, [1, 0, 0])
        XCTAssertEqual(item.imageFeature?.revision, 2)
        XCTAssertFalse(store.filtered(kind: nil, query: "epoch", pinnedOnly: false).isEmpty,
                       "substring search must now find the image by its recognised text")
    }

    /// Without this the panel shows stale results until the next copy, and the whole
    /// feature reads as broken.
    func testApplyingAResultBumpsTheRevisionCounter() {
        let store = tempStore()
        let item = imageClip()
        store.add(item)
        let before = store.imageUnderstandingRevision

        store.applyImageUnderstanding(result("anything at all"), to: item)

        XCTAssertEqual(store.imageUnderstandingRevision, before + 1,
                       "results landing must be observable, or the UI never refreshes")
    }
}
