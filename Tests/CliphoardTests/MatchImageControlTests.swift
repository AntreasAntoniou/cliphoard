import XCTest
import AppKit
@testable import Cliphoard

/// The "search by image" control: available everywhere, icon-only, and never inert.
///
/// Making it icon-only and putting it in every mode created two ways to ship something
/// broken that still compiles and still looks fine in a screenshot:
///
///   1. An SF Symbol that does not exist on the deployment target renders as EMPTY SPACE.
///      It does not throw, does not warn, and does not fall back — the button simply becomes
///      invisible. With a text label that would have been survivable; without one there is
///      nothing left to click.
///   2. The reference image only ranks IMAGE clips. Offering the control in Exact or Tag mode
///      without switching modes would open a file panel, accept a picture, and change
///      nothing — the exact defect `FrozenControlsTests` exists to catch, in a control that
///      no longer has text to explain itself.
@MainActor
final class MatchImageControlTests: XCTestCase {

    /// The symbol must actually resolve. Asserted against the SAME API the view uses, so a
    /// symbol that vanishes on some future OS fails the build rather than the button.
    func testTheMatchImageSymbolResolvesOnThisSystem() {
        let name = ContentView.matchImageSymbol
        XCTAssertNotNil(
            NSImage(systemSymbolName: name, accessibilityDescription: nil),
            "the match-image button resolved to '\(name)', which does not exist here. An "
            + "unavailable SF Symbol renders as blank space, so the control would be "
            + "invisible rather than obviously broken — and it has no text label to fall "
            + "back on.")
    }

    /// The fallback must be reachable, not decorative. If the preferred symbol were ever the
    /// only option, the macOS 13 path would be untested and this whole guard would be theatre.
    func testTheFallbackSymbolAlsoExists() {
        XCTAssertNotNil(
            NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil),
            "the fallback symbol must exist on every supported OS — it is what macOS 13 "
            + "users see, and this project's deployment target is macOS 13")
    }

    /// Whichever branch was taken, it is one of the two we vetted — not an empty string or
    /// something a refactor introduced without checking availability.
    func testTheResolvedSymbolIsOneOfTheTwoVettedNames() {
        XCTAssertTrue(
            ["photo.badge.magnifyingglass", "camera.viewfinder"].contains(ContentView.matchImageSymbol),
            "unexpected symbol '\(ContentView.matchImageSymbol)' — a new one must be checked "
            + "for availability on macOS 13 before it ships, because the failure is silent")
    }

    /// Picking a reference must leave the app in a mode where the reference DOES something.
    /// Asserted at the source, because the alternative is driving an NSOpenPanel in a test.
    func testChoosingAReferenceSwitchesIntoImageMode() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Cliphoard/UI/ContentView.swift"),
            encoding: .utf8)

        guard let start = source.range(of: "private func chooseReferenceImage()") else {
            return XCTFail("chooseReferenceImage was renamed — move this test with it")
        }
        // Bounded by the NEXT declaration, not by a character count. The first version took
        // a fixed 1400-char prefix and started failing the moment the function grew — a
        // `defer` block was added above the assertion it was looking for, pushing it out of
        // the window. The code was correct; the test's idea of "the function" was not.
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private ") ?? rest.range(of: "\n    var ")
        let body = String(rest[..<(end?.lowerBound ?? rest.endIndex)])
        XCTAssertTrue(body.contains("model.referenceImage = "),
                      "the picker no longer stores the chosen image")
        XCTAssertTrue(body.contains("settings.searchMode = .image"),
                      "choosing a reference image must switch the search mode to .image. The "
                      + "reference only ranks image clips, so in any other mode the user "
                      + "would pick a file and watch nothing happen — with no text on the "
                      + "button to hint at why.")
    }

    /// The control is gated on the MODEL being loaded, not on the mode. Both halves matter:
    /// available everywhere (the point of this change) but never when it cannot work.
    func testTheControlIsGatedOnTheModelNotOnTheMode() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Cliphoard/UI/ContentView.swift"),
            encoding: .utf8)
        guard let start = source.range(of: "private var referenceImagePicker") else {
            return XCTFail("referenceImagePicker was renamed — move this test with it")
        }
        let body = String(source[start.upperBound...].prefix(900))
        XCTAssertTrue(body.contains("store.clipEmbedder != nil"),
                      "the control must still disappear when the towers are absent, or it "
                      + "opens a file panel and can never rank anything")
        XCTAssertFalse(body.contains("searchMode == .image"),
                       "the control is no longer restricted to Image mode — that restriction "
                       + "is what hid it from everyone who had not already found the mode")
    }

    /// Icon-only controls need an accessible name, or VoiceOver announces an unnamed button.
    /// The text label was the accessible name until this change removed it.
    func testTheIconOnlyControlStillHasAnAccessibleName() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Cliphoard/UI/ContentView.swift"),
            encoding: .utf8)
        guard let start = source.range(of: "private var referenceImagePicker") else {
            return XCTFail("referenceImagePicker was renamed")
        }
        let body = String(source[start.upperBound...].prefix(2600))
        XCTAssertTrue(body.contains(#"accessibilityLabel("Search by image")"#),
                      "an icon-only button with no accessibility label is unidentifiable to "
                      + "VoiceOver — the visible text used to serve as its name")
        XCTAssertTrue(body.contains(".help("),
                      "sighted users lost the label too; the tooltip is now the only thing "
                      + "that explains what the icon does")
    }
}
