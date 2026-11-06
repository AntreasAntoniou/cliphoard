import XCTest
import AppKit
import SwiftUI
@testable import Cliphoard

@MainActor
final class PanelAnchoringTests: XCTestCase {
    func testActualPanelFitsVisibleContentAndKeepsFooterAtBottom() throws {
        _ = NSApplication.shared
        let panel = FloatingPanel()
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let marker = NSView()
        panel.setContent { AnchoringFixture(marker: marker) }
        for visible in [NSRect(x: 0, y: 0, width: 1728, height: 1084),
                        NSRect(x: -1440, y: 80, width: 640, height: 900),
                        NSRect(x: -1440, y: 80, width: 1440, height: 900)] {
            panel.setFrame(NSRect(x: visible.minX, y: visible.minY,
                                  width: visible.width, height: 697), display: false)
            for _ in 0..<3 {
                panel.fit(to: visible)
                panel.contentView?.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            XCTAssertFalse(panel.isVisible)
            XCTAssertEqual(panel.frame.minY, visible.minY, accuracy: 1)
            XCTAssertEqual(panel.frame.width, visible.width, accuracy: 1)
            let footer = marker.convert(marker.bounds, to: nil)
            XCTAssertEqual(footer.minY, 0, accuracy: 1,
                "Visible footer must reach the window bottom, not float in transparent space")
            XCTAssertLessThan(panel.frame.height, visible.width > 1000 ? 380 : 500)
        }
    }
}

@MainActor private struct AnchoringFixture: View {
    let marker: NSView
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 0) {
            SearchBarView(query: .constant(""), scope: .constant(.all), matching: .constant(.smart),
                searchFocused: $focused, isPro: true, openOptions: {}, openSettings: {}) {
                Group {
                    Text("Clip type")
                    Text("Pinned")
                    Text("Time")
                    Text("Filters")
                }
            }
            Color.gray.frame(height: 240)
            Text("Footer").frame(maxWidth: .infinity).frame(height: 32)
                .background(AnchorMarker(view: marker))
        }.padding(.top, 8)
    }
}

private struct AnchorMarker: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
