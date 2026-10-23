import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Settings → **Move to another Mac**: the whole export/import surface.
///
/// Three things here are non-obvious and are the reason this is its own file.
///
/// **The passphrase prompt is an `NSAlert`, not a SwiftUI `.sheet`.** A SwiftUI sheet is a
/// separate key window, and `panel.onResignKey` already has to special-case the inspector
/// for exactly that reason. `AppDelegate.applicationShouldTerminate` is the precedent, and
/// it carries the non-obvious part: `NSAlert.runModal()` OVERWRITES its window level with
/// `.modalPanel` (8) while the bar sits at `.mainMenu + 1` (25), so without lowering our
/// own windows for the duration the user never sees the prompt at all. `SystemPanel.runAlert`
/// does that, once, for both sheets.
///
/// **Capture is suspended while either sheet is up.** This is a clipboard manager. A
/// passphrase pasted in from a password manager would otherwise be captured into the very
/// history it protects — and a generated one would be, too, which is why Generate writes
/// straight into both fields and the system pasteboard is not named anywhere in this
/// file — a test asserts that by searching for the class name, so do not reintroduce it
/// even in a comment.
///
/// **The floor is not enforced here.** It is enforced in `HistoryArchiveIO`, because the
/// command line never sees this sheet. What this file adds is the meter, the confirm field
/// and the warning — help, not the rule.
@MainActor
final class ArchiveModel: ObservableObject {

    /// An opened file waiting for the user to say yes.
    struct Pending {
        let url: URL
        let passphrase: String
        let summary: HistoryArchive.Summary
        let limitBefore: Int
        let unpinnedHere: Int
        /// From the summary — an upper bound on what will be written, since dedup only lowers it.
        var incomingUnpinned: Int { summary.clipCount - summary.pinnedCount }
        /// Offered only where it is needed: the file does not fit under the stored limit.
        var offersLift: Bool {
            !ClipStore.importPlan(limitBefore: limitBefore, unpinnedHere: unpinnedHere,
                                  lift: false).fits(incomingUnpinned)
        }
        /// The toggle's answer counts only where the toggle was shown: a file that fits never
        /// changes the user's limit behind a control they were not offered.
        func plan(lift: Bool) -> ClipStore.ImportPlan {
            ClipStore.importPlan(limitBefore: limitBefore, unpinnedHere: unpinnedHere,
                                 lift: lift && offersLift)
        }
    }

    @Published private(set) var busy: String?
    @Published private(set) var result: String?
    @Published private(set) var pending: Pending?
    /// Defaults ON: when the file does not fit, turn the history limit off BEFORE the rows land.
    /// Never a post-hoc banner — `trim()` deletes rows AND unlinks their payload files. Declined,
    /// what does not fit stays in the file; it is never trimmed.
    @Published var liftLimit = true

    /// The ONE place the section decides whether the buttons work, and it produces the
    /// sentence shown underneath them. A control that looks live and does nothing is the
    /// defect `FrozenControlsTests` exists for, so the reason is always visible.
    ///
    /// There is no licence line here because the feature ships free: `ProGate` is consulted
    /// at the two actions below (and at the two command-line flags), where refusing has
    /// something to refuse.
    static func gateReason(_ store: ClipStore) -> String? {
        if store.safeMode {
            return "Cliphoard can't read its own history right now, so it can neither "
                 + "export it nor add to it. Nothing has been deleted."
        }
        return nil
    }

    // MARK: Export

