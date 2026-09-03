import AppKit

/// The app's only exits.
///
/// Both the safe-mode banner and Settings call in here rather than reaching for
/// `NSApp.terminate` themselves, so there is one relaunch implementation instead of the
/// two that were about to exist. The unsaved-clip confirm does NOT live here: it lives in
/// `AppDelegate.applicationShouldTerminate`, which every exit passes through — including
/// `osascript -e 'tell application "Cliphoard" to quit'`, which no call site can route.
@MainActor
enum AppLifecycle {
    /// Set by `requestRelaunch`, consumed in `applicationWillTerminate` — never before.
    /// Spawning the reopen next to the `terminate` call is the bug this ordering exists to
    /// prevent: a quit the user then CANCELS would otherwise leave a watcher waiting on
    /// our pid, and the app would resurrect itself on some unrelated later quit.
    private(set) static var relaunchRequested = false

    static func quit() { NSApp.terminate(nil) }
    static func requestRelaunch() { relaunchRequested = true; NSApp.terminate(nil) }
    static func cancelRelaunch() { relaunchRequested = false }

    /// The shell command that reopens this app once THIS process is gone, or nil when
    /// there is nothing sane to reopen (a `swift run` build is a bare executable, not a
    /// bundle, and `open` on it would put a Finder window on screen).
    ///
    /// Pure, so the ordering rule is asserted as arithmetic rather than by reading a
    /// `Process` that only runs while the app is dying. `open -n` fired BEFORE terminate —
    /// which is what `SettingsView.relaunch` did — puts a second instance on the same
    /// ditto.sqlite/WAL and the same keychain item while the first still owns them.
    static func relaunchCommand(pid: Int32, bundleURL: URL) -> String? {
        guard bundleURL.pathExtension == "app" else { return nil }
        return "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; "
             + "/usr/bin/open \(quoted(bundleURL.path))"
    }

    @discardableResult
    static func performRelaunchIfRequested() -> Bool {
        guard relaunchRequested else { return false }
        relaunchRequested = false
        guard let command = relaunchCommand(pid: ProcessInfo.processInfo.processIdentifier,
                                            bundleURL: Bundle.main.bundleURL) else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", command]
        try? task.run()
        return true
    }

    private static func quoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
