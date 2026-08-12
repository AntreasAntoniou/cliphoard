import XCTest
import AppKit
import SwiftUI
@testable import Cliphoard

/// The bar's height, and what it is allowed to take that height from.
///
/// The defect: `FloatingPanel.barHeight` was a constant 380, and every conditional
/// chrome row `ContentView` stacks above the card strip — safe-mode banner,
/// paste-blocked banner, indexing bar — took its height out of that 380. The card
/// is a fixed `Theme.cardWidth × Theme.cardHeight` and never squeezes, so the strip
/// did not get denser, it got CLIPPED: with the safe-mode banner up, the bottom row
/// of every card ("51 characters", "4 min 20 sec") was simply gone.
///
/// Everything asserted here is arithmetic or a headless measurement, deliberately.
/// SwiftUI on macOS only creates NSViews for AppKit-backed controls — a rendered
/// card produces no NSView at all (a walk of the presented tree finds nine views,
/// of which the only landmark is the search field's `NSTextField`) — so a test that
/// hunts for a card in the view tree cannot fail for the right reason. The geometry
/// is therefore a pure function, and the chrome cap is a named view.
@MainActor
final class PanelHeightTests: XCTestCase {

    /// A stand-in for a real display. Origin deliberately non-zero: the bar is
    /// anchored to a screen's visible frame, not to zero, and a fix that happened
    /// to work on the main screen and nowhere else should not pass.
    private let visible = NSRect(x: 120, y: 60, width: 1440, height: 1000)

    // MARK: - What the card strip is owed

    /// The strip must reserve a WHOLE card plus its inset. This is the number the
    /// old 380 was 10pt short of, before a single banner appeared.
    ///
    /// Kills: `stripHeight = t.cardHeight` (drops the 14pt top/bottom inset, so the
    /// first and last rows of every card clip), and any return to a constant.
    func testStripReservesAWholeCardPlusItsInset() {
        XCTAssertGreaterThanOrEqual(Theme.stripHeight, Theme.cardHeight + 28,
            "The strip must hold a whole card and both 14pt insets, or the card is clipped.")
    }

    /// The clean bar — no banner, no indexing — is taller than the constant it
    /// replaced. Growing the panel by the chrome height alone would have preserved
    /// this 10pt bug in the state the user is in almost all the time.
    ///
    /// Kills: `minBarHeight` being treated as the resting height rather than a floor.
    func testTheCleanBarIsTallerThanTheConstantItReplaced() {
        let fixedChrome: CGFloat = 8 + 70 + 1 + 33   // top pad, toolbar, divider, footer
        let clean = FloatingPanel.barFrame(visible: visible,
                                           contentHeight: fixedChrome + Theme.stripHeight)
        XCTAssertEqual(clean.height, 390, accuracy: 0.5)
        XCTAssertGreaterThan(clean.height, 380,
            "A clean bar at the old constant clipped the strip by 10pt before any chrome existed.")
    }

    // MARK: - Where the bar sits, however tall it gets

    /// However much chrome appears, the bar grows UPWARD from the screen's bottom
    /// edge. Growing it any other way walks the bar off the bottom of the display.
    ///
    /// Kills: anchoring on `frame.minY` (the window's own, which AppKit drifts
    /// downward by 12pt on every implicit content resize), centring the bar, or
    /// keeping `maxY` fixed.
    func testTheBarIsAnchoredAtTheScreenBottomAtEveryHeight() {
        for content in [CGFloat(200), 380, 390, 512, 630, 5000] {
            let f = FloatingPanel.barFrame(visible: visible, contentHeight: content)
            XCTAssertEqual(f.minY, visible.minY, accuracy: 0.5,
                           "content height \(content) moved the bar off the screen edge")
            XCTAssertEqual(f.minX, visible.minX, accuracy: 0.5)
            XCTAssertEqual(f.width, visible.width, accuracy: 0.5)
        }
    }

    /// A bar that wants more than the display has gets the display, not more.
    ///
    /// Kills: dropping the `min(_, visible.height)` clamp.
    func testTheBarNeverOutgrowsTheScreen() {
        let f = FloatingPanel.barFrame(visible: visible, contentHeight: 5000)
        XCTAssertEqual(f.height, visible.height, accuracy: 0.5)
        XCTAssertLessThanOrEqual(f.maxY, visible.maxY + 0.5)
    }

    /// And a bar whose content somehow measures tiny still opens at its floor.
    ///
    /// Kills: dropping the `max(_, minBarHeight)` clamp — which would let a
    /// mis-measured tree (an unpinned body region reports 141pt) collapse the bar.
    func testTheBarNeverCollapsesBelowItsFloor() {
        let f = FloatingPanel.barFrame(visible: visible, contentHeight: 10)
        XCTAssertEqual(f.height, FloatingPanel.minBarHeight, accuracy: 0.5)
    }

    /// The dismissed bar clears the screen COMPLETELY at whatever height it had.
    ///
    /// This is the bug a naive fix introduces: the old `slideOut` pushed the window
    /// down by the constant 380, so once the bar can be 512pt tall, sliding it out
    /// by 380 leaves 132pt of bar sitting on the screen edge after it is "closed".
    ///
    /// Kills: any off-screen frame computed from a constant instead of the bar's
    /// actual height.
    func testTheDismissedBarFullyClearsTheScreenAtEveryHeight() {
        for content in [CGFloat(380), 390, 512, 630] {
            let off = FloatingPanel.offScreenFrame(visible: visible, contentHeight: content)
            let on = FloatingPanel.barFrame(visible: visible, contentHeight: content)
            XCTAssertLessThanOrEqual(off.maxY, visible.minY + 0.5,
                "a \(on.height)pt bar left \(off.maxY - visible.minY)pt on screen after sliding out")
            XCTAssertEqual(off.height, on.height, accuracy: 0.5)
        }
    }

