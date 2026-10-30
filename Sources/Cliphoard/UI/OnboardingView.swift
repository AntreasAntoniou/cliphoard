import SwiftUI
import AppKit
import Combine
#if !APP_STORE
import ApplicationServices
#endif

/// First-run welcome window: explains the hotkey and the channel's paste flow,
/// then gets out of the way. Shown once (gated on UserDefaults), and
/// re-openable from the menu-bar menu.
@MainActor
enum Onboarding {
    private static let key = "didOnboardV1"
    private static var window: NSWindow?

    static func showIfNeeded(store: ClipStore, onUpgrade: @escaping () -> Void) {
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        present(store: store, onUpgrade: onUpgrade)
    }

    static func present(store: ClipStore, onUpgrade: @escaping () -> Void) {
        SensitiveClipReveal.shared.lock()
        if let w = window {
            NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); return
        }
        let view = OnboardingView(store: store, onDone: {
            UserDefaults.standard.set(true, forKey: key)
            window?.close(); window = nil
        }, onUpgrade: onUpgrade)
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.setContentSize(NSSize(width: 600, height: 680))
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

@MainActor
struct OnboardingView: View {
    @ObservedObject var store: ClipStore
    let onDone: () -> Void
    let onUpgrade: () -> Void
    @State private var explorePro = false
    @State private var downloadSelectedModel = false
    @State private var draft: GuidedSetupDraft

    init(store: ClipStore, onDone: @escaping () -> Void, onUpgrade: @escaping () -> Void) {
        self.store = store
        self.onDone = onDone
        self.onUpgrade = onUpgrade
        _draft = State(initialValue: GuidedSetupDraft(overlays: TagBaskets.overlayIDs,
            level: DeepSearch.level, historyLimit: store.historyLimit))
    }
    #if !APP_STORE
    @State private var trusted = AXIsProcessTrusted()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    #endif

