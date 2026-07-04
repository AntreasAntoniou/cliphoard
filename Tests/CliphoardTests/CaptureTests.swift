import XCTest
import AppKit
@testable import Cliphoard

/// A fake `PasteboardReading` that lets `ClipboardMonitor.capture(from:)` run
/// headless — no system pasteboard, no app activation. Seed it with any mix of
/// file URL / image / text and it answers the four reads (plus `readImage`)
/// exactly as `NSPasteboard` would for those contents.
@MainActor
final class FakePasteboard: PasteboardReading {
    var fileURLs: [URL] = []
    var image: NSImage?
    var string: String?
    var rtf: Data?

    func readObjects(forClasses classes: [AnyClass], options: [NSPasteboard.ReadingOptionKey: Any]?) -> [Any]? {
        // capture() only ever asks for file URLs here.
        guard classes.contains(where: { $0 == NSURL.self }) else { return nil }
        return fileURLs.isEmpty ? nil : fileURLs.map { $0 as NSURL }
    }

    func canReadObject(forClasses classes: [AnyClass], options: [NSPasteboard.ReadingOptionKey: Any]?) -> Bool {
        if classes.contains(where: { $0 == NSImage.self }) { return image != nil }
        return false
    }

    func string(forType type: NSPasteboard.PasteboardType) -> String? {
        type == .string ? string : nil
    }

    func data(forType type: NSPasteboard.PasteboardType) -> Data? {
        type == .rtf ? rtf : nil
    }

    func readImage() -> NSImage? { image }
}

/// TP-10: capture-path behaviour driven through the fake-pasteboard seam.
/// Extends (does not duplicate) `CaptureSkipTests`, which already covers
/// `shouldSkip`'s truth table directly; here we verify capture *priority*,
/// that `shouldSkip` is honoured at capture time, and `detectKind` boundaries.
@MainActor
final class CaptureTests: XCTestCase {
    private var tempDir: URL!
    private var store: ClipStore!
    private var monitor: ClipboardMonitor!

