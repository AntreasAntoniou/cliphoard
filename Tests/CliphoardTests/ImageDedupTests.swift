import XCTest
import AppKit
import CryptoKit
@testable import Cliphoard

/// T2: Content-hash image dedup. Identical PNG bytes must share a signature,
/// collapse to a single ClipStore entry, and leave exactly one PNG on disk.
@MainActor
final class ImageDedupTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        Feedback.soundEnabled = false
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoImageDedupTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// Build a deterministic solid-colour PNG so identical inputs => identical bytes.
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

    private func makeImageItem(from png: Data) -> ClipItem {
        let item = ClipItem(kind: .image, text: "Image")
        let hash = sha256Hex(png)
        item.imageHash = hash
        item.payloadFile = "\(hash).png"
        return item
    }

    func testIdenticalImageBytesShareSignature() {
        let png = pngData(red: 1.0)
        let a = makeImageItem(from: png)
        let b = makeImageItem(from: png)
        XCTAssertEqual(a.signature, b.signature)
        XCTAssertTrue(a.signature.hasPrefix("img:"))
    }

    func testDifferentImageBytesDifferInSignature() {
        let a = makeImageItem(from: pngData(red: 1.0))
        let b = makeImageItem(from: pngData(red: 0.25))
        XCTAssertNotEqual(a.signature, b.signature)
    }

    func testSignatureFallsBackToPayloadFileWhenHashNil() {
        // Legacy items (no imageHash) keep the old 'img:'+payloadFile form.
        let legacy = ClipItem(kind: .image, text: "Image")
        legacy.payloadFile = "ABC123.png"
        XCTAssertNil(legacy.imageHash)
        XCTAssertEqual(legacy.signature, "img:ABC123.png")
    }

    func testStoreCollapsesIdenticalImagesAndKeepsOnePNG() {
        let store = ClipStore(directory: tempDir)
        let png = pngData(red: 1.0)
        let hash = sha256Hex(png)
        let name = "\(hash).png"

        // Simulate two captures of byte-identical image content. Persist the PNG
        // (reusing on collision, mirroring the monitor's behaviour) for both.
        for _ in 0..<2 {
            let item = ClipItem(kind: .image, text: "Image")
            item.imageHash = hash
            item.payloadFile = name
            let url = tempDir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                try? png.write(to: url)
            }
            store.add(item)
        }

        XCTAssertEqual(store.items.count, 1, "identical images must collapse to one item")

        let pngs = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path))?
            .filter { $0.hasSuffix(".png") && !$0.hasSuffix("-thumb.png") } ?? []
        XCTAssertEqual(pngs.count, 1, "only one PNG should remain on disk")
    }

    func testImageHashCodableRoundTrip() throws {
        let item = ClipItem(kind: .image, text: "Image")
        item.imageHash = "deadbeef"
        item.payloadFile = "deadbeef.png"
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(ClipItem.self, from: data)
        XCTAssertEqual(decoded.imageHash, "deadbeef")
        XCTAssertEqual(decoded.signature, "img:deadbeef")
    }

    func testLegacyJSONWithoutImageHashDecodes() throws {
        // A clip serialized before imageHash existed must still decode (nil hash).
        let json = """
        {"id":"\(UUID().uuidString)","kind":"image","text":"Image","payloadFile":"old.png",\
        "createdAt":0,"lastUsedAt":0,"pinned":false,"useCount":0,"embeddings":{}}
        """
        let decoded = try JSONDecoder().decode(ClipItem.self, from: Data(json.utf8))
        XCTAssertNil(decoded.imageHash)
        XCTAssertEqual(decoded.signature, "img:old.png")
    }
}