    /// The app's own hoard-bag icon (the white filled bag), matching the panel
    /// toolbar; falls back to the ⌘ glyph if the bundle icon can't load.
    @ViewBuilder private var brandIcon: some View {
        if let icon = Bundle.main.image(forResource: "Cliphoard") ?? NSApp.applicationIconImage {
            Image(nsImage: icon)
                .resizable().interpolation(.high)
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .accessibilityHidden(true)
        } else {
            Image(systemName: "command")
                .font(.system(size: 44)).foregroundStyle(Theme.accent)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("Step \(draft.step.rawValue + 1) of \(GuidedSetupDraft.Step.allCases.count)")
                    .font(.caption).foregroundStyle(.secondary)
                Text(draft.step.title).font(.system(size: 24, weight: .bold))
            }
            .padding(.top, 28).padding(.bottom, 18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    stepContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
            }
            Divider()
            HStack {
                Button("Back") { draft.back() }
                    .disabled(draft.step == .welcome)
                Spacer()
                Text("Nothing changes until you finish.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if draft.step == .finish {
                    Button(downloadSelectedModel && draft.level != .off ? "Finish & prepare model" : "Apply choices and finish") { finish() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canFinish)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Next") { draft.next() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
        }
        .frame(width: 600, height: 680)
        .background(VisualEffectBackground(material: .windowBackground, blending: .behindWindow))
        #if !APP_STORE
        .onReceive(timer) { _ in trusted = AXIsProcessTrusted() }
        #endif
    }

    private var unpinnedCount: Int { store.items.filter { !$0.pinned }.count }
    private func modelAvailable(_ level: DeepSearchLevel) -> Bool {
        if level == .gemma2 { return GemmaMediaAssets.localCandidateExists() }
        guard let name = level.modelName else { return true }
        return ModelAssets.canPrepareLocally(name)
    }
    private func modelChoiceTitle(_ level: DeepSearchLevel) -> String {
        if level == .gemma2 { return level.title + (modelAvailable(level) ? " · downloaded" : " · 485 MB download") }
        guard let name = level.modelName, let bytes = ModelAssets.catalog[name]?.bytes else { return level.title }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return level.title + (modelAvailable(level) ? " · downloaded" : " · \(size) download")
    }
    private var canFinish: Bool {
        draft.canFinish(unpinnedCount: unpinnedCount, selectedModelAvailable: modelAvailable(draft.level), allowDeferredModel: true)
            && !(store.safeMode && draft.changes?.historyLimit != nil)
    }
    private var retentionLabel: String { draft.historyLimit == 0 ? "Unlimited" : String(draft.historyLimit) }
    private var overlayNames: String {
        let names = draft.overlays.compactMap { id in TagBaskets.all.first { $0.id == id }?.name }
        return names.isEmpty ? "General only" : "General + " + names.joined(separator: ", ")
    }

    @ViewBuilder private var stepContent: some View {
        switch draft.step {
        case .welcome:
            HStack { Spacer(); brandIcon; Spacer() }
            hotkeyRow
            feature("lock.shield", "Private by design", "Clipboard processing stays on your Mac. Sensitive previews require macOS authentication to reveal.")
            pasteSection
        case .tags:
            Text("General tags are included. Add specialist baskets for the clips you work with; you can combine them and change them later in Settings.")
                .foregroundStyle(.secondary)
            ForEach(TagBaskets.all.filter { $0.id != "general" }) { basket in
                Toggle(basket.name, isOn: Binding(get: { draft.overlays.contains(basket.id) }, set: { enabled in
                    if enabled { if !draft.overlays.contains(basket.id) { draft.overlays.append(basket.id) } }
                    else { draft.overlays.removeAll { $0 == basket.id } }
                }))
            }
            Text("Your existing custom tags are preserved. Edit custom tag text in Settings.")
                .font(.caption).foregroundStyle(.secondary)
        case .model:
            Text("Choose the on-device model used for semantic search. Off uses no neural model. Low is the smallest option, Normal is a compact all-rounder, High uses MiniLM, and EmbeddingGemma 2 uses the larger multimodal model for text search and tagging too. Changing the model re-indexes your history in the background after you finish.")
                .foregroundStyle(.secondary)
            Picker("Search model", selection: $draft.level) {
                ForEach(DeepSearchLevel.allCases) { level in
                    Text(modelChoiceTitle(level))
                        .tag(level)
                }
            }
            .pickerStyle(.radioGroup)
            Text("No models are bundled. Choose an optional Hugging Face download, or keep using basic search and download later in Settings. Models are prepared and run locally; your clipboard stays on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            if draft.level != .off {
                Toggle("Download and prepare this model after finishing", isOn: $downloadSelectedModel)
                Text("Download progress, cancellation and retry are available in Settings → Search.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .history:
            Text("Keep the newest unpinned clips up to this limit. Pinned clips are kept separately. Unlimited keeps history until you delete it.")
                .foregroundStyle(.secondary)
            Picker("Keep unpinned clips", selection: $draft.historyLimit) {
                ForEach(GuidedSetupDraft.historyChoices, id: \.0) { value, label in Text(label).tag(value) }
                if !GuidedSetupDraft.historyChoices.contains(where: { $0.0 == draft.historyLimit }) {
                    Text("Current: \(draft.historyLimit)").tag(draft.historyLimit)
                }
            }
            Text("\(unpinnedCount) unpinned clips are currently stored. Lowering the limit can permanently delete older clips and their images. Review and confirm that on the final step.")
                .font(.caption).foregroundStyle(.secondary)
        case .pro:
            Text("Find the moment. Rediscover the idea.")
                .font(.title2.bold())
            Text("Turn your clipboard into a searchable world of pictures, sounds and video with Cliphoard Pro.")
                .foregroundStyle(.secondary)
            feature("photo", "Search beyond words", "Find images by what they show, discover similar pictures and read text inside screenshots.")
            feature("play.rectangle", "Jump to the good part", "Search audio and video, then open a matching moment. Choose Lightweight, Balanced or Detailed sampling to suit your Mac.")
            feature("waveform", "Find what was said", "Optional Whisper models add transcription-based search, with sampled speech or fuller transcription to suit your needs.")
            feature("lock.shield", "Your media stays yours", "Models download from Hugging Face only when you choose, prepare locally and run on your Mac. No models are bundled. Sparse sampling can miss brief moments.")
            VStack(alignment: .leading, spacing: 8) {
                Label("Power foundational AI research", systemImage: "sparkles")
                    .font(.headline)
                Text("All proceeds go to foundational AI research. Advancing that research is the mission—and the discoveries help make Cliphoard smarter along the way.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            if store.entitlement.isPro {
                Label("You already have Pro. Enjoy exploring!", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Theme.accent)
            } else {
                Picker("Your next step", selection: $explorePro) {
                    Text("Explore Pro after setup").tag(true)
                    Text("Continue with Free").tag(false)
                }
                .pickerStyle(.radioGroup)
                Text("Free includes clipboard history, tags and text search. Exploring Pro opens purchase options after setup; it does not buy anything. You can upgrade later in Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .finish:
            if explorePro && !store.entitlement.isPro {
                feature("sparkles", "Explore Pro next", "After applying your choices, we’ll open the highlighted Pro purchase options. No purchase happens automatically.")
            }
            feature("tag", "Tags", overlayNames)
            feature("cpu", "Search model", draft.level.title)
            feature("clock", "History", "Keep \(retentionLabel.lowercased()) unpinned clips; pinned clips are preserved.")
            let remove = draft.removalCount(unpinnedCount: unpinnedCount)
            if remove > 0 {
                Text("Finishing will permanently remove \(remove) older unpinned clips and their image files. Export an encrypted history backup in Settings first if you want to retain them.")
                    .foregroundStyle(.orange)
                Toggle("I agree to remove these \(remove) older unpinned clips", isOn: Binding(
                    get: { draft.confirmedRemovalCount == remove },
                    set: { draft.confirmedRemovalCount = $0 ? remove : nil }))
            }
            if store.safeMode && draft.changes?.historyLimit != nil {
                Text("History is in recovery mode. Keep the existing retention setting until recovery is resolved.")
                    .foregroundStyle(.orange)
            }
            if !modelAvailable(draft.level) && draft.changes?.level != nil {
                Text(downloadSelectedModel ? "The selected model will download from Hugging Face and prepare locally after you finish." : "This model will be downloaded later from Settings. Basic search remains available.")
                    .foregroundStyle(.orange)
            }
            Text("You can revisit this walkthrough from Welcome to Cliphoard in the menu-bar menu.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func finish() {
        // All checks and writes run synchronously on MainActor. A new capture
        // cannot slip between the exact removal-count consent and trim().
        guard canFinish, let changes = draft.changes else { return }
        if let overlays = changes.overlays {
            TagBaskets.overlayIDs = overlays
            store.rebuildTagIndex()
        }
        if let level = changes.level {
            DeepSearch.level = level
            EmbedderProvider.configureAndReindex(level: level, store: store, allowDownloads: downloadSelectedModel)
        } else if downloadSelectedModel, draft.level != .off {
            EmbedderProvider.configureAndReindex(level: draft.level, store: store, allowDownloads: true)
        }
        if let limit = changes.historyLimit { store.historyLimit = limit }
        onDone()
        if explorePro && !store.entitlement.isPro { onUpgrade() }
    }

    private func feature(_ symbol: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(Theme.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(body).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var hotkeyRow: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "keyboard").font(.system(size: 18)).foregroundStyle(Theme.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 6) {
                Text("Summon it anywhere").font(.system(size: 14, weight: .semibold))
                HStack(spacing: 6) {
                    ForEach(["⌃", "⌥", "⌘", "V"], id: \.self) { k in
                        Text(k).font(.system(size: 13, weight: .semibold, design: .rounded))
                            .frame(minWidth: 22).padding(.vertical, 5).padding(.horizontal, 6)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    }
                    Text("from any app").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder private var pasteSection: some View {
        #if APP_STORE
        feature("doc.on.clipboard", "Pick, then paste",
                "Choosing a clip copies it to the clipboard. Return to your app and press ⌘V.")
        #else
        accessibilitySection
        #endif
    }

    #if !APP_STORE
    private var accessibilitySection: some View {
        HStack(spacing: 14) {
            Image(systemName: trusted ? "checkmark.circle.fill" : "exclamationmark.shield")
                .font(.system(size: 18)).foregroundStyle(trusted ? .green : .orange).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(trusted ? "Accessibility granted" : "One quick permission")
                    .font(.system(size: 13, weight: .semibold))
                Text(trusted ? "Cliphoard can paste the clip you pick back into your app."
                             : "Cliphoard needs Accessibility to paste into the app you were using.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !trusted {
                Button("Grant…") { grant() }.controlSize(.small)
            }
        }
        .padding(12)
        .background((trusted ? Color.green : Color.orange).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    private func grant() {
        _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    #endif
}
