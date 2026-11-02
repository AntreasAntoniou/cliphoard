import XCTest
import SwiftUI
import AppKit
@testable import Cliphoard

@MainActor
final class SearchControlPresentationTests: XCTestCase {
    func testCombinedSummaryDoesNotPromiseDisabledOrPaidContent() {
        let selected = SearchCapabilities(text: true, images: true, audio: true, video: true, imageModel: .clip)
        XCTAssertEqual(SearchControlLabels.combinedSummary(selected, pro: false), "Text")
        XCTAssertEqual(SearchControlLabels.combinedSummary(selected, pro: true), "Text · Images · Audio · Video")
        let none = SearchCapabilities(text: false, images: true, audio: false, video: false, imageModel: .gemma2)
        XCTAssertTrue(SearchControlLabels.combinedSummary(none, pro: false).contains("No content types"))
        XCTAssertEqual(SearchControlLabels.combinedSummary(none, pro: true), "Images")
    }

    func testIdleStatusDisappearsButIndexingAndCalibrationLimitRemainVisible() {
        XCTAssertFalse(PictureIndexStatus(indexed: 10, eligible: 10, working: false).needsAttention)
        XCTAssertFalse(PictureIndexStatus(indexed: 0, eligible: 0, working: false).needsAttention)
        XCTAssertTrue(PictureIndexStatus(indexed: 0, eligible: 10, working: false).needsAttention)
        XCTAssertTrue(PictureIndexStatus(indexed: 10, eligible: 10, working: true).needsAttention)
        XCTAssertTrue(PictureIndexStatus(indexed: 1, eligible: 1, working: false).needsAttention)
    }

    /// Only a stateless, synthetic toolbar is hosted. No ClipStore, clipboard,
    /// real model, application delegate, Keychain or network is involved.
    func testToolbarFitsNarrowAndWideWindows() throws {
        _ = NSApplication.shared
        for width in [640.0, 900.0, 1440.0] {
            for dark in [false, true] {
                let host = NSHostingView(rootView: SearchBarFixture()
                    .frame(width: width).preferredColorScheme(dark ? .dark : .light))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 115),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                host.frame = NSRect(x: 0, y: 0, width: width, height: 115)
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                XCTAssertLessThanOrEqual(host.fittingSize.width, width + 1)
                XCTAssertLessThan(host.fittingSize.height, 125)
                XCTAssertFalse(window.isVisible)
                if let output = ProcessInfo.processInfo.environment["CLIPHOARD_SEARCH_UI_SNAPSHOTS"] {
                    let root = URL(fileURLWithPath: output, isDirectory: true)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: root.appendingPathComponent("toolbar-\(Int(width))-\(dark ? "dark" : "light").png"), options: .withoutOverwriting)
                }
                window.close()
            }
        }
    }
}

@MainActor private struct SearchBarFixture: View {
    @State private var query = "cat"
    @State private var scope = SearchModality.all
    @FocusState private var focused: Bool
    var body: some View {
        SearchBarView(query: $query, scope: $scope, searchFocused: $focused,
                      isPro: true, openOptions: {}, openSettings: {}) {
            HStack(spacing: 12) {
                Label("Clip type", systemImage: "line.3.horizontal.decrease")
                Label("Pinned", systemImage: "pin.fill")
                Label("Time", systemImage: "clock")
                Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                Spacer()
                Text("Text · Images").foregroundStyle(.secondary)
            }
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}
