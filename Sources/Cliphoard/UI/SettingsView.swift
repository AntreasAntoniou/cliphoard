import SwiftUI
import AppKit

/// Observable wrapper over the app's persisted settings so the in-bar settings
/// UI can bind to them with two-way bindings. Reads current values on init and
/// writes through on change.
@MainActor
final class AppSettings: ObservableObject {
    let store: ClipStore

    @Published var soundEnabled: Bool { didSet { Feedback.soundEnabled = soundEnabled } }
    @Published var soundName: String { didSet { Feedback.soundName = soundName } }
    @Published var debugLogging: Bool { didSet { UserDefaults.standard.set(debugLogging, forKey: "debugLog") } }
    @Published var historyLimit: Int { didSet { store.historyLimit = historyLimit } }
    @Published var launchAtLogin: Bool { didSet { LoginItem.set(launchAtLogin) } }
    @Published var activateOnSummon: Bool { didSet { UserDefaults.standard.set(activateOnSummon, forKey: "activateOnSummon") } }
    @Published var themePreset: ThemePreset { didSet { Theme.preset = themePreset } }
    @Published var layoutMode: LayoutMode { didSet { Theme.layout = layoutMode } }
    @Published var searchMode: SearchMode {
        didSet {
            DeepSearch.mode = searchMode
            // Semantic modes need a model; default to ogma-small if none chosen.
            if searchMode != .exact && deepSearchLevel == .off { deepSearchLevel = .normal }
        }
    }
    @Published var deepSearchLevel: DeepSearchLevel {
        didSet {
            DeepSearch.level = deepSearchLevel
            // Load the new tier's model, then re-embed all entries into its space.
            EmbedderProvider.configureAndReindex(level: deepSearchLevel, store: store)
        }
    }
    @Published var activeBasket: String {
        didSet {
            TagBaskets.activeID = activeBasket
            store.reclassifyAllTags()   // cheap: re-tags from cached vectors
        }
    }
    /// Custom-basket tags, one per line, for editing.
    @Published var customTagsText: String

    func applyCustomTags() {
        let tags = customTagsText
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        TagBaskets.custom = TagBasket(id: "custom", name: "Custom", tags: tags)
        if activeBasket == "custom" { store.reclassifyAllTags() }
    }

    init(store: ClipStore) {
        self.store = store
        soundEnabled = Feedback.soundEnabled
        soundName = Feedback.soundName
        debugLogging = DebugLog.enabled
        historyLimit = store.historyLimit
        launchAtLogin = LoginItem.enabled
        activateOnSummon = UserDefaults.standard.bool(forKey: "activateOnSummon")
        themePreset = Theme.preset
        layoutMode = Theme.layout
        searchMode = DeepSearch.mode
        deepSearchLevel = DeepSearch.level
        activeBasket = TagBaskets.activeID
        customTagsText = TagBaskets.custom.tags.joined(separator: "\n")
    }

    func previewSound() { Feedback.play(named: soundName) }

    /// Live Accessibility-trust state. Polled while Settings is open so the
    /// "Grant…" row disappears as soon as the grant takes effect.
    @Published var axTrusted: Bool = AXIsProcessTrusted()
    func refreshAXTrust() {
        let t = AXIsProcessTrusted()
        if t != axTrusted { axTrusted = t }
    }
}

