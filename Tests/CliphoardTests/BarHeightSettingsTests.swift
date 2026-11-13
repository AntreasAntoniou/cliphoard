import XCTest
import AppKit
import SwiftUI
@testable import Cliphoard

@MainActor
final class BarHeightSettingsTests: XCTestCase {
    func testDefaultPersistenceResetAndInvalidValues() throws {
        let name = "BarHeightTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = BarHeightSettings(defaults: defaults)
        XCTAssertEqual(settings.previewHeight, 250)
        settings.setHeight(370)
        XCTAssertEqual(BarHeightSettings(defaults: defaults).previewHeight, 370)
        settings.setHeight(250)
        XCTAssertEqual(BarHeightSettings(defaults: defaults).previewHeight, 250)
        for (input, expected) in [(Double.nan, 250.0), (.infinity, 250), (-10, 200), (900, 400)] {
            settings.setHeight(input)
            XCTAssertEqual(settings.previewHeight, expected)
            defaults.set(input, forKey: BarHeightSettings.defaultsKey)
            XCTAssertEqual(BarHeightSettings(defaults: defaults).previewHeight, expected)
        }
    }

    func testSmallScreenLimitsExtraHeightWithoutLosingSavedChoice() throws {
        let name = "BarHeightTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = BarHeightSettings(defaults: defaults)
        settings.setHeight(400)
        settings.setAvailableHeight(615)
        XCTAssertEqual(settings.effectiveHeight, 250)
        XCTAssertEqual(settings.previewHeight, 400)
        settings.setAvailableHeight(900)
        XCTAssertEqual(settings.effectiveHeight, 400)
        settings.setHeight(200)
        XCTAssertEqual(settings.effectiveHeight, 200)
        XCTAssertEqual(settings.panelFloor, 270)
    }

    func testActualPanelResizesLiveAndKeepsFooterAtBottom() async throws {
        _ = NSApplication.shared
        let settings = BarHeightSettings.shared
        let saved = settings.previewHeight
        defer { settings.setHeight(saved) }
        let panel = FloatingPanel()
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        panel.setContent { HeightFixture() }
        let visible = NSRect(x: -1440, y: 80, width: 1440, height: 900)
        var heights: [CGFloat] = []
        for chosen in [200.0, 250, 400, 250] {
            settings.setHeight(chosen)
            for _ in 0..<3 {
                panel.fit(to: visible)
                panel.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 30_000_000)
            }
            XCTAssertEqual(panel.frame.minY, visible.minY, accuracy: 0.5)
            XCTAssertEqual(panel.frame.height, chosen - 48 + 28 + 112, accuracy: 0.5)
            let off = FloatingPanel.offScreenFrame(visible: visible, contentHeight: panel.frame.height,
                                                   minimumHeight: settings.panelFloor)
            XCTAssertEqual(off.height, panel.frame.height)
            XCTAssertEqual(off.maxY, visible.minY)
            heights.append(panel.frame.height)
        }
        XCTAssertLessThan(heights[0], heights[1])
        XCTAssertGreaterThan(heights[2], heights[1])
        XCTAssertEqual(heights[1], heights[3])
    }
}

@MainActor private struct HeightFixture: View {
    @ObservedObject var height = BarHeightSettings.shared
    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 80)
            Color.gray.frame(height: Theme.thumbnailStripHeight)
            Text("Footer").frame(height: 32)
        }
    }
}
