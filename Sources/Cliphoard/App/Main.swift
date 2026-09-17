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
        // Move a history to another Mac: `--export-history <path>` /
        // `--import-history <path>`, both with an optional `--store-dir <dir>`.
        //
        // The passphrase is read from STDIN ONLY, first line — never from argv, which is
        // world-readable through `ps`, never echoed when stdin is a terminal, and never
        // logged. Like every other in-process flag here, these must be launched from
        // inside the INSTALLED BUNDLE and not from `.build`: keychain access is keyed to
        // code identity, so a `.build` binary sees a different (empty) keychain.
        if let i = CommandLine.arguments.firstIndex(of: "--export-history"),
           CommandLine.arguments.indices.contains(i + 1) {
            let args = CommandLine.arguments
            // The licence gate is carried HERE as well as in the UI. A gate the command
            // line does not consult is a one-flag bypass, which is not a gate.
            guard ProGate.allowsHistoryArchive else {
                print("Moving your history to another Mac is a Pro feature.")
                exit(2)
            }
            let out = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
            let store = ClipStore(directory: Self.storeDirectoryArgument(args))
            guard !store.safeMode else {
                print("REFUSING: store is in SAFE MODE. Cliphoard cannot read its own "
                      + "history right now, so an export would be unreadable gibberish.")
                exit(1)
            }
            let passphrase = Self.readPassphrase("Passphrase for the export")
            var lastLine = ""
            let result = store.exportArchive(
                to: out, passphrase: passphrase,
                acknowledgingUnreadable: args.contains("--allow-unreadable")) { _, message in
                    guard message != lastLine else { return }
                    lastLine = message
                    FileHandle.standardError.write(Data(("  " + message + "\n").utf8))
                }
            switch result {
            case .success(let report):
                print("exported \(report.clipCount) clips, \(report.payloadCount) images, "
                      + "\(report.imageFeatureCount) image prints, "
                      + "\(report.dismissalCount) dismissals")
                print(String(format: "  %d bytes in %.2f s → %@",
                             report.byteCount, report.seconds, out.path))
                if report.skippedUnreadableClips > 0 || report.skippedUnreadablePayloads > 0 {
                    print("  SKIPPED \(report.skippedUnreadableClips) unreadable clip(s) and "
                          + "\(report.skippedUnreadablePayloads) unreadable image(s) — the "
                          + "file records this, so the destination says it too.")
                }
                exit(0)
            case .failure(let error):
                print("REFUSED: " + error.message)
                exit(1)
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--import-history"),
           CommandLine.arguments.indices.contains(i + 1) {
            let args = CommandLine.arguments
            guard ProGate.allowsHistoryArchive else {
                print("Moving your history to another Mac is a Pro feature.")
                exit(2)
            }
            let file = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
            let passphrase = Self.readPassphrase("Passphrase for \(file.lastPathComponent)")
            // --dry-run verifies EVERY chunk's tag to EOF and writes nothing at all — not
            // even a staging folder. It does not need (and does not open) the store.
            if args.contains("--dry-run") {
                switch HistoryArchiveIO.verify(url: file, passphrase: passphrase) {
                case .success(let report):
                    Self.printSummary(report.summary)
                    let kinds = report.byKind.sorted { $0.key < $1.key }
                        .map { "\($0.key) \($0.value)" }.joined(separator: " · ")
                    print("  VERIFIED \(report.clipCount) clips · \(kinds)")
                    print("  \(report.payloadCount) images · \(report.imageFeatureCount) "
                          + "image prints · \(report.dismissalCount) dismissals")
                    print(String(format: "  %d body bytes, every block's tag checked, in %.2f s",
                                 report.bytesVerified, report.seconds))
                    print("DRY RUN — nothing was written.")
                    exit(0)
                case .failure(let error):
                    print("REFUSED: " + error.message)
                    exit(1)
                }
            }
            let store = ClipStore(directory: Self.storeDirectoryArgument(args))
            guard !store.safeMode else {
                print("REFUSING: store is in SAFE MODE. Nothing has been deleted.")
                exit(1)
            }
            let setUnlimited = args.contains("--set-unlimited")
            let acceptTrim = args.contains("--accept-trim")
            // `--set-unlimited` turns the limit off, which only Pro can do — a free build used
            // to be told to run it, and it set 500. `--accept-trim` keeps the stored limit and
            // imports the newest clips that fit it, leaving the rest in the file: nothing is
            // trimmed after the fact, because `trim()` deletes rows AND unlinks their images.
            // Neither flag, and not everything fits: refuse, so the decision is the user's.
            if setUnlimited && !store.entitlement.isPro && store.historyLimit != 0 {
                let raise = store.historyLimit < ClipStore.freeHistoryLimit
                    ? ", or raise the limit to \(ClipStore.freeHistoryLimit) in Settings first"
                    : ""
                print("REFUSING: --set-unlimited turns the history limit off, and this build "
                      + "cannot — it keeps at most \(ClipStore.freeHistoryLimit) unpinned clips. "
                      + "Re-run with --accept-trim to keep the newest clips that fit your limit "
                      + "(the file keeps all of them; nothing already here is deleted)\(raise). "
                      + Licence.pitch)
                exit(1)
            }
            switch HistoryArchiveIO.preview(url: file, passphrase: passphrase) {
            case .failure(let error):
                print("REFUSED: " + error.message)
                exit(1)
            case .success(let summary):
                Self.printSummary(summary)
                let plan = ClipStore.importPlan(
                    limitBefore: store.historyLimit,
                    unpinnedHere: store.items.filter { !$0.pinned }.count,
                    lift: setUnlimited, entitlement: store.entitlement)
                let incoming = summary.clipCount - summary.pinnedCount
                if !plan.fits(incoming) && !acceptTrim {
                    print(plan.refusal(incomingUnpinned: incoming))
                    exit(1)
                }
                if let note = plan.preview(incomingUnpinned: incoming) { print("  " + note) }
            }
            var lastLine = ""
            let staged = store.stageImport(from: file, passphrase: passphrase) { _, message in
                guard message != lastLine else { return }
                lastLine = message
                FileHandle.standardError.write(Data(("  " + message + "\n").utf8))
            }
            switch staged {
            case .failure(let error):
                print("REFUSED: " + error.message)
                exit(1)
            case .success(let quarantined):
                let tally = store.ingestImported(quarantined, liftLimit: setUnlimited)
                if let refusal = tally.refusal {
                    print("REFUSED: " + refusal.message)
                    exit(1)
                }
                print(tally.summaryLine)
                print(String(format: "  %d image(s) moved in, %d already here, in %.2f s",
                             tally.payloadsMoved, tally.payloadsAlreadyPresent, tally.seconds))
                print("  Search will re-index on the next launch of the app.")
                exit(0)
            }
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        // Retain the delegate for the lifetime of the app.
        objc_setAssociatedObject(app, "dittoDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
        app.run()
    }

    /// `--store-dir <dir>`, expanded, or nil for the real store. One line, and it is what
    /// makes verifying an import possible without ever writing to the live history.
    @MainActor
    static func storeDirectoryArgument(_ args: [String]) -> URL? {
        guard let j = args.firstIndex(of: "--store-dir"), args.indices.contains(j + 1)
        else { return nil }
        return URL(fileURLWithPath: (args[j + 1] as NSString).expandingTildeInPath,
                   isDirectory: true)
    }

    /// First line of stdin. Never argv (world-readable via `ps`), never echoed when stdin
    /// is a terminal, never logged, never on the pasteboard.
    @MainActor
    static func readPassphrase(_ prompt: String) -> String {
        guard isatty(0) != 0 else { return readLine(strippingNewline: true) ?? "" }
        FileHandle.standardError.write(Data((prompt + ": ").utf8))
        var saved = termios()
        tcgetattr(0, &saved)
        var quiet = saved
        quiet.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(0, TCSAFLUSH, &quiet)
        defer {
            tcsetattr(0, TCSAFLUSH, &saved)
            FileHandle.standardError.write(Data("\n".utf8))
        }
        return readLine(strippingNewline: true) ?? ""
    }

    @MainActor
    static func printSummary(_ summary: HistoryArchive.Summary) {
        let kinds = summary.byKind.sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value)" }.joined(separator: " · ")
        let stamp = DateFormatter()
        stamp.dateStyle = .medium
        stamp.timeStyle = .none
        print("\(summary.clipCount) clips from "
              + stamp.string(from: Date(timeIntervalSinceReferenceDate: summary.oldestCreatedAt))
              + " to "
              + stamp.string(from: Date(timeIntervalSinceReferenceDate: summary.newestCreatedAt))
              + ", made on \(summary.machineName) (Cliphoard \(summary.appVersion), "
              + "\(summary.exportedAt))")
        print("  \(kinds)")
        print("  \(summary.payloadCount) images (\(summary.payloadBytes) bytes) · "
              + "\(summary.imageFeatureCount) image prints · "
              + "\(summary.dismissalCount) dismissals · "
              + "search index \(summary.embeddingsIncluded ? "included" : "recomputed here")")
        if summary.skippedUnreadableClips > 0 || summary.skippedUnreadablePayloads > 0 {
            print("  WARNING: the machine that made this file could not read "
                  + "\(summary.skippedUnreadableClips) clip(s) and "
                  + "\(summary.skippedUnreadablePayloads) image(s), so they are NOT in it.")
        }
    }

}
