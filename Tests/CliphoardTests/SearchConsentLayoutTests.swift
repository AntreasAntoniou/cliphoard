import XCTest
import AppKit
import SwiftUI
@testable import Cliphoard

@MainActor final class SearchConsentLayoutTests: XCTestCase {
    private final class ClickHost<V: View>: NSHostingView<V> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
    func testFullConsentAndBothActionsAreVisibleAndClickable() async throws {
        _ = NSApplication.shared
        let oldTheme = Theme.preset
        Theme.preset = .oneDark
        defer { Theme.preset = oldTheme }
        for download in [false, true] {
            var prepared = 0, declined = 0
            let view = SearchModelConsentCard(title: "CLIP · OpenVision", download: download,
                size: "485 MB", pictures: true, enabled: true,
                cancel: { declined += 1 }, prepare: { prepared += 1 })
                .controlSize(.small).frame(width: 420)
                .preferredColorScheme(.dark).environment(\.colorScheme, .dark)
            let measure = NSHostingController(rootView: view)
            let size = measure.sizeThatFits(in: CGSize(width: CGFloat(420), height: CGFloat.infinity))
            XCTAssertGreaterThan(size.height, Theme.chromeMaxHeight,
                "This consent must be outside the 100pt status region that clipped its buttons")
            XCTAssertLessThan(size.height, 260, "The full card must fit a short screen's popover")
            let host = ClickHost(rootView: view)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            window.orderBack(nil); host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
            for x in [35.0, 350.0] {
                let y = host.isFlipped ? host.bounds.height - 20 : 20
                let point = host.convert(NSPoint(x: x, y: y), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                    window.sendEvent(event)
                }
            }
            XCTAssertEqual(prepared, 1); XCTAssertEqual(declined, 1)
            if let output = ProcessInfo.processInfo.environment["CLIPHOARD_SEARCH_UI_SNAPSHOTS"] {
                try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                    to: URL(fileURLWithPath: output).appendingPathComponent("consent-\(download ? "download" : "cached").png"), options: .withoutOverwriting)
            }
            window.close()
        }
    }
}
