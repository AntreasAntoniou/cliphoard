import XCTest
import AppKit
@testable import Cliphoard

/// TP-12: image payload lifecycle through the capture seam.
/// - An un-rasterisable image must NOT yield a stored-but-unpastable clip.
/// - A capturable image lays down its payload (and thumbnail) in the store dir.
/// - That payload participates correctly in the orphan sweep (asserting the
///   persist↔sweep interaction without re-proving `OrphanSweepTests`).
@MainActor
final class PayloadTests: XCTestCase {
    private var tempDir: URL!
    private var store: ClipStore!
    private var monitor: ClipboardMonitor!

    override func setUp() {
        super.setUp()
        Feedback.soundEnabled = false
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoPayloadTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = ClipStore(directory: tempDir)
        monitor = ClipboardMonitor(store: store)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        store = nil
        monitor = nil
        super.tearDown()
    }

    private func rasterisableImage() -> NSImage {
        let size = NSSize(width: 8, height: 8)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.blue.setFill()
        NSRect(origin: .zero, size: size).fill()
        img.unlockFocus()
        return img
    }

    /// An image with no usable representation (`tiffRepresentation == nil`)
    /// cannot be persisted; capture must return nil rather than minting a clip
    /// whose payload is missing — that clip would be unpastable.
    func testUnrasterisableImageIsNotCaptured() {
        let pb = FakePasteboard()
        pb.image = NSImage() // no representations → persistImage fails

        XCTAssertNil(monitor.capture(from: pb),
            "an image that can't be persisted must not produce a clip")

        // And nothing should have been written to the store directory.
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: store.storeDirectory, includingPropertiesForKeys: nil)) ?? []
        let pngs = entries.filter { $0.pathExtension.lowercased() == "png" }
        XCTAssertTrue(pngs.isEmpty, "no payload should be left behind on persist failure")
    }

    /// A capturable image writes its payload PNG (and a sidecar thumbnail) into
    /// the store directory, and the clip references that payload file.
    func testCapturableImageWritesPayloadAndThumbnail() throws {
        let pb = FakePasteboard()
        pb.image = rasterisableImage()

        let item = try XCTUnwrap(monitor.capture(from: pb))
        XCTAssertEqual(item.kind, .image)
        let payload = try XCTUnwrap(item.payloadFile)

        let fm = FileManager.default
        let payloadURL = store.storeDirectory.appendingPathComponent(payload)
        XCTAssertTrue(fm.fileExists(atPath: payloadURL.path), "payload PNG must exist on disk")

        // Sidecar thumbnail "<base>-thumb.png" written next to the original.
        let base = (payload as NSString).deletingPathExtension
        let thumbURL = store.storeDirectory.appendingPathComponent("\(base)-thumb.png")
        XCTAssertTrue(fm.fileExists(atPath: thumbURL.path), "thumbnail sidecar must exist")
    }

    /// persist ↔ sweep interaction: a payload from a *captured-and-stored* image
    /// is referenced by a live item, so the store's orphan sweep must keep it,
    /// while a stray PNG with no referencing item is removed. We assert the
    /// interaction (live payload survives, stray dies) rather than re-deriving
    /// the sweep's own rules — `OrphanSweepTests` owns those.
    func testPersistedPayloadSurvivesSweepWhileStrayIsRemoved() throws {
        // 1. Capture an image into THIS store so it becomes a live payload.
        let pb = FakePasteboard()
        pb.image = rasterisableImage()
        let item = try XCTUnwrap(monitor.capture(from: pb))
        store.add(item)
        let payload = try XCTUnwrap(item.payloadFile)

        // 2. Drop a stray PNG that no live item references.
        let stray = store.storeDirectory.appendingPathComponent("stray-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: stray)

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: store.storeDirectory.appendingPathComponent(payload).path))
        XCTAssertTrue(fm.fileExists(atPath: stray.path))

        // 3. Reopen the store on the same directory: init runs the orphan sweep.
        store = nil
        let reopened = ClipStore(directory: tempDir)

        // The live payload (referenced by the migrated/loaded image clip) survives;
        // the stray is swept.
        XCTAssertTrue(reopened.items.contains { $0.payloadFile == payload },
            "the captured image clip should persist across reopen")
        XCTAssertTrue(fm.fileExists(atPath: reopened.storeDirectory.appendingPathComponent(payload).path),
            "a referenced payload must survive the sweep")
        XCTAssertFalse(fm.fileExists(atPath: stray.path),
            "an unreferenced stray PNG must be swept on init")
    }
}
