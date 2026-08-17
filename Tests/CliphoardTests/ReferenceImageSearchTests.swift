import XCTest
import AppKit
@testable import Cliphoard

/// Searching by a picture from disk rather than by typed words.
///
/// The property that actually matters is RANKING, not thresholds: the user picked the file,
/// so they want the closest clips to it even when nothing is a strong match. That is why
/// `imagesSimilar(toReferenceImage:)` applies no relevance floor while the text path does —
/// a floor tuned for free text would return nothing for a perfectly reasonable reference,
/// and "no results" for a picture you are looking straight at reads as broken.
///
/// These tests run only where the CLIP towers are installed. That is a real limitation and
/// it is declared rather than hidden: on a machine without the model the whole feature is
/// absent by design (`clipEmbedder` is nil and the UI control does not appear), so there is
/// nothing to assert about behaviour — and asserting "returns empty" would pass equally well
/// against a build where the feature was silently broken.
@MainActor
final class ReferenceImageSearchTests: XCTestCase {

    private func tempStore() -> ClipStore {
        ClipStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoRef-\(UUID().uuidString)"))
    }

    private func png(_ colour: NSColor, size: CGFloat = 64) -> Data {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        colour.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            return Data()
        }
        return data
    }

    /// The embedder turns real file bytes into a vector of the expected width. This is the
    /// seam the whole feature rests on — everything else is ranking arithmetic over it.
    func testAReferenceImageFromDiskEmbedsToTheJointSpace() throws {
        let store = tempStore()
        guard let clip = store.clipEmbedder else {
            throw XCTSkip("CLIP towers are not installed in this build, so there is no "
                          + "reference-image feature to exercise. Not a pass.")
        }
        let vector = clip.embed(imageData: png(.systemBlue))
        XCTAssertEqual(vector.count, CLIPEmbedder.dimension,
                       "a reference image must land in the same 192-d space as the stored "
                       + "clip vectors, or the comparison is between different spaces")
        // L2 is baked into the graph, so the vector must already be unit length — if it is
        // not, `similarity` is no longer a cosine and every score is silently wrong.
        let norm = vector.reduce(0) { $0 + $1 * $1 }
        XCTAssertEqual(norm, 1.0, accuracy: 0.01,
                       "the CoreML graph bakes in the L2 norm; an un-normalised vector means "
                       + "similarity() is a dot product of unnormalised vectors, not a cosine")
    }

    /// Two DIFFERENT pictures must not embed to the same vector. Guards the failure mode
    /// where preprocessing collapses everything — which is exactly what the uncentred text
    /// space did, and is invisible unless something asserts separation.
    func testDifferentPicturesEmbedDifferently() throws {
        let store = tempStore()
        guard let clip = store.clipEmbedder else {
            throw XCTSkip("CLIP towers are not installed in this build. Not a pass.")
        }
        let a = clip.embed(imageData: png(.systemBlue))
        let b = clip.embed(imageData: png(.systemRed))
        guard !a.isEmpty, !b.isEmpty else { return XCTFail("both fixtures must embed") }
        XCTAssertLessThan(CLIPEmbedder.similarity(a, b), 0.999,
                          "two visibly different pictures produced effectively identical "
                          + "vectors — the vision tower or its preprocessing has collapsed")
    }

    /// Unreadable bytes yield NO vector rather than a zero one. A zero vector scores 0
    /// against everything, which is indistinguishable from "nothing matched" and would be
    /// cached as a valid answer.
    func testGarbageBytesYieldNoVectorRatherThanZeros() throws {
        let store = tempStore()
        guard let clip = store.clipEmbedder else {
            throw XCTSkip("CLIP towers are not installed in this build. Not a pass.")
        }
        XCTAssertTrue(clip.embed(imageData: Data(repeating: 0x7F, count: 512)).isEmpty,
                      "bytes that are not an image must return [] — a zero vector would be "
                      + "cached as a valid embedding and never retried")
    }

    /// An empty or single-image store returns nothing rather than crashing: centring needs
    /// at least two vectors to have a meaningful mean, and centring one vector by itself
    /// yields the zero vector.
    func testTooFewImagesToCentreReturnsEmptyRatherThanCrashing() throws {
        let store = tempStore()
        try XCTSkipIf(store.safeMode, "frozen store here")
        XCTAssertTrue(store.imagesSimilar(toReferenceImage: png(.systemGreen)).isEmpty,
                      "with fewer than two indexed images there is no corpus mean to centre "
                      + "by, and the honest answer is no results")
    }
}