/// The settings surface shown *inside* the bar (toggled from the toolbar gear).
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: ClipStore
    /// Live, observable Accessibility-trust state (polled).
    private var axTrusted: Bool { settings.axTrusted }
    private let axTimer = Timer.publish(every: 1.2, on: .main, in: .common).autoconnect()

    private let limits: [(Int, String)] = [
        (0, "Unlimited"), (100, "100"), (200, "200"), (500, "500"), (1000, "1000"), (5000, "5000")
    ]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                section("General") {
                    Toggle("Launch at login", isOn: $settings.launchAtLogin)
                    HStack {
                        Text("Global shortcut").foregroundStyle(.secondary)
                        Spacer()
                        keycap("⌃⌥⌘V")
                    }
                    Toggle("Take over focus when summoned", isOn: $settings.activateOnSummon)
                    Text(settings.activateOnSummon
                         ? "On: Cliphoard becomes the active app each time you summon it. Use this only if typing doesn't reliably land in the search field — it briefly takes the menu bar from your app and makes pasting a touch slower."
                         : "Off (recommended): the bar floats over your work without taking over — your current app keeps its focus and menu bar, and pasting back is faster. Turn this on only if the search field won't accept typing on your setup.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("Appearance") {
                    HStack {
                        Text("Theme")
                        Spacer()
                        Picker("", selection: $settings.themePreset) {
                            ForEach(ThemePreset.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().frame(width: 180)
                    }
                    HStack {
                        Text("Layout")
                        Spacer()
                        Picker("", selection: $settings.layoutMode) {
                            ForEach(LayoutMode.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().frame(width: 180)
                    }
                    Text(settings.layoutMode.subtitle)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                section("Sound") {
                    Toggle("Play sound on copy", isOn: $settings.soundEnabled)
                    HStack {
                        Text("Copy sound").foregroundStyle(settings.soundEnabled ? .primary : .secondary)
                        Spacer()
                        Picker("", selection: $settings.soundName) {
                            ForEach(Feedback.availableSounds, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                        .disabled(!settings.soundEnabled)
                        Button {
                            settings.previewSound()
                        } label: { Image(systemName: "play.circle") }
                        .buttonStyle(.plain)
                        .disabled(!settings.soundEnabled)
                    }
                }

                section("Search") {
                    HStack {
                        Text("Mode")
                        Spacer()
                        Picker("", selection: $settings.searchMode) {
                            ForEach(SearchMode.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().frame(width: 150)
                    }
                    HStack {
                        Text("Embedding model")
                        Spacer()
                        Picker("", selection: $settings.deepSearchLevel) {
                            // .high (EmbeddingGemma) has no bundled/converted model and
                            // always falls back, so it's not offered (audit BL-17).
                            ForEach(DeepSearchLevel.allCases.filter { $0 != .high }) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().frame(width: 180)
                        .disabled(settings.searchMode == .exact)
                    }
                    embedderStatus
                    Text("Smart = clips containing exactly what you typed first, then the closest in meaning · Exact = only clips containing the typed text, ignoring case · Tag = clips in the auto category (of 100) closest to your query. You can also switch modes from the pill next to the search field. Models run on-device (CoreML).")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                section("Tags") {
                    HStack {
                        Text("Basket")
                        Spacer()
                        Picker("", selection: $settings.activeBasket) {
                            ForEach(TagBaskets.all) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden().frame(width: 170)
                    }
                    Text(TagBaskets.active.isDimensional
                         ? "\(TagBaskets.active.dimensions.count) dimensions × 10 — every clip is classified along all of them (one value per dimension)."
                         : "\(TagBaskets.active.tags.count) tags — clips are classified into their nearest few.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)

                    // The active basket's tags, in a bounded, clipped, scrollable
                    // box (a lazy grid does NOT clip, so it must live in a ScrollView
                    // with a fixed height or it overflows onto other sections). A
                    // dimensional basket groups its tags under each dimension header;
                    // a flat basket shows one flowing pool.
                    ScrollView(.vertical, showsIndicators: true) {
                        if TagBaskets.active.isDimensional {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(TagBaskets.active.dimensions.enumerated()), id: \.offset) { _, dim in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(dim.name.uppercased())
                                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                                        FlowLayout(spacing: 5) {
                                            ForEach(dim.tags, id: \.self) { tag in tagPill(tag) }
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        } else {
                            FlowLayout(spacing: 5) {
                                ForEach(TagBaskets.active.tags, id: \.self) { tag in tagPill(tag) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        }
                    }
                    .frame(height: 160)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    if settings.activeBasket == "custom" {
                        Text("Custom tags (one per line)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        TextEditor(text: $settings.customTagsText)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 90)
                            .padding(4)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                        HStack {
                            Spacer()
                            Button("Apply tags") { settings.applyCustomTags() }.controlSize(.small)
                        }
                    }
                }

                section("History") {
                    HStack {
                        Text("Keep")
                        Spacer()
                        Picker("", selection: $settings.historyLimit) {
                            ForEach(limits, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                    }
                    HStack {
                        Text("\(store.items.count) item\(store.items.count == 1 ? "" : "s") stored")
                            .foregroundStyle(.secondary).font(.system(size: 12))
                        Spacer()
                        Button("Clear Unpinned", role: .destructive) { store.clearUnpinned() }
                            .controlSize(.small)
                    }
                }

                section("Permissions & Advanced") {
                    HStack {
                        Image(systemName: axTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(axTrusted ? .green : .orange)
                        Text(axTrusted ? "Accessibility granted (auto-paste enabled)"
                                        : "Accessibility needed for auto-paste")
                            .font(.system(size: 12))
                        Spacer()
                        if !axTrusted {
                            Button("Grant…") { promptAccessibility() }
                                .controlSize(.small)
                        }
                    }
                    if !axTrusted {
                        HStack {
                            Text("Already granted but still showing? macOS applies it on relaunch.")
                                .font(.system(size: 11)).foregroundStyle(.tertiary)
                            Spacer()
                            Button("Relaunch") { relaunch() }.controlSize(.small)
                        }
                    }
                    Toggle("Debug logging", isOn: $settings.debugLogging)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity)
        .onReceive(axTimer) { _ in settings.refreshAXTrust() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refreshAXTrust()
        }
    }

    /// Quit and relaunch so a just-granted Accessibility permission is picked up.
    private func relaunch() {
        let url = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", url.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: Building blocks

    /// Live status line for the active embedder. The hashing fallback means no
    /// converted semantic model is loaded; anything else is a real on-device model.
    @ViewBuilder
    private var embedderStatus: some View {
        let signature = EmbedderProvider.active.signature
        let isFallback = signature.hasPrefix("hashing")
        HStack(spacing: 6) {
            Image(systemName: isFallback ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isFallback ? .orange : .green)
            Text(isFallback ? "Semantic models not installed — using basic matching"
                            : "Semantic model active: \(signature)")
                .foregroundStyle(isFallback ? Color.secondary : Color.green)
        }
        .font(.system(size: 11))
    }

    /// A single accent-tinted tag capsule, shared by the flat and dimensional
    /// taxonomy displays.
    private func tagPill(_ tag: String) -> some View {
        Text(tag)
            .font(.system(size: 11)).lineLimit(1).fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Theme.accent.opacity(0.12), in: Capsule())
            .foregroundStyle(Theme.accent)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)   // was .tertiary — too dim on the panel material
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(12)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        }
        .font(.system(size: 13))
    }

    private func keycap(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
    }

    private func promptAccessibility() {
        _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary)
    }
}