    // MARK: - The chrome cap

    /// An empty chrome group costs the strip nothing. The cap is on the common
    /// path — it wraps rows that are absent almost always — so if the wrapper
    /// itself reserved height it would tax every summon to fix a rare state.
    ///
    /// Kills: implementing the cap with `minHeight`, a fixed `frame(height:)`, or
    /// any padding on the wrapper.
    func testAnEmptyChromeGroupCostsNothing() {
        let host = NSHostingController(rootView: BoundedChrome { EmptyView() })
        let h = host.sizeThatFits(in: CGSize(width: CGFloat(1440), height: .infinity)).height
        XCTAssertEqual(h, 0, accuracy: 0.5, "an absent banner must not reserve height")
    }

    /// Chrome under the cap renders at its natural height — the cap must not
    /// squash a banner that fits.
    ///
    /// Kills: a cap applied as `frame(height:)` rather than `frame(maxHeight:)`.
    func testChromeUnderTheCapKeepsItsNaturalHeight() {
        let host = NSHostingController(rootView: BoundedChrome {
            Color.clear.frame(height: 42)
        })
        let h = host.sizeThatFits(in: CGSize(width: CGFloat(1440), height: .infinity)).height
        XCTAssertEqual(h, 42, accuracy: 0.5)
    }

    /// Chrome past the cap scrolls. The strip gives up nothing — which is the whole
    /// difference between capping the CHROME and clamping the WINDOW: a window clamp
    /// hands the shortfall back to the card area and quietly restores the original bug.
    ///
    /// Kills: removing `frame(maxHeight: Theme.chromeMaxHeight)`.
    func testChromePastTheCapScrollsInsteadOfEatingTheStrip() {
        let host = NSHostingController(rootView: BoundedChrome {
            Color.clear.frame(height: 400)
        })
        let h = host.sizeThatFits(in: CGSize(width: CGFloat(1440), height: .infinity)).height
        XCTAssertEqual(h, Theme.chromeMaxHeight, accuracy: 0.5)
    }

    /// Even with both chrome groups pinned at the cap, the bar fits a real display.
    ///
    /// Kills: raising `chromeMaxHeight` to a value that pushes the bar past the
    /// shortest Mac's visible frame (a 1024x640 display has roughly 615pt of it).
    func testTheWorstCaseBarStillFitsTheShortestMacDisplay() {
        let fixedChrome: CGFloat = 8 + 70 + 1 + 33
        let worst = fixedChrome + Theme.stripHeight + 2 * Theme.chromeMaxHeight
        XCTAssertLessThanOrEqual(worst, 615,
            "worst-case bar is \(worst)pt; a 1024x640 display offers about 615pt of visible frame")
    }

    // MARK: - How the height is measured

    /// The measurement must be WIDTH-AWARE. `fittingSize`, `intrinsicContentSize`
    /// and `preferredContentSize` all answer at the content's IDEAL width — for
    /// this tree that is the width of the entire card strip, thousands of points —
    /// so a banner that wraps on a narrow display is measured unwrapped and the bar
    /// comes up exactly one text line too short. Which is the original bug, back.
    ///
    /// Kills: `contentHeight` using `view.fittingSize.height`.
    func testTheContentMeasurementIsWidthAware() {
        let wrapping = VStack(spacing: 0) {
            Text("Your clips are safe — macOS wouldn’t unlock the key just now, usually "
                 + "because the Mac was asleep when Cliphoard started. Quit and reopen it "
                 + "while you’re here, and approve any keychain prompt.")
                .font(.system(size: 10))
            Color.clear.frame(height: 278)
        }
        let host = NSHostingController(rootView: wrapping)
        host.view.layoutSubtreeIfNeeded()
        let ideal = host.view.fittingSize.height
        let narrow = host.sizeThatFits(in: CGSize(width: CGFloat(700), height: .infinity)).height
        XCTAssertGreaterThan(narrow, ideal,
            "fittingSize answered at the content's ideal width and missed the wrapped line")
    }

    /// The height must not depend on the height the bar is currently given, or
    /// feeding it back into the window is a fixed point at any value — including
    /// the wrong one it already has. A pinned body region makes the answer a
    /// constant, so the window converges in one step.
    ///
    /// Kills: restoring `maxHeight: .infinity` on the body region in `ContentView`.
    func testTheMeasuredHeightDoesNotDependOnTheHeightOffered() {
        let pinned = VStack(spacing: 0) {
            Color.clear.frame(height: 70)
            ScrollView(.horizontal) { Color.clear.frame(width: 4000, height: 250) }
                .frame(height: Theme.stripHeight)
            Color.clear.frame(height: 33)
        }
        let host = NSHostingController(rootView: pinned)
        let answers = [CGFloat(200), 380, 800, 2000, .infinity].map {
            host.sizeThatFits(in: CGSize(width: CGFloat(1440), height: $0)).height
        }
        XCTAssertEqual(Set(answers).count, 1,
            "the tree answered the window's own height back at it: \(answers)")
    }
}
