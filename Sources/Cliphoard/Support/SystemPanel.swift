import AppKit

/// Putting a system window on screen on the user's behalf, once, correctly.
///
/// Settings is rendered IN-BAR (`ContentView`, inside `model.showSettings`), so the host
/// window is the floating panel — and `panel.onResignKey` hides the whole bar the moment an
/// `NSSavePanel`, `NSOpenPanel` or `NSAlert` takes key. `isPresentingSystemPanel` is the
/// named exemption for "we put this window here", and it has to be cleared on EVERY path
/// including cancel, or the bar becomes permanently un-dismissable — a quieter bug than the
/// one it fixes, and a worse one.
///
/// Three call sites needed the same six lines (the reference-image picker, and now both
/// archive panels), and a fourth — `ImportPanel.chooseStore` — had NONE, so opening it
/// hid the bar underneath. That is where a helper earns its place: the next person to open
/// a system window gets the behaviour without having to know the rule.
enum SystemPanel {

    /// Run `body` with hide-on-resign suspended, restoring the flag and asking the panel
    /// for focus back on every exit path.
    @MainActor
    static func run<T>(_ model: PanelViewModel?, _ body: () -> T) -> T {
        model?.isPresentingSystemPanel = true
        defer {
            model?.isPresentingSystemPanel = false
            // The panel stayed visible but lost key focus to the modal; without this the
            // interface is on screen and the keyboard is dead.
            model?.onRequestFocus?()
        }
        return body()
    }

    /// `run`, plus the window-level dance an `NSAlert` needs.
    ///
    /// `NSAlert.runModal()` OVERWRITES its window's level with `.modalPanel` (8), while the
    /// bar sits at `.mainMenu + 1` (25). Probed in `AppDelegate.applicationShouldTerminate`:
    /// raising the alert's level before `runModal` does NOT survive, so CGWindowList reports
    /// the alert at layer 8 with the bar in front of it and the user never sees the prompt
    /// at all. Lower OUR windows for the duration instead — deterministic, synchronous, no
    /// timer — and restore every one of them in the `defer`.
    @MainActor
    static func runAlert<T>(_ model: PanelViewModel?, _ body: () -> T) -> T {
        let raised = NSApp.windows.filter { $0.level.rawValue > NSWindow.Level.normal.rawValue }
        let saved = raised.map { ($0, $0.level) }
        raised.forEach { $0.level = .normal }
        defer { for (window, level) in saved { window.level = level } }
        return run(model, body)
    }
}
