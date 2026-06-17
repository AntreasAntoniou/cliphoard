import XCTest
import AppKit
import SwiftUI
@testable import Ditto

// MARK: - Content classification

@MainActor
final class ClassificationTests: XCTestCase {
    func testPlainText() {
        XCTAssertEqual(ClipboardMonitor.detectKind(for: "hello world"), .text)
        XCTAssertEqual(ClipboardMonitor.detectKind(for: "a multi\nline note"), .text)
    }

    func testLinks() {
        XCTAssertEqual(ClipboardMonitor.detectKind(for: "https://example.com"), .link)
        XCTAssertEqual(ClipboardMonitor.detectKind(for: "http://example.com/a/b?c=1"), .link)
        XCTAssertEqual(ClipboardMonitor.detectKind(for: "mailto:a@b.com"), .link)
    }

    /// Regression for the operator-precedence fix: a host-less URL must NOT be a link.
    func testHostlessUrlIsNotLink() {
        XCTAssertEqual(ClipboardMonitor.detectKind(for: "http:"), .text)
        XCTAssertEqual(ClipboardMonitor.detectKind(for: "https://"), .text)
    }

    func testUrlsWithSpacesAreText() {
        XCTAssertEqual(ClipboardMonitor.detectKind(for: "see https://x.com now"), .text)
    }

    func testColors() {
        XCTAssertEqual(ClipboardMonitor.detectKind(for: "#FF8800"), .color)
        XCTAssertEqual(ClipboardMonitor.detectKind(for: "FF8800"), .color)
        XCTAssertEqual(ClipboardMonitor.detectKind(for: "#fff"), .color)
        XCTAssertEqual(ClipboardMonitor.detectKind(for: "#11223344"), .color) // 8-digit (alpha)
    }

    func testNonColors() {
        XCTAssertEqual(ClipboardMonitor.detectKind(for: "#GGGGGG"), .text)
        XCTAssertEqual(ClipboardMonitor.detectKind(for: "12345"), .text) // wrong length
    }
}

// MARK: - Hex colour parsing

final class ColorParsingTests: XCTestCase {
    private func rgb(_ hex: String) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        let ns = NSColor(Theme.color(fromHex: hex)).usingColorSpace(.sRGB)!
        return (ns.redComponent, ns.greenComponent, ns.blueComponent, ns.alphaComponent)
    }

    func testSixDigit() {
        let (r, g, b, a) = rgb("#FF0000")
        XCTAssertEqual(r, 1, accuracy: 0.01); XCTAssertEqual(g, 0, accuracy: 0.01)
        XCTAssertEqual(b, 0, accuracy: 0.01); XCTAssertEqual(a, 1, accuracy: 0.01)
    }

    func testThreeDigitExpands() {
        let (r, g, b, _) = rgb("#0F0")
        XCTAssertEqual(r, 0, accuracy: 0.01); XCTAssertEqual(g, 1, accuracy: 0.01)
        XCTAssertEqual(b, 0, accuracy: 0.01)
    }

    func testEightDigitAlpha() {
        let (_, _, _, a) = rgb("#0000007F")
        XCTAssertEqual(a, 0.5, accuracy: 0.02)
    }

    func testNoHashPrefix() {
        let (_, _, b, _) = rgb("0000FF")
        XCTAssertEqual(b, 1, accuracy: 0.01)
    }
}

// MARK: - Dedup signatures

final class SignatureTests: XCTestCase {
    func testIdenticalTextSharesSignature() {
        let a = ClipItem(kind: .text, text: "same")
        let b = ClipItem(kind: .text, text: "same")
        XCTAssertEqual(a.signature, b.signature)
    }

    func testDifferentTextDiffers() {
        let a = ClipItem(kind: .text, text: "one")
        let b = ClipItem(kind: .text, text: "two")
        XCTAssertNotEqual(a.signature, b.signature)
    }

    func testKindSpecificKeys() {
        let img = ClipItem(kind: .image, text: "Image"); img.payloadFile = "x.png"
        let file = ClipItem(kind: .file, text: "/a"); file.filePath = "/a"
        XCTAssertTrue(img.signature.hasPrefix("img:"))
        XCTAssertTrue(file.signature.hasPrefix("file:"))
    }
}

