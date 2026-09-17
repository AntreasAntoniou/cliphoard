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

    /// This install's entitlement, from the one object every view here already observes.
    /// Read through rather than copied, so a key pasted below changes every gated surface
    /// in the same frame.
    var entitlement: Entitlement { store.entitlement }

    /// What the user has typed into the Pro key field. Not the stored key — `verifyLicence`
    /// is what commits it, so a half-pasted key never becomes the live one.
    @Published var licenceKeyField: String = ""
    /// Set when a gated control was touched by a free build. The surfaces read it to explain
    /// the refusal instead of appearing broken — a control that silently does nothing is the
    /// exact defect `FrozenControlsTests` exists to catch, and a PAID one doing it is worse.
    /// Tagged with the surface so the explanation renders under the control that raised it.
    @Published var proPitch: ProPitch?

    func pitch(_ surface: ProSurface) -> String? {
        proPitch?.surface == surface ? proPitch?.message : nil
    }

    /// The order id of a live Pro entitlement, for the Settings section to show once verified.
    var proOrderID: String? { if case .pro(let order, _) = entitlement { return order }; return nil }
    var proIssued: Date? { if case .pro(_, let issued) = entitlement { return issued }; return nil }

    /// Why the last Verify press failed, or nil. A licence field that rejects a key without
    /// saying why sends the buyer to email; `Licence.verify` already returns the reason.
    var licenceError: String? {
        guard let verdict = licenceVerdict, case .free(let reason) = verdict else { return nil }
        return reason ?? "that field is empty"
    }

    /// Verify what is in the field and keep it only if it is real. A key that does not
    /// verify is NOT stored: storing it would make Settings show a key while the app behaves
    /// as free, which is the most confusing state a licence UI can be in.
    func verifyLicence() {
        let typed = licenceKeyField.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = Licence.verify(typed)
        if result.isPro {
            Licence.store(typed)
            proPitch = nil
        } else {
            Licence.remove()
        }
        store.entitlement = Licence.current
        licenceVerdict = result
        syncGatedSettingsToEntitlement()
    }

    func removeLicence() {
        Licence.remove()
        licenceKeyField = ""
        licenceVerdict = nil
        store.entitlement = Licence.current
        syncGatedSettingsToEntitlement()
    }

    /// The verdict of the last Verify press, or nil if none. Separate from `entitlement` so
    /// a FAILED paste can say why ("signature does not verify") rather than silently
    /// reverting to a free build with no explanation.
    @Published var licenceVerdict: Entitlement?

    /// After a licence change, bring the gated settings back in line with what the build
    /// will actually do. Only ever turns things OFF (or leaves them), never deletes: the
    /// history limit is deliberately NOT rewritten here — see `ClipStore.allowedHistoryLimit`.
    private func syncGatedSettingsToEntitlement() {
        // A verified key turns the image features ON. 1.0.0's default was on for everyone,
        // and a buyer whose paid feature is silently off has bought a support ticket — so a
        // deliberate Verify press is allowed to override a previous off. Only a press does
        // this; nothing here runs on its own.
        if entitlement.isPro { ClipStore.setImageUnderstanding(true, entitlement: entitlement) }
        let allowed = ClipStore.imageUnderstandingAllowed(entitlement)
        if imageUnderstanding != allowed { imageUnderstanding = allowed }
        if !SearchMode.available(entitlement).contains(searchMode) { searchMode = .smart }
    }
    @Published var launchAtLogin: Bool { didSet { LoginItem.set(launchAtLogin) } }
    @Published var activateOnSummon: Bool { didSet { UserDefaults.standard.set(activateOnSummon, forKey: "activateOnSummon") } }
    /// Turning this ON schedules the pass immediately, so the setting takes effect while
    /// the user is still looking at it. Turning it OFF stops FUTURE recognition but does
    /// not erase what was already read — that is what "Forget" is for, and PRIVACY.md
    /// says so explicitly rather than letting the toggle imply more than it does.
    @Published var imageUnderstanding: Bool {
        didSet {
            ClipStore.setImageUnderstanding(imageUnderstanding, entitlement: entitlement)
            // GATE 2. The toggle is disabled for a free build, but a binding is not a
            // permission: bounce the published value back so the switch cannot sit in the
            // ON position describing work this build will not do.
            let allowed = ClipStore.imageUnderstandingAllowed(entitlement)
            if imageUnderstanding != allowed {
                proPitch = ProPitch(.imageUnderstanding,
                                    "Reading text inside your screenshots is Cliphoard Pro. "
                                    + Licence.pitch)
                imageUnderstanding = allowed
                return
            }
            if imageUnderstanding { store.scheduleImageUnderstanding() }
        }
    }
    /// See `WebPaste.isEnabled`. On by default from 1.0.0, with this toggle as the way out: it
    /// is the only feature that rewrites what another app put on the clipboard, and macOS
    /// requires taking ownership to do it. `didSet` fires only on a user change, so an
    /// untouched toggle leaves the key ABSENT (= on) and a flip to off stores an explicit
    /// false that survives upgrades.
    @Published var webSafeScreenshots: Bool {
        didSet { WebPaste.isEnabled = webSafeScreenshots }
    }
    @Published var themePreset: ThemePreset { didSet { Theme.preset = themePreset } }
    @Published var layoutMode: LayoutMode { didSet { Theme.layout = layoutMode } }
    @Published var searchMode: SearchMode {
        didSet {
            // GATE 1. The Pro row is SHOWN (naming the limit honestly is this app's habit —
            // see `SearchMode.blurb`) and selecting it cannot take effect. Bouncing back to
            // the previous mode, rather than disabling the row, is what makes this work in
            // both pickers without relying on SwiftUI honouring `.disabled` inside a menu.
            guard SearchMode.available(entitlement).contains(searchMode) else {
                proPitch = ProPitch(.imageSearch,
                                    "Searching your pictures by describing them is Cliphoard "
                                    + "Pro. " + Licence.pitch)
                searchMode = oldValue
                return
            }
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
    @Published var vectorDetail: VectorDetail {
        didSet {
            DeepSearch.detail = vectorDetail
            // A head switch changes the embedder signature (different vector
            // space), so reconfigure + re-embed exactly like a model change.
            EmbedderProvider.configureAndReindex(level: deepSearchLevel, store: store)
        }
    }
    @Published var activeBasket: String {
        didSet {
            // "general" = base only (no overlay); "custom" = the flat editable
            // pool; anything else = that specialist layered on General.
            TagBaskets.overlayID = (activeBasket == "general") ? nil : activeBasket
            store.rebuildTagIndex()     // synchronous: ids are derived, not stored
        }
    }

    /// Every specialist basket layered on General, in selection order. Replaces the single
    /// `activeBasket` overlay; that property is kept because "custom" still selects the flat
    /// pool as a whole basket rather than composing onto General.
    @Published var overlayBaskets: [String] {
        didSet {
            TagBaskets.overlayIDs = overlayBaskets
            store.rebuildTagIndex()
        }
    }
    @Published var assignmentThreshold: Double {
        didSet {
            TagSpace.assignmentThreshold = Float(assignmentThreshold)
            store.rebuildTagIndex()
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
        if activeBasket == "custom" { store.rebuildTagIndex() }
    }

    /// Shows the user what "Forget" would actually erase, before they press it. A
    /// destructive button with no stated scope invites either paralysis or regret.
    var imageUnderstandingStatus: String {
        let n = store.recognisedImageCount
        if let progress = store.imageProgress, progress.total > 0 {
            return "Reading images… \(progress.done)/\(progress.total)"
        }
        return n == 0 ? "No text read from images yet"
                      : "Text read from \(n) image\(n == 1 ? "" : "s")"
    }

    func forgetImageUnderstanding() { store.forgetImageUnderstanding() }

    init(store: ClipStore) {
        self.store = store
        soundEnabled = Feedback.soundEnabled
        soundName = Feedback.soundName
        debugLogging = DebugLog.enabled
        historyLimit = store.historyLimit
        launchAtLogin = LoginItem.enabled
        activateOnSummon = UserDefaults.standard.bool(forKey: "activateOnSummon")
        // The ALLOWED value, not the stored preference: the preference defaults to ON for an
        // untouched install, and a free build showing that switch on would be describing work
        // it does not do.
        imageUnderstanding = ClipStore.imageUnderstandingAllowed(store.entitlement)
        webSafeScreenshots = WebPaste.isEnabled
        themePreset = Theme.preset
        layoutMode = Theme.layout
        searchMode = DeepSearch.mode
        deepSearchLevel = DeepSearch.level
        vectorDetail = DeepSearch.detail
        activeBasket = TagBaskets.overlayID ?? "general"
        overlayBaskets = TagBaskets.overlayIDs
        assignmentThreshold = Double(TagSpace.assignmentThreshold)
        customTagsText = TagBaskets.custom.tags.joined(separator: "\n")
        licenceKeyField = UserDefaults.standard.string(forKey: Licence.defaultsKey) ?? ""
        licenceVerdict = store.entitlement.isPro ? store.entitlement : nil
        // A persisted `.image` selection can OUTLIVE the entitlement that allowed it — a
        // removed key, a refund, a fresh free install on a defaults domain that still has the
        // old selection. Without this the app opens in a mode that is selected, cannot run,
        // and can only return an empty list — the one state both `FrozenControlsTests` and
        // `SearchMode.blurb` exist to prevent, arrived at through the paywall this time
        // rather than through a missing model.
        //
        // `DeepSearch.mode` is written EXPLICITLY, and the reason is worth recording because
        // it is the opposite of what the language rule suggests. Observers do not fire for
        // assignments during initialisation — but `searchMode` is `@Published`, a property
        // WRAPPER, and once the wrapper itself is initialised an assignment goes through its
        // setter, so `didSet` does fire and would write this through on its own. Measured,
        // not assumed: removing this line leaves the test green. It stays anyway, because the
        // persistence of a paid gate should not rest on a subtlety that vanishes the day
        // someone drops `@Published` for an `@Observable` macro.
        if !SearchMode.available(store.entitlement).contains(searchMode) {
            searchMode = .smart
            DeepSearch.mode = .smart
        }
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
    /// Owns the import scan/preview/commit flow. StateObject rather than a plain
    /// property so a preview survives the view re-rendering while the user reads it.
    @StateObject private var importModel = ImportModel()
    /// Embedder lifecycle (ready / downloading N% / installing / failed) for the
    /// live status line — auto-install progress renders here.
    @ObservedObject private var embedderState = EmbedderState.shared
    /// Live, observable Accessibility-trust state (polled).
    private var axTrusted: Bool { settings.axTrusted }
    private let axTimer = Timer.publish(every: 1.2, on: .main, in: .common).autoconnect()

    /// Free rows first, Pro rows last. The order is the tier boundary made visible: everything
    /// above the line is in the build you already have.
    private let limits: [(Int, String)] = [
        (100, "100"), (200, "200"), (500, "500"), (1000, "1000"), (5000, "5000"), (0, "Unlimited")
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
                    Divider()
                    HStack {
                        Text("Quit Cliphoard").foregroundStyle(.secondary)
                        Spacer()
                        Button("Quit") { AppLifecycle.quit() }.controlSize(.small)
                    }
                }

                // GATE 6. Between General and Appearance, where someone looking for "how do
                // I pay / where did my key go" will find it without scrolling past the tags.
                section("Cliphoard Pro") {
                    HStack(spacing: 6) {
                        Image(systemName: settings.entitlement.isPro ? "checkmark.seal.fill" : "lock.fill")
                            .foregroundStyle(settings.entitlement.isPro ? Color.green : Color.secondary)
                        Text(settings.entitlement.isPro
                             ? "Pro is active on this Mac"
                             : "Free build — a full clipboard manager, with no time limit")
                        Spacer()
                        if !settings.entitlement.isPro {
                            Button("Get Pro — \(Licence.priceLabel)") {
                                NSWorkspace.shared.open(Licence.buyURL)
                            }
                            .controlSize(.small)
                        }
                    }
                    if let order = settings.proOrderID {
                        HStack {
                            // The order id is shown ONCE VERIFIED and nowhere else: it is what
                            // the buyer quotes in an email when something goes wrong, and it is
                            // the only thing in the key worth reading back to them.
                            Text("Order \(order)"
                                 + (settings.proIssued.map {
                                     " · issued \($0.formatted(date: .abbreviated, time: .omitted))"
                                 } ?? ""))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Spacer()
                            Button("Remove") { settings.removeLicence() }.controlSize(.small)
                        }
                    }
                    HStack {
                        TextField("CLIP1-…", text: $settings.licenceKeyField)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                        Button("Verify") { settings.verifyLicence() }
                            .controlSize(.small)
                            .disabled(settings.licenceKeyField
                                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let error = settings.licenceError {
                        // A key that does not verify is NOT stored, so this says why rather
                        // than leaving a field full of text next to a build behaving as free.
                        Text("That key did not verify — \(error). Nothing was saved.")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    }
                    Text("Your key is checked on this Mac, offline, against a public key "
                         + "compiled into the app. There is no licence server, no activation "
                         + "and no call of any kind — and so nothing anyone could switch off. "
                         + "Pro is \(Licence.priceLabel) once: one person, every Mac you own.")
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

                section("Images") {
                    HStack(spacing: 6) {
                        // UPSELL 3. Disabled rather than hidden, and badged rather than merely
                        // greyed: a switch that has vanished teaches nothing, and a greyed one
                        // with no label is a bug report.
                        Toggle("Read text in images", isOn: $settings.imageUnderstanding)
                            .disabled(!settings.entitlement.isPro)
                        if !settings.entitlement.isPro { ProBadge() }
                        Spacer()
                    }
                    if let pitch = settings.pitch(.imageUnderstanding) {
                        ProPitchCard(message: pitch)
                    }
                    // Deliberately says what it does AND what it refuses, because the
                    // difference is the whole reason this is defensible. Claims nothing
                    // the code does not deliver — the authenticator-code gap is stated in
                    // PRIVACY.md rather than glossed here.
                    Text("Reads text inside your images on this Mac so you can search "
                         + "screenshots, and finds visually similar images. Stored "
                         + "encrypted, never sent anywhere. Text that looks like a "
                         + "password, key, one-time code, card or bank detail, or a "
                         + "postal address is not stored at all.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack {
                        Text(settings.imageUnderstandingStatus)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Forget recognised text") { settings.forgetImageUnderstanding() }
                            .disabled(store.recognisedImageCount == 0 || store.safeMode)
                    }

                    Divider().padding(.vertical, 2)

                    Toggle("Make screenshots pasteable in web apps",
                           isOn: $settings.webSafeScreenshots)
                    // Says what it COSTS, not just what it does. This is the only feature
                    // that rewrites what another app put on the clipboard, and it is on by
                    // default — so the downsides go here, where the switch is, not in a footnote.
                    Text("macOS puts screenshots on the clipboard in a format browsers "
                         + "cannot read, so pasting one into Messenger, Gmail or any web "
                         + "app silently does nothing. This adds a format they understand.\n"
                         + "To do that Cliphoard has to take ownership of the clipboard and "
                         + "rewrite it — macOS offers no other way. Your screenshot is "
                         + "carried across, but apps that ask for TIFF get a standard-range "
                         + "image instead of a wide-gamut one, and the clipboard's owner "
                         + "shows as Cliphoard. If the rewrite fails the original is put "
                         + "back; if that also fails the clipboard is left empty, which is "
                         + "unlikely but possible. On by default. Turn it off and Cliphoard "
                         + "never rewrites what another app put on your clipboard.")
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
                            // UPSELL 1. The Pro mode is LISTED, named as Pro, and selecting it
                            // is bounced by `AppSettings.searchMode`'s gate — so it can never
                            // become a mode that is selected and silently returns nothing.
                            ForEach(SearchMode.allCases) { mode in
                                Text(SearchMode.available(settings.entitlement).contains(mode)
                                     ? mode.title : "\(mode.title) — Pro").tag(mode)
                            }
                        }
                        .labelsHidden().frame(width: 150)
                    }
                    if let pitch = settings.pitch(.imageSearch) {
                        ProPitchCard(message: pitch)
                    }
                    HStack {
                        Text("Embedding model")
                        Spacer()
                        Picker("", selection: $settings.deepSearchLevel) {
                            // ogma micro/small (MIT) ship bundled; MiniLM (Apache-2.0)
                            // downloads on demand. Every tier is permissively licensed.
                            ForEach(DeepSearchLevel.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().frame(width: 200)
                        .disabled(settings.searchMode == .exact)
                    }
                    HStack {
                        Text("Vector detail")
                        Spacer()
                        Picker("", selection: $settings.vectorDetail) {
                            ForEach(VectorDetail.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().frame(width: 180)
                        // Head selection exists only on the ogma models; the HF
                        // tier (MiniLM) has a fixed output head.
                        .disabled(settings.searchMode == .exact || !settings.deepSearchLevel.isOgma)
                    }
                    Text("Vector detail (ogma tiers): Full uses the 1024-d bge-large-distilled head — strongest search; Compact stores 2.7× smaller vectors. High runs MiniLM (fast, excellent) and downloads on first use. Switching re-indexes in the background.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    embedderStatus
                    Text("Smart = clips containing exactly what you typed first, then the closest in meaning · Exact = only clips containing the typed text, ignoring case · Tag = clips in the auto category (of 100) closest to your query. You can also switch modes from the pill next to the search field. Models run on-device (CoreML).")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                section("Tags") {
                    HStack(alignment: .top) {
                        Text("Baskets")
                        Spacer()
                        // MULTI-SELECT. One overlay forced a false choice: a developer who
                        // also keeps receipts had to pick which half of their clipboard got
                        // classified. Dimensions merge by name, so stacking is well defined
                        // and later selections win a collision.
                        //
                        // A Menu of toggles rather than a multi-select list: the set is
                        // small, the choice is rare, and this keeps the row one line tall
                        // while showing the current selection in the label — which a list
                        // does not, once it scrolls.
                        Menu {
                            ForEach(TagBaskets.all.filter { $0.id != "general" }) { basket in
                                Toggle(isOn: Binding(
                                    get: { settings.overlayBaskets.contains(basket.id) },
                                    set: { on in
                                        var next = settings.overlayBaskets
                                        if on {
                                            if !next.contains(basket.id) { next.append(basket.id) }
                                        } else {
                                            next.removeAll { $0 == basket.id }
                                        }
                                        settings.overlayBaskets = next
                                    })) {
                                        Text(basket.name)
                                    }
                            }
                        } label: {
                            Text(settings.overlayBaskets.isEmpty
                                 ? "General only"
                                 : ([TagBaskets.general.name]
                                    + settings.overlayBaskets.compactMap { id in
                                        TagBaskets.all.first { $0.id == id }?.name
                                    }).joined(separator: " + "))
                                .lineLimit(2)
                                .multilineTextAlignment(.trailing)
                        }
                        .frame(width: 190)
                    }
                    Text(basketSummary)
                        .font(.system(size: 11)).foregroundStyle(.secondary)

                    HStack {
                        Text("Confidence floor")
                        Slider(value: $settings.assignmentThreshold, in: 0...0.8, step: 0.01)
                        Text(settings.assignmentThreshold, format: .number.precision(.fractionLength(2)))
                            .font(.system(size: 11, design: .monospaced)).frame(width: 36)
                    }
                    Text("Average automatic tags per clip: \(averageAutomaticTags, specifier: "%.1f")")
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
                                if !TagBaskets.active.topical.isEmpty {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("TOPICAL")
                                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                                        FlowLayout(spacing: 5) {
                                            ForEach(TagBaskets.active.topical, id: \.self) { tag in tagPill(tag) }
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

                section("Import") {
                    ImportSection(model: importModel, store: store)
                }

                section("History") {
                    HStack {
                        Text("Keep")
                        Spacer()
                        // UPSELL 2 + GATE 3. The Pro rows are shown, named, and refuse to
                        // apply — through an explicit binding rather than the published value,
                        // so the picker and the store can never disagree about what is kept.
                        Picker("", selection: Binding(
                            get: { settings.historyLimit },
                            set: { requested in
                                guard settings.entitlement.isPro
                                        || ClipStore.freeHistoryLimits.contains(requested) else {
                                    settings.proPitch = ProPitch(.history,
                                        "Keeping more than \(ClipStore.freeHistoryLimit) unpinned "
                                        + "clips is Cliphoard Pro. Nothing you already have is "
                                        + "removed — pinned clips never expire and never count. "
                                        + Licence.pitch)
                                    return
                                }
                                settings.proPitch = nil
                                settings.historyLimit = requested
                            })) {
                            ForEach(limits, id: \.0) { value, label in
                                Text(settings.entitlement.isPro
                                     || ClipStore.freeHistoryLimits.contains(value)
                                     ? label : "\(label) — Pro").tag(value)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                    if let pitch = settings.pitch(.history) {
                        ProPitchCard(message: pitch)
                    }
                    HStack {
                        Text("\(store.items.count) item\(store.items.count == 1 ? "" : "s") stored")
                            .foregroundStyle(.secondary).font(.system(size: 12))
                        Spacer()
                        Button("Clear Unpinned", role: .destructive) { store.clearUnpinned() }
                            .controlSize(.small)
                            .disabled(store.safeMode)   // refuses while frozen
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
    /// Quit and relaunch so a just-granted Accessibility permission is picked up.
    private func relaunch() { AppLifecycle.requestRelaunch() }

    // MARK: Building blocks

    /// Live embedder lifecycle line. Distinguishes downloading / installing /
    /// loading from a real absence — models auto-install when a tier is picked,
    /// so "not installed" is only ever a transient or an error, never a task
    /// for the user.
    @ViewBuilder
    private var embedderStatus: some View {
        HStack(spacing: 6) {
            switch embedderState.state {
            case .ready(let signature):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Semantic model active: \(signature)").foregroundStyle(Color.green)
            case .downloading(let name, let progress):
                ProgressView().controlSize(.small)
                Text("Downloading \(name)… \(Int(progress * 100))%")
                    .foregroundStyle(.secondary)
            case .installing(let name):
                ProgressView().controlSize(.small)
                Text("Installing \(name)… (one-time)").foregroundStyle(.secondary)
            case .loading(let name):
                ProgressView().controlSize(.small)
                Text("Loading \(name)…").foregroundStyle(.secondary)
            case .failed(let name, let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("\(name) install failed: \(message)").foregroundStyle(.secondary)
                Button("Retry") {
                    EmbedderProvider.configureAndReindex(level: settings.deepSearchLevel, store: store)
                }
                .controlSize(.small)
            case .fallback:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Basic matching only — pick a model tier above to auto-install one")
                    .foregroundStyle(.secondary)
            }
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

    private var averageAutomaticTags: Double {
        let signature = EmbedderProvider.active.signature
        let counts = store.items
            .filter { $0.embeddings[signature] != nil }
            .map { store.tags(of: $0).count }
        guard !counts.isEmpty else { return 0 }
        return Double(counts.reduce(0, +)) / Double(counts.count)
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

    /// Describes the active vocabulary. After the Wave-4 retirement General owns
    /// no axes and no topical tail, so the old string rendered the nonsense
    /// "0 axes × 8 + 0 topical tags"; that state is now named honestly.
    private var basketSummary: String {
        let b = TagBaskets.active
        guard b.isDimensional else {
            return "\(b.tags.count) tags — clips are classified into their nearest few."
        }
        if b.tags.isEmpty {
            return "Tags come from deterministic detection only — no model-guessed labels."
        }
        if b.dimensions.isEmpty {
            return "\(b.topical.count) topical tags — weak matches stay blank."
        }
        return "\(b.dimensions.count) axes × 8 + \(b.topical.count) topical tags — weak matches stay blank."
    }

}
