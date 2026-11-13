import XCTest
import SwiftUI
import AppKit
@testable import Cliphoard

@MainActor
final class SearchControlPresentationTests: XCTestCase {
    private final class ClickHostingView<V: View>: NSHostingView<V> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
    func testExactTextBadgeDoesNotPromiseAnUnusedConfiguredModel() {
        let capabilities = SearchCapabilities(text: true, images: true, audio: false, video: false, imageModel: .clip)
        XCTAssertEqual(SearchScopeBadge.selected(mode: .all, capabilities: capabilities, level: .normal,
            pro: true, matching: .exact).map(\.label), ["Text · Exact", "Images · CLIP"])
        XCTAssertEqual(SearchScopeBadge.selected(mode: .text, capabilities: capabilities, level: .normal,
            pro: true, matching: .smart).map(\.label), ["Text · Ogma Small"])
    }
    func testAllTypesKeepsSavedScopeAndBadgesDescribeConfiguredSelection() {
        XCTAssertEqual(SearchControlLabels.scope(.all), "All content")
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

    func testToolbarKeepsIntentionalQueryAndFilterRows() {
        _ = NSApplication.shared
        let host = NSHostingController(rootView: SearchBarFixture(pending: false))
        let narrow = host.sizeThatFits(in: CGSize(width: 640, height: CGFloat.infinity))
        let wide = host.sizeThatFits(in: CGSize(width: 1440, height: CGFloat.infinity))
        XCTAssertLessThanOrEqual(narrow.width, 641)
        XCTAssertGreaterThanOrEqual(wide.height, 90)
        XCTAssertLessThanOrEqual(wide.height, 110)
        XCTAssertLessThanOrEqual(narrow.height, 160)
    }

    func testSettingsAndModelsButtonsHaveStableDistinctTargets() async throws {
        _ = NSApplication.shared
        XCTAssertNotNil(NSImage(systemSymbolName: "cpu", accessibilityDescription: nil))
        for width in [640.0, 1440.0] {
            var openedSettings = 0
            var openedModels = 0
            let host = ClickHostingView(rootView: SearchBarFixture(pending: false,
                settingsAction: { openedSettings += 1 }, optionsAction: { openedModels += 1 }))
            let measure = NSHostingController(rootView: SearchBarFixture(pending: false))
            let height = measure.sizeThatFits(in: CGSize(width: width, height: .infinity)).height
            let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: width, height: height),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            window.orderBack(nil)
            try await Task.sleep(nanoseconds: 100_000_000)
            print("TOOLBAR click width=\(width) host=\(host.bounds) frame=\(window.frame)")
            for (x, top) in [(width - 34, 28.0), (width - 75, 73.0)] {
                let point = host.convert(NSPoint(x: x, y: host.isFlipped ? top : host.bounds.height - top), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                    window.sendEvent(event)
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertEqual(openedSettings, 1, "Settings must be reachable at the top-right at width \(width)")
            XCTAssertEqual(openedModels, 1, "Models and search must have a separate second-row target")
        }
    }

    func testToolbarMenuItemsExplainEachChoice() throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: SearchBarFixture(pending: false))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 150),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        func menus(_ view: NSView) -> [NSPopUpButton] {
            (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(menus)
        }
        let controls = menus(host)
        XCTAssertEqual(controls.count, 2)
        for control in controls {
            let items = control.itemArray.filter { !$0.title.isEmpty && !$0.isSeparatorItem }
            XCTAssertGreaterThanOrEqual(items.count, 4)
            for item in items {
                XCTAssertFalse((item.toolTip ?? "").isEmpty, "Missing hover explanation: \(item.title)")
            }
        }
        window.close()
    }

