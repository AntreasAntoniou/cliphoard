import AppKit
import SwiftUI

/// A borderless panel pinned to the bottom of the active screen that slides up
/// into view — the signature Paste-style presentation.
final class FloatingPanel: NSPanel {
    /// Visible height of the bar.
    static let barHeight: CGFloat = 380

    var onResignKey: (() -> Void)?

    /// Stored hosting controller so the SwiftUI tree can be re-evaluated on every
    /// present. Kept as the panel's `contentViewController` — see `setContent`
    /// and `refresh`. The bug this fixes: previously the hosting view was a local
    /// in `setContent`, assigned once at launch, so an ordered-out panel never
    /// re-rendered `ContentView` against fresh `ClipStore` state on reopen.
    private var hostingController: NSViewController?
    /// Builds the current root view; reset by `setContent` on each present so the
    /// captured `model`/`store` references stay valid.
    private var makeRootView: (() -> NSViewController)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: FloatingPanel.barHeight),
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
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Install the SwiftUI content. The closure is retained and re-invoked by
    /// `refresh()` so each present rebuilds a fresh `NSHostingController` —
    /// guaranteeing the tree is re-evaluated against current `ClipStore` state.
    func setContent<Content: View>(_ build: @escaping () -> Content) {
        makeRootView = { NSHostingController(rootView: build()) }
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
    }

    /// Slide the bar up from below the screen edge.
    func slideIn() {
        guard let screen = targetScreen() else { return }
        let frame = screen.visibleFrame
        let width = frame.width
        let onScreen = NSRect(x: frame.minX, y: frame.minY, width: width, height: Self.barHeight)
        let offScreen = NSRect(x: frame.minX, y: frame.minY - Self.barHeight, width: width, height: Self.barHeight)

        setFrame(offScreen, display: false)
        alphaValue = 1
        makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(onScreen, display: true)
        }
    }

    func slideOut(completion: (() -> Void)? = nil) {
        guard let screen = targetScreen() else { orderOut(nil); completion?(); return }
        let frame = screen.visibleFrame
        let offScreen = NSRect(x: frame.minX, y: frame.minY - Self.barHeight,
                               width: frame.width, height: Self.barHeight)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().setFrame(offScreen, display: true)
        }, completionHandler: {
            self.orderOut(nil)
            completion?()
        })
    }

    /// The screen containing the mouse, falling back to the main screen.
    private func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}