    func beginExport(store: ClipStore, panel: PanelViewModel?) {
        guard ProGate.allowsHistoryArchive else {
            result = HistoryArchive.ArchiveError.licenceRequired.message
            return
        }
        guard Self.gateReason(store) == nil else { return }
        guard let passphrase = PassphraseSheet.ask(confirming: true, panel: panel) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let suggested = "Cliphoard History \(formatter.string(from: Date()))."
            + HistoryArchive.fileExtension
        guard let url = SystemPanel.run(panel, { () -> URL? in
            let save = NSSavePanel()
            save.nameFieldStringValue = suggested
            save.prompt = "Export"
            save.message = "Save an encrypted copy of your whole history."
            if let type = UTType(filenameExtension: HistoryArchive.fileExtension) {
                save.allowedContentTypes = [type]
            }
            return save.runModal() == .OK ? save.url : nil
        }) else { return }

        busy = "Writing the export…"
        result = nil
        var report = DistributionChannel.withSecurityScopedAccess(to: url) {
            store.exportArchive(to: url, passphrase: passphrase) { _, message in
                self.busy = message
            }
        }
        // The one refusal a user may legitimately override: some of this history cannot be
        // decrypted on this Mac. Never silently — the manifest records the counts so the
        // DESTINATION says it too. A partial export must not be able to present itself as
        // complete.
        if case .failure(.unreadableContent(let clips, let payloads)) = report {
            let proceed = SystemPanel.runAlert(panel) { () -> Bool in
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Some of this history cannot be read on this Mac"
                alert.informativeText =
                    "\(clips) clip\(clips == 1 ? "" : "s") and \(payloads) "
                    + "image\(payloads == 1 ? "" : "s") will not be in the file. The export "
                    + "will record that, so the other Mac says it too."
                alert.addButton(withTitle: "Export the rest")
                alert.addButton(withTitle: "Cancel")
                alert.buttons[0].keyEquivalent = ""
                alert.buttons[1].keyEquivalent = "\r"
                return alert.runModal() == .alertFirstButtonReturn
            }
            guard proceed else { busy = nil; result = "Nothing was exported."; return }
            report = DistributionChannel.withSecurityScopedAccess(to: url) {
                store.exportArchive(to: url, passphrase: passphrase,
                                    acknowledgingUnreadable: true) { _, message in
                    self.busy = message
                }
            }
        }
        busy = nil
        switch report {
        case .success(let done):
            result = "Exported \(done.clipCount) clips and \(done.payloadCount) images to "
                + "\(url.lastPathComponent). Keep the passphrase safe — there is no recovery."
        case .failure(let error):
            result = error.message
        }
    }

    // MARK: Import

    func beginImport(store: ClipStore, panel: PanelViewModel?) {
        guard ProGate.allowsHistoryArchive else {
            result = HistoryArchive.ArchiveError.licenceRequired.message
            return
        }
        guard Self.gateReason(store) == nil else { return }
        guard let url = SystemPanel.run(panel, { () -> URL? in
            let open = NSOpenPanel()
            open.allowsMultipleSelection = false
            open.canChooseDirectories = false
            open.prompt = "Open"
            open.message = "Pick a Cliphoard export from your other Mac."
            if let type = UTType(filenameExtension: HistoryArchive.fileExtension) {
                open.allowedContentTypes = [type]
            }
            return open.runModal() == .OK ? open.url : nil
        }) else { return }
        guard let passphrase = PassphraseSheet.ask(confirming: false, panel: panel) else { return }

        busy = "Opening the file…"
        result = nil
        let preview = DistributionChannel.withSecurityScopedAccess(to: url) {
            HistoryArchiveIO.preview(url: url, passphrase: passphrase)
        }
        busy = nil
        switch preview {
        case .failure(let error):
            result = error.message
        case .success(let summary):
            pending = Pending(url: url, passphrase: passphrase, summary: summary,
                              limitBefore: store.historyLimit,
                              unpinnedHere: store.items.filter { !$0.pinned }.count)
        }
    }

    func cancelImport() { pending = nil }

    func commitImport(store: ClipStore) {
        guard let pending else { return }
        self.pending = nil
        busy = "Reading the file…"
        result = nil
        let staged = DistributionChannel.withSecurityScopedAccess(to: pending.url) {
            store.stageImport(from: pending.url, passphrase: pending.passphrase) {
                _, message in self.busy = message
            }
        }
        switch staged {
        case .failure(let error):
            busy = nil
            result = error.message
        case .success(let quarantined):
            busy = "Finishing…"
            let tally = store.ingestImported(quarantined, liftLimit: pending.plan(lift: liftLimit).lifts)
            busy = nil
            result = tally.refusal == nil
                ? tally.summaryLine + " Search is re-indexing in the background."
                : tally.summaryLine
        }
    }
}

// MARK: - The passphrase sheet

