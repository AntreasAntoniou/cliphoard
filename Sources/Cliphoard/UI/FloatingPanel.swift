import AppKit
import SwiftUI

/// A borderless panel pinned to the bottom of the active screen that slides up
/// into view — the signature Paste-style presentation.
///
/// The bar sizes itself to its content rather than to a constant. It used to be
/// a hard-coded 380pt, and every conditional chrome row `ContentView` puts above
/// the card strip — the safe-mode banner, the paste-blocked banner, the indexing
/// bar — took its height out of that 380, shrinking the strip's viewport until
/// the cards were clipped. `ClipCardView` is a fixed `Theme.cardHeight` and never
/// squeezes, so what a user saw was the bottom row of every card cut off.
final class FloatingPanel: NSPanel {
    /// Floor for the bar's height, and the size it opens at before the SwiftUI
    /// tree has ever been measured. Not the resting height — see `fit`.
    static let minBarHeight: CGFloat = 380

    /// Generous allowance for the rows that are always present — toolbar, divider, footer and
    /// the outer top pad, measured at 112pt together. Used only to bound a runaway measurement
    /// (see `barFrame`), so it is deliberately loose: it must never clip a legitimate layout,
    /// only refuse an impossible one.
    static let fixedChromeAllowance: CGFloat = 180

    /// The tallest the layout can legitimately be, derived from its own constants: the body
    /// region is pinned to `stripHeight`, each of the two chrome groups is capped at
    /// `chromeMaxHeight`, and the always-present rows are bounded by `fixedChromeAllowance`.
    /// Reads `Theme`, so it must only be evaluated where `NSApp` exists.
    static var layoutCeiling: CGFloat {
        Theme.stripHeight + 2 * Theme.chromeMaxHeight + fixedChromeAllowance
    }

    var onResignKey: (() -> Void)?

    /// Stored hosting controller so the SwiftUI tree can be re-evaluated on every
    /// present. Kept as the panel's `contentViewController` — see `setContent`
    /// and `refresh`. The bug this fixes: previously the hosting view was a local
    /// in `setContent`, assigned once at launch, so an ordered-out panel never
    /// re-rendered `ContentView` against fresh `ClipStore` state on reopen.
    ///
    /// Typed as `NSHostingController` rather than `NSViewController` because
    /// `fit` needs `sizeThatFits(in:)`, which is the only width-aware measurement
    /// AppKit offers here.
    private var hostingController: NSHostingController<AnyView>?
    /// Builds the current root view; reset by `setContent` on each present so the
    /// captured `model`/`store` references stay valid.
    private var makeRootView: (() -> NSHostingController<AnyView>)?

    /// The screen the bar was presented on. `slideOut` must dismiss on THIS
    /// screen: `targetScreen()` follows the mouse, so moving the cursor to
    /// another display while the bar was up and then pressing esc slid it out
    /// against the wrong screen's geometry — it appeared to jump.
    private var presentedScreen: NSScreen?

    /// Re-fit cadence while the bar is up. A chrome row appearing changes the
    /// content's height with no notification we can observe:
    /// `preferredContentSizeDidChange` and KVO on `preferredContentSize` were
    /// both measured to fire exactly zero times across every state change. So
    /// the bar asks rather than waits. A `sizeThatFits` over a 200-card lazy
    /// strip measured at 0.014ms, i.e. 0.04% of one frame per second.
    private var fitTimer: Timer?

