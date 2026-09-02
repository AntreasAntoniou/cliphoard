import AppKit
import SwiftUI

/// The inspector's own window: a floating panel centred above the bar rather than a
/// `.sheet` hung off it. Key-capable so its tag editor and buttons take the keyboard;
/// Esc reaches it as `cancelOperation`, which is forwarded rather than swallowed.
final class InspectorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Owns exactly one `InspectorPanel` and one hosting controller for its content.
///
/// The panel outlives every presentation (`isReleasedWhenClosed = false`, and
/// `windowShouldClose` refuses so the model — not AppKit — decides when it goes). Geometry
/// is a pure static so it can be asserted without a window.
@MainActor
final class InspectorWindowController: NSObject, NSWindowDelegate {
    let panel: InspectorPanel
    private let hosting: NSHostingController<AnyView>

    /// The user asked the window to close (title-bar button). The owner clears the model,
    /// and the model's change callback dismisses the panel.
    var onClose: (() -> Void)?
    var isPresented: Bool { panel.isVisible }

    override init() {
        panel = InspectorPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 650),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .mainMenu + 2
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.contentMinSize = NSSize(width: 560, height: 520)
        hosting = NSHostingController(rootView: AnyView(EmptyView()))
        // The window's frame is decided by `placement`, not by the SwiftUI tree's ideal size.
        hosting.sizingOptions = []
        super.init()
        panel.contentViewController = hosting
        panel.delegate = self
    }

    /// Show `view` in the panel. The frame is computed only on a fresh presentation — an
    /// inspector already on screen keeps wherever the user dragged or resized it.
    func present(_ view: AnyView, host: NSRect, visible: NSRect) {
        hosting.rootView = view
        if !panel.isVisible {
            panel.setFrame(Self.placement(size: NSSize(width: 680, height: 650), minHeight: 520,
                                          bar: host, visible: visible),
                           display: true)
        }
        panel.makeKeyAndOrderFront(nil)
        DebugLog.write("inspector: presented \(panel.frame) above bar \(host) on \(visible)")
    }

    /// Idempotent: ordering out an already-hidden panel is a no-op.
    func dismiss() { panel.orderOut(nil) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onClose?()
        return false
    }

    // MARK: Geometry

    /// Where the inspector goes: centred horizontally on the screen, vertically in the band
    /// between the top of the bar and the top of the visible frame, `gap` inside each edge.
    ///
    /// Width is `size.width` unless the screen is narrower. Height is `size.height` unless
    /// the band is shorter, but never below `minHeight`: when the band cannot hold even
    /// that, the frame hugs the top (`maxY = visible.maxY - gap`) and overlaps the bar
    /// rather than leaving the screen. A degenerate `visible` (display unplugged, stale
    /// `NSScreen`) yields `.zero` so the caller can refuse to place anything.
    static func placement(size: NSSize, minHeight: CGFloat, bar: NSRect, visible: NSRect,
                          gap: CGFloat = 12) -> NSRect {
        guard visible.width > 1, visible.height > 1 else { return .zero }
        let width = min(size.width, visible.width - 2 * gap)
        let bandMinY = bar.maxY + gap
        let bandMaxY = visible.maxY - gap
        let bandHeight = bandMaxY - bandMinY
        let height: CGFloat
        let y: CGFloat
        if bandHeight >= minHeight {
            height = min(size.height, bandHeight)
            y = (bandMinY + bandMaxY) / 2 - height / 2
        } else {
            height = minHeight
            y = visible.maxY - gap - height
        }
        return NSRect(x: visible.midX - width / 2, y: y, width: width, height: height)
    }
}
