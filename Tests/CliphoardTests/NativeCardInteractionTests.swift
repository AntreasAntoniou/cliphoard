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

    func testImageInspectButtonRespondsAcrossAspectRatios() async throws {
        for selected in [false, true] {
            for size in [NSSize(width: 90, height: 400), NSSize(width: 100, height: 100),
                         NSSize(width: 400, height: 90)] {
                try await inspectClicks(selected: selected, imageSize: size)
            }
        }
    }

    private func inspectClicks(selected: Bool, imageSize: NSSize? = nil) async throws {
        _ = NSApplication.shared
        let saved = UserDefaults.standard.string(forKey: "themePreset")
        UserDefaults.standard.set("swiss", forKey: "themePreset")
        defer { if let saved { UserDefaults.standard.set(saved, forKey: "themePreset") }
                else { UserDefaults.standard.removeObject(forKey: "themePreset") } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = ClipItem(kind: imageSize == nil ? .text : .image,
                            text: "Synthetic card for native inspect interaction")
        if let size = imageSize {
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let filename = "\(UUID().uuidString).png"
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: dir.appendingPathComponent(filename))
            item.payloadFile = filename
        }
        var inspected = 0
        var selectedByClick = 0
        let card = ClipCardView(item: item, index: 10, selected: selected,
            storeDir: dir,
            onActivate: {}, onInspect: { inspected += 1 }, onInspectTags: {},
            onPin: {}, onDelete: {}, historyIsMutable: true)
            .onTapGesture { selectedByClick += 1 }
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
            XCTAssertEqual(inspected, index + 1,
                "Each label point must activate Inspect exactly once: image=\(String(describing: imageSize)), selected=\(selected)")
            XCTAssertEqual(selectedByClick, 0, "Inspect must not fall through to card selection")
            print("NATIVE inspectPointerX=\(x) callbackCount=\(inspected) elapsedMs=\(Date().timeIntervalSince(start) * 1_000)")
        }
        XCTAssertEqual(inspected, 3, "The entire label must activate Inspect, including outside the glyph")

        let center = host.convert(NSPoint(x: host.bounds.midX, y: host.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: center,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 100,
                clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            NSApp.sendEvent(event)
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(selectedByClick, 1, "The preview must still select the card")
        XCTAssertEqual(inspected, 3, "Selecting the preview must not open Inspect")

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
