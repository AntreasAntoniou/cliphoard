import AppKit

// Cliphoard runs as a menu-bar accessory app: no Dock icon, no main window.
@main
struct Main {
    @MainActor static func main() {
        // Headless tag-quality audit: `Cliphoard --analyze-tags [outfile]`.
        // Runs the analysis in-process (so it can decrypt the store) and exits,
        // never starting the menu-bar UI.
        if let i = CommandLine.arguments.firstIndex(of: "--analyze-tags") {
            let out = CommandLine.arguments.indices.contains(i + 1)
                ? CommandLine.arguments[i + 1] : "/tmp/cliphoard-tag-audit.md"
            TagAudit.run(outputPath: out)
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        // Retain the delegate for the lifetime of the app.
        objc_setAssociatedObject(app, "dittoDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
        app.run()
    }
}