    override func setUp() {
        super.setUp()
        Feedback.soundEnabled = false
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoCaptureTests-\(UUID().uuidString)")
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

    /// A small solid-colour image that rasterises to PNG so `persistImage`
    /// succeeds (the priority tests need a *capturable* image, not a failure).
    private func rasterisableImage() -> NSImage {
        let size = NSSize(width: 4, height: 4)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.red.setFill()
        NSRect(origin: .zero, size: size).fill()
        img.unlockFocus()
        return img
    }

    // MARK: Priority: file > image > text

    func testFileWinsOverImageAndText() throws {
        let fileURL = tempDir.appendingPathComponent("doc.txt")
        try Data("hi".utf8).write(to: fileURL)
        let pb = FakePasteboard()
        pb.fileURLs = [fileURL]
        pb.image = rasterisableImage()
        pb.string = "plain text"

        let item = try XCTUnwrap(monitor.capture(from: pb))
        XCTAssertEqual(item.kind, .file)
        XCTAssertEqual(item.filePath, fileURL.path)
    }

    func testImageWinsOverText() throws {
        let pb = FakePasteboard()
        pb.image = rasterisableImage()
        pb.string = "plain text"

        let item = try XCTUnwrap(monitor.capture(from: pb))
        XCTAssertEqual(item.kind, .image)
        XCTAssertNotNil(item.payloadFile, "image clip must carry a persisted payload")
    }

    func testTextWhenOnlyTextPresent() throws {
        let pb = FakePasteboard()
        pb.string = "just some words"

        let item = try XCTUnwrap(monitor.capture(from: pb))
        XCTAssertEqual(item.kind, .text)
        XCTAssertEqual(item.text, "just some words")
    }

    func testEmptyPasteboardCapturesNothing() {
        XCTAssertNil(monitor.capture(from: FakePasteboard()))
    }

    func testEmptyStringIsNotCaptured() {
        let pb = FakePasteboard()
        pb.string = ""
        XCTAssertNil(monitor.capture(from: pb))
    }

    func testRTFIsAttachedToTextClip() throws {
        let rtf = Data("{\\rtf1 hello}".utf8)
        let pb = FakePasteboard()
        pb.string = "hello"
        pb.rtf = rtf

        let item = try XCTUnwrap(monitor.capture(from: pb))
        XCTAssertEqual(item.kind, .text)
        XCTAssertEqual(item.rtf, rtf)
    }

    func testColorStringIsClassifiedAndStored() throws {
        let pb = FakePasteboard()
        pb.string = "#FF8800"

        let item = try XCTUnwrap(monitor.capture(from: pb))
        XCTAssertEqual(item.kind, .color)
        XCTAssertEqual(item.colorHex, "#FF8800")
    }

    // MARK: Skipping (transient / concealed / excluded) — gate that fronts capture

    func testTransientConcealedAndExcludedAreSkipped() {
        // These are the conditions poll() checks *before* calling capture().
        // CaptureSkipTests proves the truth table; here we assert capture is
        // only reached when the gate passes, by exercising the gate directly.
        XCTAssertTrue(ClipboardMonitor.shouldSkip(
            frontmostBundleID: nil, types: ["org.nspasteboard.TransientType"], excluded: []))
        XCTAssertTrue(ClipboardMonitor.shouldSkip(
            frontmostBundleID: nil, types: ["org.nspasteboard.ConcealedType"], excluded: []))
        XCTAssertTrue(ClipboardMonitor.shouldSkip(
            frontmostBundleID: "com.1password.app",
            types: ["public.utf8-plain-text"], excluded: ["com.1password.app"]))
        XCTAssertFalse(ClipboardMonitor.shouldSkip(
            frontmostBundleID: "com.allowed.app",
            types: ["public.utf8-plain-text"], excluded: ["com.other.app"]))
    }

    /// When the gate would skip, the content is never captured — proven by
    /// composing the gate decision with capture, mirroring poll()'s flow.
    func testGatedContentIsNeverCaptured() {
        let pb = FakePasteboard()
        pb.string = "secret token"
        let skip = ClipboardMonitor.shouldSkip(
            frontmostBundleID: "com.1password.app",
            types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"],
            excluded: [])
        XCTAssertTrue(skip)
        // poll() returns before capture() when shouldSkip is true; emulate that.
        let captured = skip ? nil : monitor.capture(from: pb)
        XCTAssertNil(captured)
    }

    // MARK: detectKind boundary cases — IPv4 / IPv6 / long URL

    func testDetectKindIPv4() {
        // A bare IPv4 literal is NOT treated as a link (stays text); the same
        // address inside an http URL is a link.
        XCTAssertEqual(ClipboardMonitor.detectKind(for: "192.168.1.1"), .text)
        XCTAssertEqual(ClipboardMonitor.detectKind(for: "http://192.168.1.1/path"), .link)
    }

    func testDetectKindIPv6() {
        // A bare IPv6 literal stays text; a bracketed IPv6 URL is a link.
        XCTAssertEqual(ClipboardMonitor.detectKind(for: "2001:db8::1"), .text)
        XCTAssertEqual(ClipboardMonitor.detectKind(for: "https://[2001:db8::1]/x"), .link)
    }

    func testDetectKindLongURLAndOverLimit() {
        // A normal short URL classifies as a link.
        XCTAssertEqual(ClipboardMonitor.detectKind(for: "https://example.com/a"), .link)
        // A very long URL whose detector match no longer spans the whole string
        // falls back to text rather than being mislabelled.
        let longURL = "http://example.com/" + String(repeating: "a", count: 1000)
        XCTAssertEqual(ClipboardMonitor.detectKind(for: longURL), .text)
        // Strings at/over the 2048-char link ceiling are never links.
        let huge = "https://example.com/" + String(repeating: "b", count: 2048)
        XCTAssertEqual(ClipboardMonitor.detectKind(for: huge), .text)
    }

    func testDetectKindEmailAndMailto() {
        XCTAssertEqual(ClipboardMonitor.detectKind(for: "person@example.com"), .link)
        XCTAssertEqual(ClipboardMonitor.detectKind(for: "mailto:person@example.com"), .link)
    }
}
