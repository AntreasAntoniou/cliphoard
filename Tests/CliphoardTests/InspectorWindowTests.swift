import XCTest
import AppKit
@testable import Cliphoard

/// The inspector is its own floating panel, centred above the bar — no longer a `.sheet`
/// hung off the bar's window.
///
/// Three layers are pinned here. The geometry is a pure static and is asserted as
/// arithmetic. The model's change callback is asserted live: it must fire AFTER the value
/// changes (a `didSet`, not a `willSet`-timed publisher) and after `inspectorFocusTags`
/// has been set, because the presenter reads both. The AppKit wiring cannot be driven
/// headlessly — a live panel resigning key to another live panel — so it is asserted at the
/// source, the same way `PanelModalDismissalTests` pins the resign handler.
@MainActor
final class InspectorWindowTests: XCTestCase {

    private let size = NSSize(width: 680, height: 650)
    private let minHeight: CGFloat = 520
    private let gap: CGFloat = 12

    private func sourceRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func model() -> PanelViewModel {
        PanelViewModel(store: ClipStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoInspector-\(UUID().uuidString)")))
    }

    // MARK: - Geometry

    /// A laptop display: the band above a 380pt bar is shorter than the minimum height, so
    /// the frame takes the minimum, hugs the top and stays inside the screen.
    func testShortScreenShrinksToTheMinimumAndHugsTheTop() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let bar = NSRect(x: 0, y: 0, width: 1440, height: 380)
        let frame = InspectorWindowController.placement(size: size, minHeight: minHeight,
                                                        bar: bar, visible: visible)
        XCTAssertTrue(visible.contains(frame), "the inspector must never leave the screen: \(frame)")
        XCTAssertEqual(frame.midX, visible.midX, accuracy: 0.5, "centred horizontally")
        XCTAssertEqual(frame.height, minHeight, "height shrinks to the floor, not below it")
        XCTAssertLessThanOrEqual(frame.maxY, visible.maxY - gap, "hugs the top, inside the gap")
    }

    /// A large display: the full size fits, and the frame is centred in the band between the
    /// bar and the top of the screen.
    func testTallScreenTakesFullHeightCentredInTheBand() {
        let visible = NSRect(x: 0, y: 0, width: 2560, height: 1415)
        let bar = NSRect(x: 0, y: 0, width: 2560, height: 380)
        let frame = InspectorWindowController.placement(size: size, minHeight: minHeight,
                                                        bar: bar, visible: visible)
        XCTAssertEqual(frame.height, size.height)
        XCTAssertEqual(frame.width, size.width)
        XCTAssertGreaterThanOrEqual(frame.minY, bar.maxY + gap, "clears the bar by the gap")
        let bandMidY = ((bar.maxY + gap) + (visible.maxY - gap)) / 2
        XCTAssertEqual(frame.midY, bandMidY, accuracy: 0.5, "centred in the band above the bar")
        XCTAssertEqual(frame.midX, visible.midX, accuracy: 0.5, "centred horizontally")
        XCTAssertTrue(visible.contains(frame))
    }

    /// A display that went away yields nothing to place, not a 0×0 window at the origin.
    func testDegenerateScreenYieldsZero() {
        let bar = NSRect(x: 0, y: 0, width: 1440, height: 380)
        XCTAssertEqual(InspectorWindowController.placement(size: size, minHeight: minHeight,
                                                           bar: bar, visible: .zero), .zero)
    }

    // MARK: - Model

    /// `inspect` fires the change with the item, after `inspectorFocusTags` is already set;
    /// `closeInspector` fires it with nil.
    ///
    /// The stored property is sampled INSIDE the callback, because that is the claim: the
    /// presenter makes the bar resign key, and the resign handler reads `inspectedItem`
    /// directly. A `willSet`-timed callback (or a `$inspectedItem.sink`) would hand over the
    /// new value while the property still held the old one. Verified to bite: with
    /// `willSet { onInspectorChange?(newValue) }` the sampled value is stale on both edges.
    func testInspectAndCloseFireTheChangeCallbackInOrder() {
        let model = model()
        let item = ClipItem(kind: .text, text: "inspect me")
        var seen: [(item: ClipItem?, stored: ClipItem?, focusTags: Bool)] = []
        model.onInspectorChange = { [weak model] changed in
            seen.append((changed, model?.inspectedItem, model?.inspectorFocusTags ?? false))
        }

        model.inspect(item, focusTags: true)
        XCTAssertEqual(seen.count, 1, "inspect fires exactly once")
        XCTAssertEqual(seen.last?.item?.id, item.id, "fires with the inspected item")
        XCTAssertEqual(seen.last?.stored?.id, item.id,
                       "the callback runs after the stored value changed (didSet, not willSet)")
        XCTAssertTrue(seen.last?.focusTags ?? false,
                      "focusTags must already be set when the presenter reads it")

        model.closeInspector()
        XCTAssertEqual(seen.count, 2, "close fires exactly once")
        XCTAssertNil(seen.last?.item, "close fires with nil")
        XCTAssertNil(seen.last?.stored,
                     "the stored value is already nil when the dismissal callback runs")
        XCTAssertNil(model.inspectedItem)
    }

    // MARK: - Wiring, asserted at the source

    /// The `.sheet` is gone from the bar's view tree.
    func testTheSheetIsGoneFromContentView() throws {
        let source = try String(
            contentsOf: sourceRoot().appendingPathComponent("Sources/Cliphoard/UI/ContentView.swift"),
            encoding: .utf8)
        XCTAssertFalse(source.contains(".sheet(item: $model.inspectedItem"),
                       "the inspector is a floating panel now; a leftover .sheet would present "
                       + "the detail view twice")
    }

    /// The delegate subscribes to the model, and a dismissal closes the inspector BEFORE the
    /// bar slides out — while `isClosing` is already true, so the nil branch does not hand
    /// key focus back to a bar that is leaving.
    func testTheDelegateWiresTheInspectorAndClosesItBeforeSlidingOut() throws {
        let source = try String(
            contentsOf: sourceRoot().appendingPathComponent("Sources/Cliphoard/App/AppDelegate.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains("model.onInspectorChange ="),
                      "onInspectorChange is never assigned, so inspecting a clip shows nothing")

        guard let start = source.range(of: "private func hide(paste: Bool") else {
            return XCTFail("hide(paste:) was renamed — move this test with it")
        }
        let body = String(source[start.upperBound...].prefix(700))
        guard let close = body.range(of: "model.closeInspector()"),
              let slide = body.range(of: "panel.slideOut") else {
            return XCTFail("hide(paste:) must close the inspector and slide the bar out")
        }
        XCTAssertLessThan(close.lowerBound, slide.lowerBound,
                          "the inspector must be closed before the bar slides out")
        guard let closing = body.range(of: "isClosing = true") else {
            return XCTFail("hide(paste:) no longer marks isClosing")
        }
        XCTAssertLessThan(closing.lowerBound, close.lowerBound,
                          "closeInspector must run after isClosing is set, or the nil branch "
                          + "re-keys a bar that is on its way out")
    }
}