/// Two secure fields, a strength meter, a live mismatch indicator, a Generate button and an
/// un-dismissable no-recovery warning.
@MainActor
enum PassphraseSheet {

    /// Returns the passphrase, or nil if the user cancelled.
    static func ask(confirming: Bool, panel: PanelViewModel?) -> String? {
        ClipboardMonitor.withCaptureSuspended {
            SystemPanel.runAlert(panel) { () -> String? in
                NSApp.activate(ignoringOtherApps: true)
                let accessory = PassphraseAccessory(confirming: confirming)
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = confirming
                    ? "Choose a passphrase for this export"
                    : "Enter the passphrase for this file"
                alert.informativeText = confirming
                    ? "This passphrase is the only key. Nothing is escrowed, there is no "
                    + "backup key and no reset — if you lose it, the file cannot be opened "
                    + "by anyone, including us. The file is as sensitive as your history "
                    + "itself: it includes clips flagged as coming from password managers."
                    : "The file cannot be opened without it."
                alert.accessoryView = accessory
                alert.addButton(withTitle: confirming ? "Export" : "Open")
                alert.addButton(withTitle: "Cancel")
                // Return must not be bound to the button that acts — the same discipline
                // as the quit alert.
                alert.buttons[0].keyEquivalent = ""
                alert.buttons[1].keyEquivalent = "\r"
                alert.window.initialFirstResponder = accessory.field
                guard alert.runModal() == .alertFirstButtonReturn else { return nil }
                let value = accessory.field.stringValue
                guard value.count >= HistoryArchive.passphraseMinimumLength else { return nil }
                if confirming, accessory.confirmField.stringValue != value { return nil }
                return value
            }
        }
    }
}

/// The accessory view. A plain `NSView` rather than SwiftUI because it lives inside an
/// `NSAlert`, which hosts AppKit.
@MainActor
final class PassphraseAccessory: NSView, NSTextFieldDelegate {
    let field = NSSecureTextField(frame: .zero)
    let confirmField = NSSecureTextField(frame: .zero)
    private let meter = NSLevelIndicator(frame: .zero)
    private let status = NSTextField(labelWithString: "")
    private let confirming: Bool

