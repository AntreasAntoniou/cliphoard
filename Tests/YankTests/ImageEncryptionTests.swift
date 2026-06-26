import XCTest
import AppKit
import CryptoKit
@testable import Yank

/// T3: Image payloads (and their thumbnails) are encrypted at rest with the
/// `enc1:` AES-GCM seal. The PLAINTEXT png is hashed BEFORE sealing, so T2's
/// content-addressed `<hash>.png` dedup is unchanged. New captures are sealed by
/// ClipboardMonitor.persistImage; pre-encryption PNGs are upgraded once by
/// ClipStore.encryptImagePayloadsIfNeeded() (driven here through ClipStore.init).
@MainActor
final class ImageEncryptionTests: XCTestCase {
    private var tempDir: URL!
    private var store: ClipStore!
    private var monitor: ClipboardMonitor!
    private static let migrationFlag = "imagesEncryptedV1"

    override func setUp() {
        super.setUp()
        Feedback.soundEnabled = false
        // Clear the one-time migration gate so the at-rest upgrade actually runs
        // for each ClipStore we construct in this suite.
        UserDefaults.standard.removeObject(forKey: Self.migrationFlag)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoImageEncTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = ClipStore(directory: tempDir)
        monitor = ClipboardMonitor(store: store)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        UserDefaults.standard.removeObject(forKey: Self.migrationFlag)
        store = nil
        monitor = nil
        super.tearDown()
    }

