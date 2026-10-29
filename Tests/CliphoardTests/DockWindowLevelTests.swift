import AppKit
import CoreGraphics
import XCTest
@testable import Cliphoard

final class DockWindowLevelTests: XCTestCase {
    @MainActor
    func testActualHiddenPanelsRemainBelowSystemDock() {
        _ = NSApplication.shared
        let bar = FloatingPanel()
        let inspector = InspectorWindowController()
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))

        // Construct the actual windows without ordering them onscreen, starting
        // clipboard monitoring, changing Dock preferences, or creating content.
        XCTAssertFalse(bar.isVisible)
        XCTAssertFalse(inspector.panel.isVisible)
        XCTAssertGreaterThan(bar.level.rawValue, NSWindow.Level.normal.rawValue)
        XCTAssertLessThan(bar.level.rawValue, inspector.panel.level.rawValue)
        XCTAssertLessThan(inspector.panel.level.rawValue, dockLevel)
        XCTAssertTrue(bar.canBecomeKey)
        XCTAssertTrue(inspector.panel.canBecomeKey)
    }
}
