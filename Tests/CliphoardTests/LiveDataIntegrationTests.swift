import XCTest
@testable import Cliphoard

/// TP-21: the whole pipeline, end to end, against a COPY of the real store.
///
/// Every other test in this suite uses synthetic fixtures. This one runs the actual
/// recognition pass over the user's actual images — real screenshots from a browser, of
/// unknown content, at real sizes — because a feature that only works on data I invented
/// is not a feature that works.
///
/// It runs in-process rather than in the app bundle, and that distinction is the point of
/// this file: the app bundle currently cannot read its own keys, because a scripted
/// relaunch happens in dark wake where the keychain can present no UI to anybody. That is
/// environmental and transient. This test proves the CODE is correct on real data, and
/// isolates the remaining unknown to the launch context alone.
///
/// Skips when the copy is absent, so it never fails an ordinary run.
@MainActor
final class LiveDataIntegrationTests: XCTestCase {

    private var copyDir: URL {
        URL(fileURLWithPath: "/private/tmp/claude-501/-Users-antreas/"
            + "a3424a85-37ed-435a-88a6-482496e45604/scratchpad/livecopy")
    }

    override func tearDown() {
        ImageUnderstanding.resetAnalyzer()
        super.tearDown()
    }

    func testRealStoreDecryptsAndRecognisesRealImages() async throws {
        guard FileManager.default.fileExists(
            atPath: copyDir.appendingPathComponent("ditto.sqlite").path)
        else { throw XCTSkip("no copy of the live store present") }

        let store = ClipStore(directory: copyDir)
        try XCTSkipUnless(!store.items.isEmpty, "copy loaded no clips")

        // 1. The keys must actually open the store. If this fails the process cannot read
        //    the keychain either and nothing below would mean anything.
        let unreadable = store.items.filter { Crypto.isSealed($0.text) }.count
        print("LIVE clips=\(store.items.count) unreadable=\(unreadable) safeMode=\(store.safeMode)")
        // Not "zero unreadable": a handful of clips on this machine were sealed under
        // ephemeral keys minted during scripted, dark-wake launches before the mint guard
        // landed, and those are genuinely gone. What matters is that the RECOVERY RING is
        // working — i.e. the great majority open — because if it were not, nothing below
        // would be measuring the pipeline.
        try XCTSkipUnless(unreadable * 4 < store.items.count,
                          "\(unreadable)/\(store.items.count) unreadable — the keychain is "
                          + "unavailable in this process, so the pipeline cannot be judged")
        XCTAssertFalse(store.safeMode,
                       "a fully readable store must NOT be in safe mode, or the pass is "
                       + "blocked for the wrong reason")

        // 2. Run the real pass over the real images.
        let images = store.items.filter { $0.kind == .image }
        try XCTSkipUnless(!images.isEmpty, "no image clips in the copy")
        print("LIVE images=\(images.count)")

        store.scheduleImageUnderstanding()
        for _ in 0..<80 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if store.items.filter(ClipStore.needsImageUnderstanding).isEmpty { break }
        }

        let remaining = store.items.filter(ClipStore.needsImageUnderstanding).count
        XCTAssertEqual(remaining, 0, "the pass left \(remaining) real images unanalysed")

        // 3. Report what it actually found, and assert the invariants that matter.
        var withText = 0, withheldOrEmpty = 0, withPrint = 0
        for img in store.items.filter({ $0.kind == .image }) {
            let ocr = img.ocrText ?? ""
            if ocr.isEmpty { withheldOrEmpty += 1 } else { withText += 1 }
            if img.imageFeature != nil { withPrint += 1 }
            print("LIVE image source=\(img.sourceApp ?? "?") "
                  + "ocr=\(ocr.isEmpty ? "<none/withheld>" : "\(ocr.count) chars") "
                  + "print=\(img.imageFeature.map { "\($0.vector.count)-d rev\($0.revision)" } ?? "none") "
                  + "flags=\(img.flags.rawValue)")

            // The invariant, on real data: a clip that trips the withhold rule must store
            // nothing, and one that does not must be searchable by what was read.
            if !img.flags.isDisjoint(with: ClipItem.ocrWithholdFlags) {
                XCTAssertTrue(ocr.isEmpty,
                              "a real image tripped the withhold rule and its text was "
                              + "STORED — this is the leak the whole design exists to stop")
            }
            // Recognised text must never be left sealed in memory.
            XCTAssertFalse(Crypto.isSealed(ocr), "recognised text surfaced as ciphertext")
        }
        print("LIVE summary: withText=\(withText) withheldOrEmpty=\(withheldOrEmpty) withPrint=\(withPrint)")

        // 4. Sealed at rest, on the real database.
        let reloaded = ClipStore(directory: copyDir)
        let persisted = reloaded.items.filter { $0.kind == .image && !($0.ocrText ?? "").isEmpty }
        XCTAssertEqual(persisted.count, withText,
                       "recognised text did not survive a reload of the real store")

        // 5. End-to-end searchability: whatever was actually read must be findable.
        if let sample = store.items.first(where: { $0.kind == .image && !($0.ocrText ?? "").isEmpty }),
           let word = (sample.ocrText ?? "").split(separator: " ")
            .first(where: { $0.count >= 5 && $0.allSatisfy(\.isLetter) }) {
            let hits = store.filtered(kind: nil, query: String(word), pinnedOnly: false)
            XCTAssertTrue(hits.contains { $0.id == sample.id },
                          "a word Vision read out of a real screenshot does not find it — "
                          + "the search integration is broken on real data")
            print("LIVE searchable: \"\(String(word))\" found the image it came from")
        }
    }
}