// MARK: - Store behaviour (isolated temp directory)

@MainActor
final class ClipStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        Feedback.soundEnabled = false
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func newStore() -> ClipStore { ClipStore(directory: tempDir) }
    private func text(_ s: String) -> ClipItem { ClipItem(kind: .text, text: s) }

    func testAddAndOrder() {
        let store = newStore()
        store.add(text("first"))
        store.add(text("second"))
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.items.first?.text, "second") // newest first
    }

    func testDedupKeepsOneAndBumps() {
        let store = newStore()
        store.add(text("dup"))
        store.add(text("other"))
        store.add(text("dup")) // duplicate signature
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.items.first?.text, "dup") // bumped to front
    }

    func testTrimDropsOldestUnpinned() {
        let store = newStore()
        store.historyLimit = 2
        store.add(text("a")); store.add(text("b")); store.add(text("c"))
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.items.map(\.text), ["c", "b"])
    }

    func testUnlimitedKeepsEverything() {
        let store = newStore()
        store.historyLimit = 0 // unlimited
        for i in 0..<50 { store.add(text("item-\(i)")) }
        XCTAssertEqual(store.items.count, 50)
    }

    func testPinSurvivesTrimAndSortsFront() {
        let store = newStore()
        store.historyLimit = 2
        let keep = text("pinme")
        store.add(keep)
        store.togglePin(keep)
        store.add(text("a")); store.add(text("b")); store.add(text("c"))
        XCTAssertTrue(store.items.contains { $0.text == "pinme" })
        XCTAssertEqual(store.items.first?.text, "pinme") // pinned floats to front
    }

    func testFiltered() {
        let store = newStore()
        store.add(text("apple"))
        store.add(text("banana"))
        let link = ClipItem(kind: .link, text: "https://apple.com")
        store.add(link)
        XCTAssertEqual(store.filtered(kind: nil, query: "apple", pinnedOnly: false).count, 2)
        XCTAssertEqual(store.filtered(kind: .link, query: "", pinnedOnly: false).count, 1)
        store.togglePin(link)
        XCTAssertEqual(store.filtered(kind: nil, query: "", pinnedOnly: true).count, 1)
    }

    func testClearUnpinned() {
        let store = newStore()
        let pinned = text("keep")
        store.add(pinned); store.togglePin(pinned)
        store.add(text("drop1")); store.add(text("drop2"))
        store.clearUnpinned()
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.text, "keep")
    }

    func testPersistenceRoundTrip() {
        do {
            let store = newStore()
            store.add(text("persisted-a"))
            store.add(text("persisted-b"))
        }
        let reloaded = newStore() // same tempDir
        XCTAssertEqual(reloaded.items.count, 2)
        XCTAssertEqual(reloaded.items.first?.text, "persisted-b")
    }

    func testCounts() {
        let store = newStore()
        store.add(text("t1")); store.add(text("t2"))
        store.add(ClipItem(kind: .link, text: "https://x.com"))
        let counts = store.counts()
        XCTAssertEqual(counts[.text], 2)
        XCTAssertEqual(counts[.link], 1)
    }
}

// MARK: - Paste-as-plain-text

@MainActor
final class PasterTests: XCTestCase {
    func testPlainStripsRTF() {
        let store = ClipStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoTests-paste-\(UUID().uuidString)"))
        let item = ClipItem(kind: .text, text: "styled")
        item.rtf = "{\\rtf1 styled}".data(using: .utf8)

        Paster.writeToPasteboard(item, store: store, plain: true)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "styled")
        XCTAssertNil(NSPasteboard.general.data(forType: .rtf), "plain paste must omit RTF")
    }

    func testRichKeepsRTF() {
        let store = ClipStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoTests-paste-\(UUID().uuidString)"))
        let item = ClipItem(kind: .text, text: "styled")
        item.rtf = "{\\rtf1 styled}".data(using: .utf8)

        Paster.writeToPasteboard(item, store: store, plain: false)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "styled")
        XCTAssertNotNil(NSPasteboard.general.data(forType: .rtf), "rich paste must keep RTF")
    }
}
