import XCTest
@testable import Cliphoard

/// TP-9: kind refinement. The old embedding-based `refineKind` seam was removed;
/// a clip's KIND is now decided solely by deterministic detection
/// (`ClipboardMonitor.detectKind`) and healed on store init by
/// `ClipStore.repairKinds`. These tests pin that observable behaviour through the
/// public surface (no source edit, no private-visibility changes): the pure
/// `detectKind` classifier plus a `ClipStore` over a temp directory whose stored
/// rows are re-derived on load.
@MainActor
final class RefineKindTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        Feedback.soundEnabled = false
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoRefineKindTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// Seed a legacy `history.json` (the established temp-store fixture path) so the
    /// rows migrate into a fresh SQLite store on init and then run through
    /// `repairKinds`. Returns the loaded store.
    private func storeSeeded(with rows: [[String: Any]]) throws -> ClipStore {
        let data = try JSONSerialization.data(withJSONObject: rows, options: [])
        try data.write(to: dir.appendingPathComponent("history.json"))
        return ClipStore(directory: dir)
    }

    private func clip(text: String, kind: String) -> [String: Any] {
        let now = Date().timeIntervalSinceReferenceDate
        return [
            "id": UUID().uuidString,
            "kind": kind,
            "text": text,
            "createdAt": now,
            "lastUsedAt": now,
            "pinned": false,
            "useCount": 0,
        ]
    }

    /// A whitespace-free string that is really a URL/domain but was mis-stored as
    /// plain `.text` is promoted to `.link` when the store re-derives kinds on init.
    func testRefineKindPromotesWhitespaceFreeTextToLinkWhenTagged() throws {
        // Sanity: the classifier itself recognises these as links.
        XCTAssertEqual(ClipboardMonitor.detectKind(for: "https://example.com"), .link)
        XCTAssertEqual(ClipboardMonitor.detectKind(for: "github.com"), .link)

        let store = try storeSeeded(with: [
            clip(text: "https://example.com", kind: "text"),
            clip(text: "github.com", kind: "text"),
        ])

        let url = try XCTUnwrap(store.items.first { $0.text == "https://example.com" })
        XCTAssertEqual(url.kind, .link, "mis-stored URL row healed to .link on load")
        let domain = try XCTUnwrap(store.items.first { $0.text == "github.com" })
        XCTAssertEqual(domain.kind, .link, "mis-stored bare-domain row healed to .link on load")
    }

    /// Ordinary multi-word prose stays `.text` — it must NOT be promoted to a link
    /// just because it contains URL-ish words, and the repair pass leaves it alone.
    func testRefineKindLeavesMultiWordTextAlone() throws {
        XCTAssertEqual(ClipboardMonitor.detectKind(for: "hello world"), .text)
        XCTAssertEqual(ClipboardMonitor.detectKind(for: "see https://x.com now"), .text)
        XCTAssertEqual(ClipboardMonitor.detectKind(for: "example.com is a great domain"), .text)

        let store = try storeSeeded(with: [
            clip(text: "hello world", kind: "text"),
            clip(text: "see https://x.com now", kind: "text"),
            clip(text: "example.com is a great domain", kind: "text"),
        ])

        for item in store.items {
            XCTAssertEqual(item.kind, .text, "multi-word text \"\(item.text)\" must stay .text")
        }
    }

    /// Non-text clips (images, files) carry an out-of-band payload and a caption
    /// string that is not their real content. The repair pass keys kind re-derivation
    /// off text only for payload-free rows, so a non-text clip is never demoted to
    /// `.text` even if its caption would classify that way.
    func testRefineKindDoesNotDemoteNonText() throws {
        let now = Date().timeIntervalSinceReferenceDate
        // An image clip whose caption ("Image 12x8") is plain words, and a file clip
        // whose text is a path. Neither should be re-derived to .text.
        let imageRow: [String: Any] = [
            "id": UUID().uuidString,
            "kind": "image",
            "text": "Image 12×8",
            "payloadFile": "shot.png",
            "createdAt": now,
            "lastUsedAt": now,
            "pinned": false,
            "useCount": 0,
        ]
        let fileRow: [String: Any] = [
            "id": UUID().uuidString,
            "kind": "file",
            "text": "/Users/me/Documents/report.txt",
            "filePath": "/Users/me/Documents/report.txt",
            "createdAt": now,
            "lastUsedAt": now,
            "pinned": false,
            "useCount": 0,
        ]
        // Keep the referenced PNG present so the orphan sweep does not drop the image.
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: dir.appendingPathComponent("shot.png"))

        let store = try storeSeeded(with: [imageRow, fileRow])

        let image = try XCTUnwrap(store.items.first { $0.payloadFile == "shot.png" })
        XCTAssertEqual(image.kind, .image, "image clip must not be demoted to .text")
        let file = try XCTUnwrap(store.items.first { $0.filePath != nil })
        XCTAssertEqual(file.kind, .file, "file clip must not be demoted to .text")
    }

    /// The deterministic classifier promotes single, whole-string links/emails to
    /// `.link` while a bare colour or plain word does not become a link.
    func testRefineKindLink() {
        XCTAssertEqual(ClipboardMonitor.detectKind(for: "https://example.com"), .link)
        XCTAssertEqual(ClipboardMonitor.detectKind(for: "http://example.com/a/b?c=1"), .link)
        XCTAssertEqual(ClipboardMonitor.detectKind(for: "www.apple.com/mac"), .link)
        XCTAssertEqual(ClipboardMonitor.detectKind(for: "mailto:a@b.com"), .link)
        XCTAssertEqual(ClipboardMonitor.detectKind(for: "antreas@axiotic.ai"), .link)
        // Not links:
        XCTAssertEqual(ClipboardMonitor.detectKind(for: "just words here"), .text)
        XCTAssertEqual(ClipboardMonitor.detectKind(for: "#FF8800"), .color)
    }
}