    init(confirming: Bool) {
        self.confirming = confirming
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: confirming ? 118 : 34))
        field.placeholderString = "Passphrase"
        field.delegate = self
        confirmField.placeholderString = "Type it again"
        confirmField.delegate = self
        meter.levelIndicatorStyle = .discreteCapacity
        meter.minValue = 0
        meter.maxValue = 4
        meter.numberOfTickMarks = 4
        meter.warningValue = 2
        meter.criticalValue = 1
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor

        var stack: [NSView] = [field]
        if confirming { stack += [confirmField, meter, status] }
        for view in stack {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.topAnchor.constraint(equalTo: topAnchor),
        ])
        if confirming {
            let generate = NSButton(title: "Generate", target: self,
                                    action: #selector(generate))
            generate.controlSize = .small
            generate.bezelStyle = .rounded
            generate.translatesAutoresizingMaskIntoConstraints = false
            addSubview(generate)
            NSLayoutConstraint.activate([
                confirmField.leadingAnchor.constraint(equalTo: leadingAnchor),
                confirmField.trailingAnchor.constraint(equalTo: trailingAnchor),
                confirmField.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
                meter.leadingAnchor.constraint(equalTo: leadingAnchor),
                meter.topAnchor.constraint(equalTo: confirmField.bottomAnchor, constant: 10),
                meter.widthAnchor.constraint(equalToConstant: 96),
                status.leadingAnchor.constraint(equalTo: meter.trailingAnchor, constant: 8),
                status.centerYAnchor.constraint(equalTo: meter.centerYAnchor),
                generate.trailingAnchor.constraint(equalTo: trailingAnchor),
                generate.centerYAnchor.constraint(equalTo: meter.centerYAnchor),
            ])
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func controlTextDidChange(_ notification: Notification) { refresh() }

    /// Writes into BOTH fields directly, and never puts the result on the system
    /// pasteboard — a generated passphrase there would be captured into the very
    /// history it protects.
    @objc private func generate() {
        guard let generated = HistoryArchive.generatePassphrase() else { return }
        field.stringValue = generated
        confirmField.stringValue = generated
        refresh()
    }

    private func refresh() {
        let value = field.stringValue
        let level = HistoryArchive.passphraseStrength(value)
        meter.doubleValue = Double(level)
        if value.count < HistoryArchive.passphraseMinimumLength {
            status.stringValue = "at least \(HistoryArchive.passphraseMinimumLength) characters"
        } else if confirming && confirmField.stringValue != value {
            status.stringValue = "the two do not match yet"
        } else {
            status.stringValue = HistoryArchive.strengthLabel(level)
        }
    }
}

// MARK: - The section

struct MoveToNewMacSection: View {
    @ObservedObject var model: ArchiveModel
    @ObservedObject var store: ClipStore
    /// The bar's view model, so both panels can suspend hide-on-resign and ask for focus
    /// back afterwards. Optional so a preview or a test can build the view without one.
    var panel: PanelViewModel?

    private var gateReason: String? { ArchiveModel.gateReason(store) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Export…").font(.system(size: 13))
                    Text("Save an encrypted copy of your whole history — clips, images, "
                         + "tags, pins and dates — protected by a passphrase you choose.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Export…") { model.beginExport(store: store, panel: panel) }
                    .controlSize(.small)
                    .disabled(gateReason != nil || model.busy != nil)
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import…").font(.system(size: 13))
                    Text("Bring a Cliphoard export in from another Mac. Clips already here "
                         + "are kept; nothing is deleted.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Import…") { model.beginImport(store: store, panel: panel) }
                    .controlSize(.small)
                    .disabled(gateReason != nil || model.busy != nil)
            }
            // The reason is ALWAYS visible when the buttons are dead. A disabled control
            // with no explanation is the thing the user reads as a broken app.
            if let gateReason {
                Text(gateReason)
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            Text("If you lose the passphrase the file cannot be opened. There is no "
                 + "recovery, no backup key, nothing stored anywhere. The file is as "
                 + "sensitive as your history itself — it includes clips flagged as coming "
                 + "from password managers.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let pending = model.pending { previewBox(pending) }
            if let busy = model.busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if let result = model.result {
                Text(result).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private func previewBox(_ pending: ArchiveModel.Pending) -> some View {
        let stamp = DateFormatter()
        stamp.dateStyle = .medium
        stamp.timeStyle = .none
        let oldest = Date(timeIntervalSinceReferenceDate: pending.summary.oldestCreatedAt)
        let newest = Date(timeIntervalSinceReferenceDate: pending.summary.newestCreatedAt)
        return VStack(alignment: .leading, spacing: 6) {
            Text("This file holds \(pending.summary.clipCount) clips from "
                 + "\(stamp.string(from: oldest)) to \(stamp.string(from: newest)), made on "
                 + "\(pending.summary.machineName) — \(pending.summary.payloadCount) images.")
                .font(.system(size: 12, weight: .semibold))
            Text("Clips already here are kept. Nothing is deleted.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if pending.summary.skippedUnreadableClips > 0
                || pending.summary.skippedUnreadablePayloads > 0 {
                Text("The Mac that made this file could not read "
                     + "\(pending.summary.skippedUnreadableClips) clip(s) and "
                     + "\(pending.summary.skippedUnreadablePayloads) image(s), so they are "
                     + "not in it.")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            if let note = pending.plan(lift: model.liftLimit)
                .preview(incomingUnpinned: pending.incomingUnpinned) {
                Text(note).font(.system(size: 11)).foregroundStyle(.orange)
            }
            if pending.offersLift {
                Toggle("Turn off the history limit (now \(pending.limitBefore)) so all of "
                       + "this file fits", isOn: $model.liftLimit)
                    .font(.system(size: 11))
            }
            HStack {
                Button("Cancel") { model.cancelImport() }.controlSize(.small)
                Spacer()
                // "Import 700" above a sentence saying 500 arrive is the small lie this file
                // exists to avoid; the sentences carry the numbers.
                Button("Import") { model.commitImport(store: store) }
                    .controlSize(.small)
                    .disabled(store.safeMode)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}