    /// True only while the bar is fully presented and NOT animating. Both `fit`
    /// and the bottom re-anchor are gated on it so neither fights the slide.
    private var isSettled = false

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: FloatingPanel.minBarHeight),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .mainMenu + 1
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .none
        delegate = self
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // MARK: Geometry

    /// The bar's on-screen frame: full width, anchored at the screen's bottom
    /// edge, grown UPWARD to hold `contentHeight`.
    ///
    /// Pure, and static, so the geometry can be asserted without a window — the
    /// interesting claims (never off the bottom, never taller than the screen,
    /// never below the floor) are all arithmetic.
    static func barFrame(visible: NSRect, contentHeight: CGFloat, ceiling: CGFloat) -> NSRect {
        // A DEGENERATE screen rect means the display went away — unplugged, or a stale
        // `NSScreen` we are still holding. `min(max(h, 380), 0)` is 0, because the clamp is
        // applied AFTER the floor with nothing beneath it, so the bar would become a 0x0
        // window at the origin, still key, pinned there by the 30Hz re-fit. Refuse instead:
        // an unchanged frame is a bar that is still where the user left it, and the next
        // dismissal recovers normally.
        guard visible.height > 1, visible.width > 1 else { return .zero }
        // `ceiling` is what the LAYOUT can legitimately need — see `layoutCeiling`. Clamping
        // only to the screen is how one bad measurement walked the bar off the top of it.
        //
        // Taken as a PARAMETER rather than read here, and this is not fussiness: `Theme` reads
        // `NSApp.effectiveAppearance`, which is nil in a test process, so touching it from this
        // function made a pure arithmetic helper crash depending on which test ran first. The
        // geometry stays pure; the app supplies the number.
        let height = min(max(contentHeight, minBarHeight), min(ceiling, visible.height))
        return NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: height)
    }

    /// Where the bar waits before sliding in and returns to after sliding out:
    /// the same frame pushed exactly its own height below the screen edge, so a
    /// taller bar still clears the screen completely.
    static func offScreenFrame(visible: NSRect, contentHeight: CGFloat,
                               ceiling: CGFloat = .greatestFiniteMagnitude) -> NSRect {
        let onScreen = barFrame(visible: visible, contentHeight: contentHeight, ceiling: ceiling)
        return NSRect(x: onScreen.minX, y: visible.minY - onScreen.height,
                      width: onScreen.width, height: onScreen.height)
    }

    /// What the SwiftUI tree needs at a given width.
    ///
    /// Width-aware on purpose. `fittingSize`, `intrinsicContentSize` and
    /// `preferredContentSize` all answer at the content's IDEAL width — measured
    /// at 5129pt for this tree, the width of the whole card strip — so on a
    /// narrow display a banner that wraps under-reports by exactly the wrapped
    /// line (432 vs 445 at a 700pt panel) and the clipping comes straight back.
    private func contentHeight(width: CGFloat) -> CGFloat {
        guard let controller = hostingController else { return Self.minBarHeight }
        return controller.sizeThatFits(in: CGSize(width: width, height: .infinity)).height
    }

    /// Size the bar to its content, anchored at the screen's bottom edge.
    func fit() {
        guard isSettled, let screen = presentedScreen ?? targetScreen() else { return }
        let visible = screen.visibleFrame
        let target = Self.barFrame(visible: visible,
                                   contentHeight: contentHeight(width: visible.width),
                                   ceiling: Self.layoutCeiling)
        // `.zero` means the screen is gone (see `barFrame`). Leave the bar exactly where it
        // is rather than resizing it to nothing.
        guard target != .zero else { return }
        guard abs(target.height - frame.height) > 0.5
            || abs(target.minY - frame.minY) > 0.5
            || abs(target.width - frame.width) > 0.5 else { return }
        setFrame(target, display: true)
    }

    private func startFitting() {
        stopFitting()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.fit() }
        // `.default`, NOT `.common`. This was `.common` — "so the bar keeps tracking its
        // content during menu and scroll tracking loops" — and that reasoning was exactly
        // backwards. `.common` includes `.eventTracking`, so the timer fired while an NSMenu
        // was open, `sizeThatFits` was measured against a perturbed tree, and every fire grew
        // the bar: opening the search-mode picker walked the panel up until it filled the
        // screen. A tracking loop is precisely when the window must NOT be resized out from
        // under the menu the user is reading. Default mode does not fire during tracking, and
        // the first fire afterwards catches up.
        RunLoop.main.add(timer, forMode: .default)
        fitTimer = timer
    }

    private func stopFitting() {
        fitTimer?.invalidate()
        fitTimer = nil
    }

    // MARK: Content

    /// Install the SwiftUI content. The closure is retained and re-invoked by
    /// `refresh()` so each present rebuilds a fresh `NSHostingController` —
    /// guaranteeing the tree is re-evaluated against current `ClipStore` state.
    func setContent<Content: View>(_ build: @escaping () -> Content) {
        makeRootView = { NSHostingController(rootView: AnyView(build())) }
        refresh()
    }

    /// Re-evaluate the SwiftUI content from scratch. Called on every present so
    /// the freshly-summoned bar reflects the latest store contents even though
    /// the panel spent its life `orderOut`. Rebuilds the hosting controller,
    /// installs it as `contentViewController`, and forces a synchronous layout.
    func refresh() {
        guard let make = makeRootView else { return }
        let controller = make()
        controller.view.autoresizingMask = [.width, .height]
        hostingController = controller
        contentViewController = controller
        controller.view.needsLayout = true
        controller.view.layoutSubtreeIfNeeded()
        fit()
    }

    // MARK: Presentation

    /// Slide the bar up from below the screen edge.
    func slideIn() {
        guard let screen = targetScreen() else { return }
        isSettled = false
        presentedScreen = screen
        let visible = screen.visibleFrame
        let height = contentHeight(width: visible.width)
        let onScreen = Self.barFrame(visible: visible, contentHeight: height,
                                     ceiling: Self.layoutCeiling)
        let offScreen = Self.offScreenFrame(visible: visible, contentHeight: height,
                                            ceiling: Self.layoutCeiling)

        setFrame(offScreen, display: false)
        alphaValue = 1
        makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(onScreen, display: true)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.isSettled = true
            self.fit()
            self.startFitting()
        })
    }

    func slideOut(completion: (() -> Void)? = nil) {
        isSettled = false
        stopFitting()
        // The screen the bar came up on, NOT the one under the mouse now.
        guard let screen = presentedScreen ?? targetScreen() else {
            orderOut(nil); presentedScreen = nil; completion?(); return
        }
        let offScreen = Self.offScreenFrame(visible: screen.visibleFrame, contentHeight: frame.height)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().setFrame(offScreen, display: true)
        }, completionHandler: {
            self.orderOut(nil)
            self.presentedScreen = nil
            completion?()
        })
    }

    /// The screen containing the mouse, falling back to the main screen. Used to
    /// CHOOSE a screen at summon time; never to dismiss — see `presentedScreen`.
    private func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

extension FloatingPanel: NSWindowDelegate {
    /// AppKit resizes a window to its hosting controller's content size behind
    /// our back, and it anchors the TOP edge — so every chrome row that appeared
    /// walked the bar DOWN off the screen edge (measured: 12pt, held until the
    /// next fit). Put the bottom edge back where it belongs, in the same runloop
    /// turn. The guard makes this converge in one step rather than recurse.
    func windowDidResize(_ notification: Notification) {
        guard isSettled, let visible = (presentedScreen ?? targetScreen())?.visibleFrame else { return }
        guard abs(frame.minY - visible.minY) > 0.5 else { return }
        setFrame(NSRect(x: frame.minX, y: visible.minY, width: frame.width, height: frame.height),
                 display: true)
    }
}
