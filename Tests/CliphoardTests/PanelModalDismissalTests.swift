import XCTest
import AppKit
@testable import Cliphoard

/// The panel must not dismiss itself when it opens a window on the user's behalf.
///
/// `resignKey` hides the panel, which is correct for "the user clicked away" and wrong for
/// "the user opened the thing we just offered them". Choosing a reference image put an
/// `NSOpenPanel` on screen, the floating panel resigned key, and the entire interface
/// vanished — the search ran correctly and its results were only visible after summoning the
/// panel again. A feature that works but hides its own output reads as broken.
///
/// The inspector sheet needed this exemption first (`inspectedItem != nil`). The file picker
/// is the second case. Two ad-hoc conditions is where a named flag earns its place — the
/// third would have been written as another inline `if` and eventually one of them would be
/// forgotten.
@MainActor
final class PanelModalDismissalTests: XCTestCase {

    private func model() -> PanelViewModel {
        PanelViewModel(store: ClipStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoModal-\(UUID().uuidString)")))
    }

    /// The flag exists and defaults to NOT suppressing. A default of `true` would make the
    /// panel impossible to dismiss by clicking away, which is a worse bug than the one fixed.
    func testTheSuppressionFlagDefaultsToOff() {
        XCTAssertFalse(model().isPresentingSystemPanel,
                       "hide-on-resign must be active by default; only an explicitly opened "
                       + "system window may suspend it")
    }

    /// The resign handler must consult the flag. Asserted at the source because the real
    /// path needs a live NSPanel resigning key to an NSOpenPanel, which cannot be driven
    /// headlessly — and asserting nothing here would leave the actual fix untested.
    func testTheResignHandlerHonoursBothExemptions() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Cliphoard/App/AppDelegate.swift"),
            encoding: .utf8)
        guard let start = source.range(of: "panel.onResignKey = ") else {
            return XCTFail("onResignKey wiring was renamed — move this test with it")
        }
        let body = String(source[start.upperBound...].prefix(900))

        XCTAssertTrue(body.contains("self.model.inspectedItem != nil"),
                      "the inspector-sheet exemption disappeared; opening a clip's detail "
                      + "view would dismiss the panel underneath it")
        XCTAssertTrue(body.contains("self.model.isPresentingSystemPanel"),
                      "the file-picker exemption is missing — choosing a reference image "
                      + "will dismiss the interface before its results can be seen")

        // Order matters: both guards must precede the hide, not follow it.
        guard let hide = body.range(of: "self.hide(paste: false)"),
              let guardFlag = body.range(of: "self.model.isPresentingSystemPanel") else {
            return XCTFail("could not locate both the guard and the hide")
        }
        XCTAssertLessThan(guardFlag.lowerBound, hide.lowerBound,
                          "the exemption is checked AFTER hiding, which does nothing")
    }

    /// The flag must be cleared on every exit path, including cancel. A leaked `true` leaves
    /// the panel permanently un-dismissable — quieter than the original bug and worse.
    func testTheFlagIsClearedOnEveryPathIncludingCancel() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Cliphoard/UI/ContentView.swift"),
            encoding: .utf8)
        guard let start = source.range(of: "private func chooseReferenceImage()") else {
            return XCTFail("chooseReferenceImage was renamed")
        }
        let body = String(source[start.upperBound...].prefix(1600))

        XCTAssertTrue(body.contains("model.isPresentingSystemPanel = true"),
                      "the picker no longer suspends hide-on-resign")
        XCTAssertTrue(body.contains("defer {"),
                      "clearing must happen in a `defer`. The function returns early on "
                      + "cancel AND on an unreadable file; a plain assignment after "
                      + "runModal() is skipped by both, stranding the flag at true.")
        guard let deferRange = body.range(of: "defer {") else { return XCTFail("no defer") }
        let deferBody = String(body[deferRange.upperBound...].prefix(300))
        XCTAssertTrue(deferBody.contains("model.isPresentingSystemPanel = false"),
                      "the defer must clear the flag")
        XCTAssertTrue(deferBody.contains("onRequestFocus"),
                      "the panel stays visible but loses key focus to the modal, so focus "
                      + "must be requested back or the results are visible and inert")
    }

    /// Focus restoration must actually reach the panel.
    func testFocusRestorationIsWiredToThePanel() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Cliphoard/App/AppDelegate.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains("model.onRequestFocus = "),
                      "onRequestFocus is never assigned, so the view's call is a no-op and "
                      + "the keyboard stays dead after the picker closes")
        guard let start = source.range(of: "model.onRequestFocus = ") else { return }
        let body = String(source[start.upperBound...].prefix(400))
        XCTAssertTrue(body.contains("makeKeyAndOrderFront"),
                      "restoring focus must make the panel key again")
        XCTAssertTrue(body.contains("self.isVisible"),
                      "it must not resurrect a panel the user has since dismissed")
    }
}