    /// A rasterisable image so `monitor.capture` drives the real persistImage seal
    /// path (tiff → png → seal → write).
    private func rasterisableImage(blue: CGFloat = 1.0) -> NSImage {
        let size = NSSize(width: 8, height: 8)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor(red: 0, green: 0, blue: blue, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        img.unlockFocus()
        return img
    }

    private func capturedImageItem(blue: CGFloat = 1.0) throws -> ClipItem {
        let pb = FakePasteboard()
        pb.image = rasterisableImage(blue: blue)
        return try XCTUnwrap(monitor.capture(from: pb),
                             "a rasterisable image must be captured")
    }

    // MARK: Helpers

    /// Deterministic solid-colour PNG so identical inputs => identical bytes,
    /// matching T2's dedup fixture.
    private func pngData(red: CGFloat, width: Int = 4, height: Int = 4) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(red: red, green: 0, blue: 0, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Pre-seed a plaintext `<hash>.png` + `<hash>-thumb.png` pair on disk AND a
    /// referencing image row in the store's DB, as a pre-encryption build would
    /// have left them. The DB row matters: ClipStore.init sweeps orphan payloads,
    /// so a payload with no referencing clip would be deleted before the
    /// encryption pass runs. Returns the content hash. Leaves the migration gate
    /// CLEARED so the next `ClipStore(directory:)` runs the upgrade pass.
    @discardableResult
    private func seedReferencedPlaintextPayload(red: CGFloat) -> String {
        let png = pngData(red: red)
        let hash = sha256Hex(png)
        // Persist a referencing row via a throwaway store (writes to the shared DB).
        let seeder = ClipStore(directory: tempDir)
        let item = ClipItem(kind: .image, text: "Image")
        item.imageHash = hash
        item.payloadFile = "\(hash).png"
        seeder.add(item)
        // Now lay down the PLAINTEXT payload + thumbnail (overwriting anything the
        // store may have left), simulating a pre-encryption on-disk state.
        try! png.write(to: tempDir.appendingPathComponent("\(hash).png"))
        try! png.write(to: tempDir.appendingPathComponent("\(hash)-thumb.png"))
        // Re-open the migration gate so the pass actually runs next init.
        UserDefaults.standard.removeObject(forKey: Self.migrationFlag)
        return hash
    }

    private func isPNGHeader(_ data: Data) -> Bool {
        // PNG magic: 89 50 4E 47 0D 0A 1A 0A.
        let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        return data.count >= 8 && Array(data.prefix(8)) == magic
    }

    // MARK: Tests

    /// (1) After the at-rest upgrade, both `<hash>.png` and `<hash>-thumb.png`
    /// begin with the `enc1:` marker and are NOT a valid PNG header.
    func testPayloadAndThumbAreSealedNotPlaintextPNG() {
        let hash = seedReferencedPlaintextPayload(red: 1.0)
        _ = ClipStore(directory: tempDir)   // runs encryptImagePayloadsIfNeeded()

        for name in ["\(hash).png", "\(hash)-thumb.png"] {
            let url = tempDir.appendingPathComponent(name)
            let raw = try! Data(contentsOf: url)
            XCTAssertTrue(Crypto.isSealed(raw), "\(name) must carry the enc1: marker")
            XCTAssertFalse(isPNGHeader(raw), "\(name) must NOT start with PNG magic at rest")
        }
    }

    /// (2) Each sealed file round-trips via Crypto.open to a decodable NSImage.
    func testSealedPayloadAndThumbRoundTripToImage() {
        let hash = seedReferencedPlaintextPayload(red: 0.5)
        _ = ClipStore(directory: tempDir)

        for name in ["\(hash).png", "\(hash)-thumb.png"] {
            let url = tempDir.appendingPathComponent(name)
            let raw = try! Data(contentsOf: url)
            guard let opened = Crypto.open(raw) else {
                return XCTFail("\(name) failed to decrypt via Crypto.open")
            }
            XCTAssertTrue(isPNGHeader(opened), "decrypted \(name) must be a valid PNG")
            XCTAssertNotNil(NSImage(data: opened), "decrypted \(name) must decode to an NSImage")
        }
    }

    /// (3) Two captures of byte-identical images reuse the same `<hash>.png`:
    /// the hash is taken over the PLAINTEXT png, so encryption leaves T2's
    /// content-addressed dedup intact (still one payload on disk). Driven through
    /// `monitor.capture` so the real persistImage `fileExists` reuse early-return
    /// is exercised — the second capture must NOT rewrite the existing payload.
    func testByteIdenticalImagesReuseSamePayloadHash() throws {
        let first = try capturedImageItem(blue: 1.0)
        let payload = try XCTUnwrap(first.payloadFile)
        let url = tempDir.appendingPathComponent(payload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // Record the sealed bytes + modification date of the first write.
        let sealedFirst = try Data(contentsOf: url)
        XCTAssertTrue(Crypto.isSealed(sealedFirst), "first capture must seal the payload")
        let firstAttrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let firstMod = firstAttrs[.modificationDate] as? Date

        // A second capture of byte-identical content must reuse the existing file
        // (same payloadFile + hash) WITHOUT rewriting it.
        let second = try capturedImageItem(blue: 1.0)
        XCTAssertEqual(second.payloadFile, first.payloadFile,
                       "byte-identical content must resolve to the same payload file")
        XCTAssertEqual(second.imageHash, first.imageHash,
                       "byte-identical content must resolve to the same hash")

        // The file was reused, not rewritten: bytes are byte-identical (a fresh
        // seal would use a new random nonce → different ciphertext) and the
        // modification date is unchanged.
        let sealedSecond = try Data(contentsOf: url)
        XCTAssertEqual(sealedFirst, sealedSecond,
                       "the reused payload must not be re-sealed (a new seal would change the nonce)")
        if let firstMod {
            let secondMod = (try FileManager.default.attributesOfItem(atPath: url.path))[.modificationDate] as? Date
            XCTAssertEqual(firstMod, secondMod, "the reused payload must not be rewritten")
        }

        // Exactly one payload on disk for the shared content.
        let pngs = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path))?
            .filter { $0.hasSuffix(".png") && !$0.hasSuffix("-thumb.png") } ?? []
        XCTAssertEqual(pngs.count, 1, "byte-identical images must share one payload")
    }

    /// (5) A NEW capture (not the migration path) seals its payload AND thumbnail
    /// at rest: both files carry the `enc1:` marker, are NOT a valid PNG header,
    /// and round-trip back to a decodable PNG via Crypto.open. Guards against a
    /// regression where persistImage/writeThumbnail dropped the seal and wrote
    /// plaintext PNGs through the live capture seam.
    func testNewCaptureSealsPayloadAndThumbnail() throws {
        let item = try capturedImageItem(blue: 0.5)
        let payload = try XCTUnwrap(item.payloadFile)
        let base = (payload as NSString).deletingPathExtension

        for name in [payload, "\(base)-thumb.png"] {
            let url = tempDir.appendingPathComponent(name)
            let raw = try Data(contentsOf: url)
            XCTAssertTrue(Crypto.isSealed(raw), "\(name) must carry the enc1: marker after capture")
            XCTAssertFalse(isPNGHeader(raw), "\(name) must NOT start with PNG magic at rest")

            let opened = try XCTUnwrap(Crypto.open(raw), "\(name) must decrypt via Crypto.open")
            XCTAssertTrue(isPNGHeader(opened), "decrypted \(name) must be a valid PNG")
            XCTAssertNotNil(NSImage(data: opened), "decrypted \(name) must decode to an NSImage")
        }
    }

    /// (4) encryptImagePayloadsIfNeeded() seals a pre-seeded plaintext PNG+thumb
    /// and is idempotent: a second store over the same dir (flag re-cleared,
    /// mimicking an interrupted/re-run pass) leaves the already-sealed bytes
    /// untouched and still decryptable.
    func testMigrationIsIdempotent() {
        let hash = seedReferencedPlaintextPayload(red: 0.75)
        let url = tempDir.appendingPathComponent("\(hash).png")
        let thumbURL = tempDir.appendingPathComponent("\(hash)-thumb.png")

        _ = ClipStore(directory: tempDir)
        let sealedOnce = try! Data(contentsOf: url)
        let thumbSealedOnce = try! Data(contentsOf: thumbURL)
        XCTAssertTrue(Crypto.isSealed(sealedOnce))
        XCTAssertTrue(Crypto.isSealed(thumbSealedOnce))

        // Re-run the pass: re-clear the gate and rebuild the store. Already-sealed
        // payloads (isSealed == true) are skipped, so bytes are byte-stable.
        UserDefaults.standard.removeObject(forKey: Self.migrationFlag)
        _ = ClipStore(directory: tempDir)
        let sealedTwice = try! Data(contentsOf: url)
        let thumbSealedTwice = try! Data(contentsOf: thumbURL)
        XCTAssertEqual(sealedOnce, sealedTwice, "re-running must not re-seal an already-sealed payload")
        XCTAssertEqual(thumbSealedOnce, thumbSealedTwice, "re-running must not re-seal an already-sealed thumb")

        // Still decryptable back to the original plaintext PNG bytes.
        XCTAssertEqual(Crypto.open(sealedTwice), pngData(red: 0.75))
    }
}
