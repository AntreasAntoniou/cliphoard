import AppKit

// Cliphoard runs as a menu-bar accessory app: no Dock icon, no main window.
@main
struct Main {
    @MainActor static func main() {
        // Headless tag-quality audit: `Cliphoard --analyze-tags [outfile]`.
        // Runs the analysis in-process (so it can decrypt the store) and exits,
        // never starting the menu-bar UI.
        if let i = CommandLine.arguments.firstIndex(of: "--archive-unreadable") {
            let out = CommandLine.arguments.indices.contains(i + 1)
                ? CommandLine.arguments[i + 1] : "/tmp/cliphoard-unreadable-archive.json"
            TagAudit.archiveUnreadable(to: out, delete: CommandLine.arguments.contains("--delete"))
            exit(0)
        }
        // List every supported clipboard manager and whether its store exists here.
        if CommandLine.arguments.contains("--import-scan") {
            ClipImporters.scan()
            exit(0)
        }
        // Describe an UNKNOWN store so a new adapter is a short read, not a project.
        if let i = CommandLine.arguments.firstIndex(of: "--import-probe"),
           CommandLine.arguments.indices.contains(i + 1) {
            ClipImporters.probe(path: (CommandLine.arguments[i + 1] as NSString).expandingTildeInPath)
            exit(0)
        }
        // Import from any supported manager: `--import-from <id> [path] [--force]`.
        // UNVERIFIED adapters dry-run unless --force, because none of them has ever been
        // executed against a real store and a bad parse writes garbage that looks like history.
        if let i = CommandLine.arguments.firstIndex(of: "--import-from"),
           CommandLine.arguments.indices.contains(i + 1) {
            let id = CommandLine.arguments[i + 1]
            guard let source = ClipImporters.all.first(where: { $0.id == id }) else {
                print("unknown source '\(id)'. Try --import-scan.")
                exit(1)
            }
            guard let read = source.read else {
                print("\(source.name): no adapter yet — \(source.note)")
                exit(1)
            }
            let explicit = CommandLine.arguments.indices.contains(i + 2)
                && !CommandLine.arguments[i + 2].hasPrefix("--")
                ? (CommandLine.arguments[i + 2] as NSString).expandingTildeInPath : nil
            guard let path = explicit ?? ClipImporters.resolve(source) else {
                print("\(source.name): store not found. Looked in:")
                source.candidatePaths.forEach { print("   \($0)") }
                exit(1)
            }
            let forced = CommandLine.arguments.contains("--force")
            let dry = source.confidence != .verified ? !forced : CommandLine.arguments.contains("--dry-run")
            if dry && source.confidence != .verified && !forced {
                print("\(source.name) is \(source.confidence.rawValue) — DRY RUN. "
                      + "Check the tally below, then re-run with --force.")
            }
            let store = ClipStore()
            guard !store.safeMode else {
                print("REFUSING: store is in SAFE MODE."); exit(1)
            }
            var tally = PasteImport.Tally()
            let staged = read(path, &tally)
            print("\(source.name): staged \(staged.count) clips from \(path)")
            ClipImporters.write(staged, marker: "import-\(source.id)", store: store,
                                dryRun: dry, tally: &tally)
            for (kind, n) in tally.byKind.sorted(by: { $0.value > $1.value }) {
                print(String(format: "  %-8s %6d", (kind as NSString).utf8String!, n))
            }
            print("  skipped: unparsable \(tally.skippedUnparsable), empty \(tally.skippedEmpty), "
                  + "duplicate \(tally.skippedDuplicate)")
            print(dry ? "DRY RUN — \(tally.imported) clips WOULD be imported"
                      : "imported \(tally.imported), tagged 'import-\(source.id)'")
            exit(0)
        }
        // Import Paste (Setapp) history: `--import-paste <db.sqlite> [--dry-run]
        // [--limit N] [--since YYYY-MM-DD]`. Runs in-process so it can seal with the same
        // keys the app uses — which is ALSO why it must be launched from inside the
        // installed bundle, not from .build: keychain access is keyed to code identity.
        if let i = CommandLine.arguments.firstIndex(of: "--import-paste"),
           CommandLine.arguments.indices.contains(i + 1) {
            let args = CommandLine.arguments
            func value(_ flag: String) -> String? {
                guard let j = args.firstIndex(of: flag), args.indices.contains(j + 1) else { return nil }
                return args[j + 1]
            }
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            let store = ClipStore()
            PasteImport.run(dbPath: args[i + 1],
                            store: store,
                            dryRun: args.contains("--dry-run"),
                            limit: value("--limit").flatMap(Int.init),
                            since: value("--since").flatMap(fmt.date(from:)))
            exit(0)
        }
        if CommandLine.arguments.contains("--crypto-diagnostics") {
            TagAudit.cryptoDiagnostics()
            exit(0)
        }
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
