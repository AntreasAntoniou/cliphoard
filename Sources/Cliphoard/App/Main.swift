import AppKit

// Cliphoard runs as a menu-bar accessory app: no Dock icon, no main window.
@main
struct Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        // Retain the delegate for the lifetime of the app.
        objc_setAssociatedObject(app, "dittoDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
        app.run()
    }
}
