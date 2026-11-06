import XCTest
import AppKit
import SwiftUI
@testable import Cliphoard

/// Real AppKit/SwiftUI hosting and native mouse events against synthetic clips only.
/// Does not use the system clipboard or the owner's store.
@MainActor
final class NativeCardInteractionTests: XCTestCase {
    private final class TestHostingView<V: View>: NSHostingView<V> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
    func testInspectButtonRespondsToNativeMouseEventsAcrossItsLabel() async throws {
        try await inspectClicks(selected: true)
    }

    func testUnselectedInspectRemainsAvailableDuringPointerDwell() async throws {
        try await inspectClicks(selected: false)
    }

    private func inspectClicks(selected: Bool) async throws {
        _ = NSApplication.shared
        let saved = UserDefaults.standard.string(forKey: "themePreset")
        UserDefaults.standard.set("swiss", forKey: "themePreset")
        defer { if let saved { UserDefaults.standard.set(saved, forKey: "themePreset") }
                else { UserDefaults.standard.removeObject(forKey: "themePreset") } }
        let item = ClipItem(kind: .text, text: "Synthetic card for native inspect interaction")
        var inspected = 0
        let card = ClipCardView(item: item, index: 10, selected: selected,
            storeDir: FileManager.default.temporaryDirectory,
            onActivate: {}, onInspect: { inspected += 1 }, onInspectTags: {},
            onPin: {}, onDelete: {}, historyIsMutable: true)
        let host = TestHostingView(rootView: card)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 220, height: 250),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        // SwiftUI combines the card's AX children intentionally. Exercise the
        // real pointer path, including points outside the small 9pt glyph.
        window.orderBack(nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        print("NATIVE hostBounds=\(host.bounds) window=\(window.frame) flipped=\(host.isFlipped)")
        let y = host.isFlipped ? host.bounds.midY - Theme.thumbnailHeight / 2 + 14
                               : host.bounds.midY + Theme.thumbnailHeight / 2 - 14
        for (index, x) in [190.0, 199.0, 208.0].enumerated() {
            let point = host.convert(NSPoint(x: x, y: y), to: nil)
            let start = Date()
            window.acceptsMouseMovedEvents = true
            for step in 0..<12 {
                let motion = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: step,
                    clickCount: 0, pressure: 0))
                NSApp.sendEvent(motion)
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertEqual(inspected, index, "Hover must never activate Inspect")
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: inspected + 1,
                    clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                NSApp.sendEvent(event)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
            XCTAssertEqual(inspected, index + 1, "Each label point must activate Inspect exactly once")
            print("NATIVE inspectPointerX=\(x) callbackCount=\(inspected) elapsedMs=\(Date().timeIntervalSince(start) * 1_000)")
        }
        XCTAssertEqual(inspected, 3, "The entire label must activate Inspect, including outside the glyph")

    }

    func testLargeHistoryNativePanelAndPinUseActions() async throws {
        _ = NSApplication.shared
        let savedTheme = UserDefaults.standard.string(forKey: "themePreset")
        let savedLevel = DeepSearch.level
        UserDefaults.standard.set("swiss", forKey: "themePreset")
        DeepSearch.level = .off
        defer {
            DeepSearch.level = savedLevel
            if let savedTheme { UserDefaults.standard.set(savedTheme, forKey: "themePreset") }
            else { UserDefaults.standard.removeObject(forKey: "themePreset") }
        }
        for count in [8_000, 32_000] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CliphoardNativePerf-\(UUID())")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let db = try XCTUnwrap(Database(path: dir.appendingPathComponent("ditto.sqlite").path))
            XCTAssertTrue(db.transaction {
                for i in 0..<count {
                    let item = ClipItem(kind: .text, text: "Synthetic ordinary meeting note number \(i)")
                    item.userTags = ["shared", "group-\(i % 8)"]
                    XCTAssertTrue(db.insert(item))
                }
            })
            let store = ClipStore(directory: dir)
            XCTAssertFalse(store.safeMode)
            XCTAssertEqual(store.items.count, count)
            let model = PanelViewModel(store: store)
            let host = NSHostingView(rootView: ContentView(model: model, store: store, pasteStatus: PasteStatus()))
            let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1280, height: 420),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
            let moved = store.items[count / 2]
            let start = Date()
            store.togglePin(moved)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(model.results.first?.id, moved.id)
            XCTAssertEqual(store.items(withUserTag: "shared").first?.id, moved.id)
            XCTAssertTrue(moved.pinned)
            print("NATIVE history=\(count) pinAndLayoutMs=\(Date().timeIntervalSince(start) * 1_000)")
            store.togglePin(moved)
            store.markUsed(moved)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(model.results.first?.id, moved.id)
            XCTAssertEqual(store.items.count, count)
            XCTAssertEqual(store.items(withUserTag: "shared").map(\.id), store.items.map(\.id))
        }
    }
}
