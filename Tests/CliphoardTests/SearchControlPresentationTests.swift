import XCTest
import SwiftUI
import AppKit
@testable import Cliphoard

@MainActor
final class SearchControlPresentationTests: XCTestCase {
    func testExactTextBadgeDoesNotPromiseAnUnusedConfiguredModel() {
        let capabilities = SearchCapabilities(text: true, images: true, audio: false, video: false, imageModel: .clip)
        XCTAssertEqual(SearchScopeBadge.selected(mode: .all, capabilities: capabilities, level: .normal,
            pro: true, matching: .exact).map(\.label), ["Text · Exact", "Images · CLIP"])
        XCTAssertEqual(SearchScopeBadge.selected(mode: .text, capabilities: capabilities, level: .normal,
            pro: true, matching: .smart).map(\.label), ["Text · Ogma Small"])
    }
    func testAllTypesKeepsSavedScopeAndBadgesDescribeConfiguredSelection() {
        XCTAssertEqual(SearchControlLabels.scope(.all), "All types")
        XCTAssertEqual(SearchModality.all.rawValue, "all")
        let selected = SearchCapabilities(text: true, images: true, audio: true, video: true, imageModel: .clip)
        XCTAssertEqual(SearchScopeBadge.selected(mode: .all, capabilities: selected, level: .normal, pro: true).map(\.label),
                       ["Text · Ogma Small", "Images · CLIP", "Audio · Gemma 2", "Video · Gemma 2"])
        XCTAssertEqual(SearchScopeBadge.selected(mode: .all, capabilities: selected, level: .off, pro: false).map(\.label), ["Text · Basic"])
        XCTAssertTrue(SearchScopeBadge.selected(mode: .images, capabilities: selected, level: .normal, pro: false).isEmpty)
        let disabled = SearchCapabilities(text: false, images: false, audio: false, video: false, imageModel: .gemma2)
        XCTAssertTrue(SearchScopeBadge.selected(mode: .all, capabilities: disabled, level: .gemma2, pro: true).isEmpty)
        XCTAssertEqual(SearchScopeBadge.selected(mode: .images, capabilities: disabled, level: .normal, pro: true).map(\.label), ["Images · Gemma 2"])
    }
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
              for pending in [false, true] {
                let host = NSHostingView(rootView: SearchBarFixture(pending: pending)
                    .frame(width: width).preferredColorScheme(dark ? .dark : .light))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 150),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                host.frame = NSRect(x: 0, y: 0, width: width, height: 150)
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                XCTAssertLessThanOrEqual(host.fittingSize.width, width + 1)
                XCTAssertLessThan(host.fittingSize.height, 160)
                XCTAssertFalse(window.isVisible)
                if let output = ProcessInfo.processInfo.environment["CLIPHOARD_SEARCH_UI_SNAPSHOTS"] {
                    let root = URL(fileURLWithPath: output, isDirectory: true)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: root.appendingPathComponent("toolbar-\(Int(width))-\(dark ? "dark" : "light")-\(pending ? "pending" : "ready").png"), options: .withoutOverwriting)
                }
                window.close()
              }
            }
        }
    }

    func testToolbarSharesTheControlsRowOnlyWhenTheirNaturalWidthsFit() {
        _ = NSApplication.shared
        let host = NSHostingController(rootView: SearchBarFixture(pending: false))
        let narrow = host.sizeThatFits(in: CGSize(width: 640, height: CGFloat.infinity))
        let wide = host.sizeThatFits(in: CGSize(width: 1440, height: CGFloat.infinity))
        XCTAssertLessThanOrEqual(narrow.width, 641)
        XCTAssertGreaterThan(narrow.height - wide.height, 18)
        XCTAssertLessThanOrEqual(wide.height, 52, "Wide toolbar must fit one 34pt controls row plus 18pt padding")
    }

    func testQuickOptionsFitsItsCompactPopover() throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: SearchOptionsFixture())
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 480)
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(host.fittingSize.width, 301)
        XCTAssertLessThanOrEqual(host.fittingSize.height, 480)
        if let output = ProcessInfo.processInfo.environment["CLIPHOARD_SEARCH_UI_SNAPSHOTS"] {
            try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("search-options.png"), options: .withoutOverwriting)
        }
    }
}

@MainActor private struct SearchBarFixture: View {
    let pending: Bool
    @State private var query = "cat"
    @State private var scope = SearchModality.all
    @FocusState private var focused: Bool
    var body: some View {
        SearchBarView(query: $query, scope: $scope, matching: .constant(.smart), searchFocused: $focused,
                      isPro: true, openOptions: {}, openSettings: {}, isPending: pending,
                      timing: pending ? .enter : .pause, submitSearch: {},
                      badges: SearchScopeBadge.selected(mode: .all,
                        capabilities: SearchCapabilities(text: true, images: true, audio: true, video: true, imageModel: .clip),
                        level: .normal, pro: true)) {
            Group {
                Label("Clip type", systemImage: "line.3.horizontal.decrease")
                Label("Pinned", systemImage: "pin.fill")
                Label("Time", systemImage: "clock")
                Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                Label("reference-picture.png", systemImage: "photo.fill").frame(width: 170)
                Button("Clear filters") {}
            }
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor private struct SearchOptionsFixture: View {
    @State private var timing = SearchTiming.pause
    @State private var text = true
    @State private var images = true
    @State private var audio = true
    @State private var video = true
    var body: some View {
        SearchOptionsView(timing: $timing, text: $text, images: $images,
                          audio: $audio, video: $video, isPro: true,
                          configuredModels: SearchScopeBadge.selected(mode: .all,
                            capabilities: SearchCapabilities(text: true, images: true, audio: true, video: true, imageModel: .clip),
                            level: .normal, pro: true), manageModels: {})
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