    func testQuickOptionsFitsItsCompactPopover() throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: SearchOptionsFixture())
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 480)
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(host.fittingSize.width, 361)
        XCTAssertLessThanOrEqual(host.fittingSize.height, 480)
        if let output = ProcessInfo.processInfo.environment["CLIPHOARD_SEARCH_UI_SNAPSHOTS"] {
            try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("search-options.png"), options: .withoutOverwriting)
        }
    }

    func testSelectedLightPaletteRendersWithExistingLogoAndRealCards() throws {
        _ = NSApplication.shared
        let old = Theme.preset
        Theme.preset = .floatingPalette
        defer { Theme.preset = old }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let logo = try XCTUnwrap(NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.png")))
        let items = [ClipItem(kind: .text, text: "Project notes\nChoose the next design direction."),
                     ClipItem(kind: .link, text: "https://example.com"),
                     ClipItem(kind: .color, text: "#138B83"),
                     ClipItem(kind: .file, text: "Project brief.pdf")]
        let view = VStack(spacing: 0) {
            SearchBarFixture(pending: false, brandImage: logo)
            Divider()
            HStack(spacing: 14) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    ClipCardView(item: item, index: index, selected: index == 0,
                        storeDir: FileManager.default.temporaryDirectory,
                        onActivate: {}, onInspect: {}, onInspectTags: {}, onPin: {}, onDelete: {},
                        historyIsMutable: true)
                }
                Spacer()
            }.padding(14)
            Text("← → Navigate     ↵ Copy & Close     ⌘C Copy     Esc Close     ? Shortcuts")
                .font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }.frame(width: 1440).background(Theme.barBackground()).preferredColorScheme(.light)
            .environment(\.colorScheme, .light)
        let panel = FloatingPanel()
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        panel.setContent { view }
        panel.fit(to: NSRect(x: 0, y: 0, width: 1440, height: 900))
        let host = try XCTUnwrap(panel.contentView)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertLessThan(panel.frame.height, 450)
        XCTAssertEqual(Theme.preset, .floatingPalette)
        if let output = ProcessInfo.processInfo.environment["CLIPHOARD_SEARCH_UI_SNAPSHOTS"] {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                to: URL(fileURLWithPath: output).appendingPathComponent("floating-palette-native.png"),
                options: .withoutOverwriting)
        }
    }

    func testPopoverModelMenusChangeBindingsAndRespectExactAndFree() throws {
        _ = NSApplication.shared
        var chosenText = DeepSearchLevel.normal
        var chosenImage = ImageSearchModel.clip
        for (pro, matching) in [(true, SearchMode.smart), (false, .exact)] {
            let host = NSHostingView(rootView: SearchOptionsView(timing: .constant(.pause),
                text: .constant(true), images: .constant(true), audio: .constant(false), video: .constant(false),
                textModel: Binding(get: { chosenText }, set: { chosenText = $0 }),
                imageModel: Binding(get: { chosenImage }, set: { chosenImage = $0 }),
                isPro: pro, matching: matching, manageModels: {}))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            func menus(_ view: NSView) -> [NSPopUpButton] {
                (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(menus)
            }
            let controls = menus(host)
            for control in controls {
                for item in control.itemArray where !item.isSeparatorItem && !item.title.isEmpty {
                    XCTAssertFalse((item.toolTip ?? "").isEmpty, "Missing hover explanation: \(item.title)")
                }
            }
            let textMenu = try XCTUnwrap(controls.first { $0.itemTitles.contains("MiniLM") })
            let imageMenu = try XCTUnwrap(controls.first { $0.itemTitles.contains("CLIP · OpenVision") })
            XCTAssertEqual(textMenu.isEnabled, matching != .exact)
            XCTAssertEqual(imageMenu.isEnabled, pro)
            if pro {
                let textItems = try XCTUnwrap(textMenu.menu)
                textItems.performActionForItem(at: textMenu.indexOfItem(withTitle: "MiniLM"))
                let imageItems = try XCTUnwrap(imageMenu.menu)
                imageItems.performActionForItem(at: imageMenu.indexOfItem(withTitle: "EmbeddingGemma 2"))
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                XCTAssertEqual(chosenText, .high)
                XCTAssertEqual(chosenImage, .gemma2)
            }
            window.close()
        }
    }
}

@MainActor private struct SearchBarFixture: View {
    let pending: Bool
    var settingsAction: () -> Void = {}
    var optionsAction: () -> Void = {}
    var brandImage: NSImage? = nil
    @State private var query = "cat"
    @State private var scope = SearchModality.all
    @FocusState private var focused: Bool
    var body: some View {
        SearchBarView(query: $query, scope: $scope, matching: .constant(.smart), searchFocused: $focused,
                      isPro: true, openOptions: optionsAction, openSettings: settingsAction, isPending: pending,
                      timing: pending ? .enter : .pause, submitSearch: {},
                      badges: SearchScopeBadge.selected(mode: .all,
                        capabilities: SearchCapabilities(text: true, images: true, audio: true, video: true, imageModel: .clip),
                        level: .normal, pro: true), brandImage: brandImage) {
            Group {
                Label("Clip type", systemImage: "line.3.horizontal.decrease")
                Label("Pinned", systemImage: "pin.fill")
                Label("Time", systemImage: "clock")
                Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                Label("reference-picture.png", systemImage: "photo.fill").frame(width: 170)
                Button("Clear filters") {}
            }
        }.background(Theme.barBackground())
    }
}

@MainActor private struct SearchOptionsFixture: View {
    @State private var timing = SearchTiming.pause
    @State private var text = true
    @State private var images = true
    @State private var audio = true
    @State private var video = true
    @State private var textModel = DeepSearchLevel.normal
    @State private var imageModel = ImageSearchModel.clip
    var body: some View {
        SearchOptionsView(timing: $timing, text: $text, images: $images,
                          audio: $audio, video: $video,
                          textModel: $textModel, imageModel: $imageModel,
                          isPro: true, manageModels: {})
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
