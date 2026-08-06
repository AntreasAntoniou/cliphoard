import SwiftUI
import AppKit

/// The signal facets currently switched on in the filter menu.
///
/// Lives outside `PanelViewModel` because the model owns the *store-resolved*
/// filters (kind, pin, time, tag facets, user tags) and resolving a signal needs
/// no index at all — `ClipSignal.matches` is a pure predicate over fields the
/// clip already carries. Keeping it here also means the chips a user sees and
/// the filters they can apply are defined in one place (`ClipSignal`).
///
/// Selection is deliberately *not* persisted across summons: the panel rebuilds
/// its hosting view on every summon, so this starts empty each time. A filter
/// that silently survives into the next summon would hide clips the user does
/// not remember hiding — and failing open (showing everything) is the safe
/// direction for a *display* filter.
@MainActor
final class SignalFilterModel: ObservableObject {
    /// Facet semantics, matching the tag-dimension menu: values within a group
    /// OR, groups AND.
    @Published var active: Set<ClipSignal> = []

    var count: Int { active.count }

    func toggle(_ signal: ClipSignal) {
        if active.contains(signal) { active.remove(signal) } else { active.insert(signal) }
    }

    /// Whether `item` survives the active filter. Empty filter → everything.
    func matches(_ item: ClipItem, now: Date) -> Bool {
        guard !active.isEmpty else { return true }
        var byGroup: [ClipSignal.Group: [ClipSignal]] = [:]
        for signal in active { byGroup[signal.group, default: []].append(signal) }
        for (_, signals) in byGroup {
            guard signals.contains(where: { $0.matches(item, now: now) }) else { return false }
        }
        return true
    }
}

/// One clip as it appears on screen, carrying its index in `model.results`.
///
/// The index is load-bearing: the model owns keyboard selection, ⌘1–9 quick
/// paste and Enter-to-commit, and every one of those indexes into
/// `model.results`. Rendering a filtered subset with *renumbered* positions
/// would make ⌘3 paste a different clip from the card labelled ⌘3 — with a
/// sensitivity filter on, quite possibly a secret the user could not see. So the
/// view renumbers nothing: it hides rows and keeps their real indices.
private struct DisplayedClip: Identifiable {
    /// Position in `model.results` — NOT the position on screen.
    let index: Int
    let item: ClipItem
    var id: UUID { item.id }
}

/// The bar content: search + category filters on top, a horizontal strip of
/// clip cards, and a keyboard-hint footer.
struct ContentView: View {
    @ObservedObject var model: PanelViewModel
    @ObservedObject var store: ClipStore
    /// Paste outcome surfaced by `AppDelegate.commit()`: a persistent banner when
    /// auto-paste is blocked (no Accessibility), and a brief success flash when a
    /// paste actually fires.
    @ObservedObject var pasteStatus: PasteStatus
    @StateObject private var settings: AppSettings
    /// Drives first-responder focus into the search field on summon (BL-11/H4):
    /// the panel is non-activating, so nothing otherwise makes the field key.
    @FocusState private var searchFocused: Bool
    /// Transient: shows a check briefly after a successful paste fires.
    @State private var showPasteConfirm = false
    /// Custom time-range popover state.
    @State private var showCustomDate = false
    @State private var customFrom = Date()
    @State private var customTo = Date()
    /// Builds the facet NSMenu on click (kept out of the summon-critical layout).
    @State private var facetMenu = FacetMenuController()
    /// Signal facets (flags / shape / source / lifecycle) switched on in that menu.
    @StateObject private var signals = SignalFilterModel()
    /// Previous `model.selection`, used only to infer which way the user was
    /// travelling when a filter hides the clip they landed on.
    @State private var lastSelection = 0

    init(model: PanelViewModel, store: ClipStore, pasteStatus: PasteStatus) {
        self.model = model
        self.store = store
        self.pasteStatus = pasteStatus
        _settings = StateObject(wrappedValue: AppSettings(store: store))
    }

    /// Shown when the store could not read its own data at launch.
    ///
    /// Deliberately states what has NOT happened ("nothing has been deleted or
    /// changed") as prominently as the problem: the failure mode we are guarding
    /// against is a user seeing garbled clips, assuming the app ate their history,
    /// and clearing it — destroying data that was still recoverable.
    @ViewBuilder private var safeModeBanner: some View {
        if store.safeMode {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Cliphoard can’t read \(store.unreadableClipCount) of \(store.items.count) clips")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Nothing has been deleted or changed. History is frozen until this is resolved.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Color.orange.opacity(0.14))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Warning: Cliphoard cannot read \(store.unreadableClipCount) of \(store.items.count) clips. "
                                + "Nothing has been deleted or changed. History is frozen until this is resolved.")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            safeModeBanner
            toolbar
            Divider().opacity(0.5)
            if let message = pasteStatus.blockedMessage { pasteBlockedBanner(message) }
            if let progress = store.indexing { indexingBar(progress) }
            if model.showSettings {
                SettingsView(settings: settings, store: store)
            } else {
                switch settings.layoutMode {
                case .strip:     cards
                case .spotlight: spotlightLayout
                case .list:      listLayout
                }
            }
            footer
        }
        .background(Theme.barBackground())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.t.border, lineWidth: 1)
        )
        .overlay(alignment: .top) {
            if showPasteConfirm { pasteConfirmFlash }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        // Theme preset: tint drives every Theme.accent control; the forced scheme
        // makes semantic .primary/.secondary text adapt; fontDesign gives Paper its serif.
        .tint(Theme.accent)
        .preferredColorScheme(Theme.t.scheme)
        .fontDesign(Theme.t.fontDesign)
        // Focus the search field whenever the bar is summoned (and not in settings),
        // so summon-then-type always lands. Deferred a tick so it runs after the
        // panel becomes key.
        .onChange(of: model.presentToken) { _ in
            guard !model.showSettings else { return }
            DispatchQueue.main.async { searchFocused = true }
        }
        .onChange(of: model.showSettings) { showing in
            DispatchQueue.main.async { searchFocused = !showing }
        }
        .onAppear { DispatchQueue.main.async { searchFocused = !model.showSettings } }
        .onChange(of: settings.searchMode) { _ in model.resetSelection() }
        // Keep keyboard selection on a card the user can actually see. Arrow keys
        // walk `model.results`, which still contains the clips this view is
        // hiding; without this, Enter could commit an invisible clip.
        .onChange(of: model.selection) { new in reconcileSelection(to: new) }
        .onChange(of: signals.active) { _ in reconcileSelection(to: model.selection) }
        // Brief success confirmation: a real paste bumps this token, so the flash
        // makes a successful paste distinguishable from a silent no-op.
        .onChange(of: pasteStatus.pasteConfirmToken) { _ in
            withAnimation(.easeOut(duration: 0.15)) { showPasteConfirm = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                withAnimation(.easeIn(duration: 0.25)) { showPasteConfirm = false }
            }
        }
        .sheet(item: $model.inspectedItem, onDismiss: { model.closeInspector() }) { item in
            ClipDetailView(
                item: item,
                store: store,
                focusTags: model.inspectorFocusTags,
                onPaste: { model.onPaste?(item, false) },
                onCopy: { model.onCopy?(item) },
                onClose: { model.closeInspector() }
            )
        }
    }

    // MARK: Paste status

    /// Persistent, non-modal banner shown on every blocked pick (Accessibility not
    /// granted): the clip is on the clipboard but the ⌘V keystroke can't fire, so
    /// this is the user's always-visible feedback + a one-tap path to fix it.
    private func pasteBlockedBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11)).foregroundStyle(Theme.accent)
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                pasteStatus.onOpenAccessibility?()
            } label: {
                Text("Open Settings")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(Color.white)
            }
            .buttonStyle(.plain)
            .help("Open Privacy → Accessibility to grant auto-paste")
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(Theme.accent.opacity(0.10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }

    /// A subtle, transient check that flashes after a paste actually fires.
    private var pasteConfirmFlash: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 11))
            Text("Pasted").font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Theme.accent, in: Capsule())
        .padding(.top, 14)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .allowsHitTesting(false)
    }

    // MARK: Toolbar

    /// The app's own hoard-bag icon for the top-left corner. Loaded from the
    /// bundled `Cliphoard.icns` (present in the built `.app`), with `NSApp`'s icon
    /// then the ⌘ glyph as fallbacks (e.g. a bare `swift run` with no bundled icon).
    private var brandIconImage: NSImage? {
        Bundle.main.image(forResource: "Cliphoard") ?? NSApp.applicationIconImage
    }

    @ViewBuilder private var brandMark: some View {
        if let icon = brandIconImage {
            Image(nsImage: icon)
                .resizable().interpolation(.high)
                .frame(width: 50, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .accessibilityHidden(true)
        } else {
            Image(systemName: "command").font(.system(size: 20)).foregroundStyle(Theme.accent)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                brandMark
                Text(model.showSettings ? "Settings" : "Cliphoard")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
            }

            if !model.showSettings { categoryChips }

            Spacer()

            if !model.showSettings {
                HStack(spacing: 8) {
                    timeMenu
                    // Always available now: the signal facets (flags, shape,
                    // source, lifecycle) exist regardless of which tag basket is
                    // loaded, so gating the whole menu on a dimensional basket
                    // would hide them.
                    filtersMenu
                    searchModePicker
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary).font(.system(size: 12))
                        TextField("Search clips", text: $model.query)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .frame(width: 160)
                            .focused($searchFocused)
                            .accessibilityLabel("Search clipboard")
                            .onChange(of: model.query) { _ in model.resetSelection() }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    // Visible focus affordance (BL-11): the field is first-responder on
                    // summon, but the blinking caret alone isn't legible at a glance.
                    .background(Color.primary.opacity(searchFocused ? 0.12 : 0.07), in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(Theme.accent.opacity(searchFocused ? 0.65 : 0), lineWidth: 1.5)
                    )
                }
            }

            Button {
                model.showSettings.toggle()
            } label: {
                Image(systemName: model.showSettings ? "xmark.circle.fill" : "gearshape.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(model.showSettings ? Color.secondary : Theme.accent)
            }
            .buttonStyle(.plain)
            .help(model.showSettings ? "Close settings" : "Settings")
            .accessibilityLabel(model.showSettings ? "Close settings" : "Settings")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var categoryChips: some View {
        HStack(spacing: 6) {
            chip(title: "All", systemImage: "square.grid.2x2", active: model.activeKind == nil && !model.pinnedOnly) {
                model.activeKind = nil; model.pinnedOnly = false; model.resetSelection()
            }
            chip(title: "Pinned", systemImage: "pin.fill", active: model.pinnedOnly) {
                model.pinnedOnly.toggle(); model.activeKind = nil; model.resetSelection()
            }
            let counts = store.counts()
            ForEach(ClipKind.allCases, id: \.self) { kind in
                if (counts[kind] ?? 0) > 0 {
                    chip(title: kind.title, systemImage: kind.symbolName,
                         active: model.activeKind == kind && !model.pinnedOnly) {
                        model.activeKind = (model.activeKind == kind ? nil : kind)
                        model.pinnedOnly = false
                        model.resetSelection()
                    }
                }
            }
        }
    }

    private func chip(title: String, systemImage: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 10))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(active ? Theme.accent : Color.primary.opacity(0.07),
                        in: Capsule())
            .foregroundStyle(active ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    /// The visible search-mode switcher next to the search field (Smart / Exact /
    /// Tag). Uses the NATIVE macOS pop-up button (the system control everyone
    /// recognizes as a dropdown) so it unmistakably reads as clickable — a custom
    /// Menu label has its background/chevron stripped by .borderlessButton style.
    private var searchModePicker: some View {
        HStack(spacing: 5) {
            Text("Search:").font(.system(size: 11)).foregroundStyle(.secondary)
            Picker("Search mode", selection: $settings.searchMode) {
                ForEach(SearchMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .tint(Theme.accent)
        }
        .help("Search mode — Smart, Exact, or Tag")
        .accessibilityLabel("Search mode: \(settings.searchMode.title)")
    }

    /// Time filter — pick when a clip was copied with plain words, or a custom
    /// date range. Mirrors the `when:` query tokens. Filters on `createdAt`.
    private var timeMenu: some View {
        Menu {
            let presets: [(String, TimeFilter)] = [
                ("Any time", .any), ("Today", .today), ("Yesterday", .yesterday),
                ("This week", .thisWeek), ("This month", .thisMonth),
                ("Last 7 days", .last7), ("Last 30 days", .last30)
            ]
            ForEach(presets, id: \.0) { title, filter in
                Button {
                    model.timeFilter = filter; model.resetSelection()
                } label: {
                    if model.timeFilter == filter { Label(title, systemImage: "checkmark") }
                    else { Text(title) }
                }
            }
            Divider()
            Button("Custom range…") {
                if case .range(let a, let b) = model.timeFilter { customFrom = a; customTo = b }
                showCustomDate = true
            }
        } label: {
            filterChipLabel(icon: "clock",
                            text: model.timeFilter.isActive ? model.timeFilter.label : "Time",
                            active: model.timeFilter.isActive)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by when the clip was copied")
        .popover(isPresented: $showCustomDate, arrowEdge: .bottom) { customDatePopover }
    }

    private var customDatePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Custom range").font(.system(size: 12, weight: .semibold))
            DatePicker("From", selection: $customFrom, displayedComponents: .date)
            DatePicker("To", selection: $customTo, displayedComponents: .date)
            HStack {
                Spacer()
                Button("Clear") { model.timeFilter = .any; model.resetSelection(); showCustomDate = false }
                Button("Apply") {
                    model.timeFilter = .range(customFrom, customTo)
                    model.resetSelection(); showCustomDate = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 240)
    }

    /// Facet-cube filters — one submenu per dimension, toggling a value on/off.
    /// Values within a dimension OR; across dimensions AND (facet semantics).
    ///
    /// Deliberately NOT a SwiftUI `Menu`: the panel rebuilds its hosting view
    /// synchronously on every summon (FloatingPanel.refresh), and a Menu's ~110
    /// items (10 dimensions × 10 values) were materialized eagerly inside that
    /// layout — a measurable summon delay. A plain chip that builds an NSMenu on
    /// click keeps the summon path O(1); the menu's cost is paid only when opened.
    private var filtersMenu: some View {
        let filterCount = model.activeFacets.count + model.activeUserTags.count + signals.count
        return Button {
            facetMenu.present(model: model, signals: signals)
        } label: {
            filterChipLabel(icon: "line.3.horizontal.decrease.circle",
                            text: filterCount == 0 ? "Filters" : "Filters (\(filterCount))",
                            active: filterCount > 0)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Filter by what the cards show — secrets, shape, source app, lifecycle, your tags")
    }

    /// Chip-styled label shared by the time and filter menus, matching the
    /// category chips' look so the toolbar reads as one control family.
    private func filterChipLabel(icon: String, text: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(active ? Theme.accent : Color.primary.opacity(0.07), in: Capsule())
        .foregroundStyle(active ? Color.white : Color.primary)
    }

    // MARK: Signal filtering

    /// `model.results` narrowed by the signal filter, each row keeping its index
    /// in `model.results` (see ``DisplayedClip``).
    ///
    /// `Date()` is sampled once per pass so every row in one render answers the
    /// age-derived predicates against the same instant.
    private var displayed: [DisplayedClip] {
        let results = model.results
        guard !signals.active.isEmpty else {
            return results.enumerated().map { DisplayedClip(index: $0.offset, item: $0.element) }
        }
        let now = Date()
        return results.enumerated().compactMap { offset, item in
            signals.matches(item, now: now) ? DisplayedClip(index: offset, item: item) : nil
        }
    }

    /// Move keyboard selection off a clip the signal filter is hiding, in the
    /// direction the user was travelling.
    ///
    /// Selection lives in the model and is driven by ⌘-key handlers this view
    /// cannot see, so the view corrects it after the fact instead of trying to
    /// own it. The direction inference makes ← and → skip a hidden run the way
    /// they would if the run were not there at all; the wrap cases are checked
    /// explicitly because `moveSelection` wraps at both ends.
    ///
    /// Idempotent: the write below re-enters this method once, finds the new
    /// index visible, and stops.
    private func reconcileSelection(to target: Int) {
        defer { lastSelection = model.selection }
        guard !signals.active.isEmpty else { return }
        let count = model.results.count
        guard count > 0 else { return }
        let visible = Set(displayed.map(\.index))
        // Everything is filtered out: leave selection alone rather than point it
        // somewhere arbitrary. The strip shows its empty state.
        guard !visible.isEmpty, !visible.contains(target) else { return }

        let forwards: Bool
        if target == 0, lastSelection == count - 1 { forwards = true }
        else if target == count - 1, lastSelection == 0 { forwards = false }
        else { forwards = target >= lastSelection }

        for step in 1...count {
            let probe = ((target + (forwards ? step : -step)) % count + count) % count
            guard visible.contains(probe) else { continue }
            model.selection = probe
            // Follow the jump in the strip; keyboard navigation is the only way
            // to get here, and it always scrolls.
            model.scrollRequest = probe
            return
        }
    }

    // MARK: Cards

    private var cards: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    let rows = displayed
                    // Leading sentinel: resets scroll to here (not to card 0), so the
                    // first card keeps its margin instead of jamming against the edge.
                    Color.clear.frame(width: 0.5, height: 1).id("head")
                    if rows.isEmpty {
                        emptyState
                    } else {
                        ForEach(rows) { row in
                            ClipCardView(
                                item: row.item,
                                // The model's index, so the ⌘N badge names the
                                // shortcut that actually pastes THIS card.
                                index: row.index,
                                selected: row.index == model.selection,
                                storeDir: store.storeDirectory,
                                onActivate: { model.onPaste?(row.item, false) },
                                onInspect: { model.inspect(row.item) },
                                onInspectTags: { model.inspect(row.item, focusTags: true) },
                                onPin: { store.togglePin(row.item) },
                                onDelete: { store.delete(row.item) }
                            )
                            // Identity is the clip's id (from ForEach) — NOT the index.
                            // An index-based .id reused stale views across filters
                            // (e.g. URLs showing under Images). Scroll by id below.
                            .onTapGesture { model.click(row.index) }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            // Only keyboard navigation scrolls the strip; mouse clicks don't, so a
            // click registers and highlights instantly with no animated re-center.
            .onChange(of: model.scrollRequest) { target in
                guard model.results.indices.contains(target) else { return }
                let id = model.results[target].id
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            // When a clip is added/bumped, reveal it wherever it lands in the
            // pinned-first order (it may sit below pinned cards, not at index 0).
            .onChange(of: store.lastAddedID) { id in
                guard let id, let idx = model.results.firstIndex(where: { $0.id == id }) else { return }
                model.selection = idx
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
            // Every time the bar is summoned, snap back to the newest clip.
            .onChange(of: model.presentToken) { _ in
                proxy.scrollTo("head", anchor: .leading)
            }
            // Changing the filter (category / pinned / search) produces a shorter
            // list; snap to the start so it isn't hidden past a stale scroll
            // offset — which made categories look empty/wrong.
            .onChange(of: model.activeKind) { _ in proxy.scrollTo("head", anchor: .leading) }
            .onChange(of: model.pinnedOnly) { _ in proxy.scrollTo("head", anchor: .leading) }
            .onChange(of: model.query) { _ in proxy.scrollTo("head", anchor: .leading) }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Alternate layouts (bake-off shortlist)

    /// Compact one-line rows — dense, fast to scan (the "Compact List" layout).
    private var listLayout: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    let rows = displayed
                    if rows.isEmpty {
                        emptyState.frame(maxWidth: .infinity)
                    } else {
                        ForEach(rows) { row in
                            clipRow(row.index, row.item).id(row.item.id)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .scrollTargets(proxy, model: model, store: store)
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// Search-first command palette: results on the left, a live preview of the
    /// selected clip on the right (the "Spotlight Palette" layout).
    private var spotlightLayout: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        let rows = displayed
                        if rows.isEmpty {
                            emptyState.frame(maxWidth: .infinity)
                        } else {
                            ForEach(rows) { row in
                                clipRow(row.index, row.item).id(row.item.id)
                            }
                        }
                    }
                    .padding(10)
                    .scrollTargets(proxy, model: model, store: store)
                }
            }
            .frame(width: 430)
            Divider().opacity(0.5)
            previewPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
    }

    /// A single dense row used by both list and spotlight layouts.
    private func clipRow(_ idx: Int, _ item: ClipItem) -> some View {
        let selected = idx == model.selection
        return HStack(spacing: 10) {
            Image(systemName: item.kind.symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 20)
            Text(rowText(item))
                .font(.system(size: 12.5))
                .lineLimit(1)
            Spacer(minLength: 8)
            // One chip only — the row is a single line. It is the FIRST chip, so
            // the certainty ordering guarantees a protective badge outranks a
            // shape or a source name for the one slot there is.
            ForEach(ClipChips.chips(for: item).prefix(1), id: \.self) { signal in
                signalPill(signal, size: 9.5)
            }
            if item.pinned {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Theme.pin)
            }
            Text(item.sourceApp ?? item.kind.title)
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: 78, alignment: .trailing)
            Text(item.createdAt, style: .relative)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(selected ? Theme.accent.opacity(0.16) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Theme.accent : .clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.click(idx) }
        .contextMenu {
            Button("Paste") { model.onPaste?(item, false) }
            Button("Inspect") { model.inspect(item) }
            Button(item.pinned ? "Unpin" : "Pin") { store.togglePin(item) }
            Button("Delete", role: .destructive) { store.delete(item) }
        }
    }

    /// A single-line textual summary of a clip for the dense rows.
    private func rowText(_ item: ClipItem) -> String {
        switch item.kind {
        case .color: return item.colorHex ?? "Color"
        case .image: return "Image"
        case .file:  return (item.filePath as NSString?)?.lastPathComponent ?? "File"
        default:     return item.preview
        }
    }

    /// The right-hand preview of the selected clip in the spotlight layout.
    @ViewBuilder private var previewPane: some View {
        let results = model.results
        if results.indices.contains(model.selection) {
            let item = results[model.selection]
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: item.kind.symbolName).foregroundStyle(Theme.accent)
                    Text(item.sourceApp ?? item.kind.title)
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text(item.characterCountLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                previewBody(item)
                // The preview pane has room, so it shows the FULL certainty-ordered
                // list rather than the card's three-slot prefix — this is the
                // surface the "+N" chip exists to reach.
                let chips = ClipChips.chips(for: item)
                if !chips.isEmpty {
                    FlowLayout(spacing: 5) {
                        ForEach(chips, id: \.self) { signal in
                            signalPill(signal, size: 10)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Text("Select a clip").foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func previewBody(_ item: ClipItem) -> some View {
        switch item.kind {
        case .image:
            // Payloads are sealed at rest — read the bytes, decrypt via
            // Crypto.open, then decode. Legacy plaintext PNGs pass through
            // Crypto.open untouched, so old histories still render.
            if let f = item.payloadFile,
               let stored = try? Data(contentsOf: store.storeDirectory.appendingPathComponent(f)),
               let png = Crypto.open(stored),
               let img = NSImage(data: png) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else { placeholderText("Image") }
        case .color:
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.color(fromHex: item.colorHex ?? "#000000"))
                    .frame(width: 96, height: 96)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.t.border))
                Text(item.colorHex ?? "")
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                Spacer()
            }
        default:
            ScrollView {
                Text(item.text).font(.system(size: 13)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func placeholderText(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A signal chip for the dense rows and the preview pane.
    ///
    /// Same glyph + label + tier tint as the card, so a chip means one thing
    /// everywhere. Colour is never the only carrier: the glyph and the spoken
    /// label say "sensitive" too.
    ///
    /// This replaces `tagNames(for:)`, which listed the top embedding tag names.
    /// The audit found those were decoration — a forced argmax with a 0.03–0.04
    /// margin — so they are not shown anywhere any more.
    private func signalPill(_ signal: ClipSignal, size: CGFloat) -> some View {
        let colors = ClipChips.colors(for: signal.tier)
        return HStack(spacing: 3) {
            Image(systemName: signal.symbol).font(.system(size: size - 1.5, weight: .semibold))
            Text(signal.title).font(.system(size: size, weight: .medium)).lineLimit(1)
        }
        .fixedSize()
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(colors.fill, in: Capsule())
        .foregroundStyle(colors.text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(signal.spoken)
    }

    private func indexingBar(_ p: ClipStore.IndexingProgress) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars").font(.system(size: 10)).foregroundStyle(Theme.accent)
                Text("Tagging \(p.done) of \(p.total)…").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if let eta = p.etaSeconds, eta > 0.5 {
                    Text("~\(Int(eta.rounded()))s left").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            ProgressView(value: p.fraction).progressViewStyle(.linear).tint(Theme.accent)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(Theme.accent.opacity(0.06))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            // An active filter is why the strip is empty — saying "nothing copied
            // yet" when a signal filter is hiding everything would be a lie the
            // user has no way to correct.
            let filtered = !model.query.isEmpty || !signals.active.isEmpty
            Text(filtered ? "No matches" : "Nothing copied yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Text(filtered ? "Try clearing a filter." : "Copy something and it will appear here.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(width: 420, height: Theme.cardHeight)
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        if model.showSettings {
            HStack(spacing: 16) {
                hint("esc", "Back")
                Spacer()
                Text("Cliphoard · ⌃⌥⌘V").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.04))
        } else {
            HStack(spacing: 14) {
                hint("←→", "Navigate")
                hint("↩", "Paste")
                hint("⌘C", "Copy")
                hint("⌘1–9", "Quick paste")
                hint("⌘P", "Pin")
                hint("⌘⌫", "Delete")
                hint("esc", "Close")
                Spacer()
                // Count what is on screen, not what the model holds — with a
                // signal filter on, those differ.
                let shown = displayed.count
                Text("\(shown) item\(shown == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.04))
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

/// Shared scroll-into-view wiring for the vertical layouts (list / spotlight),
/// mirroring the horizontal strip's behavior: follow keyboard selection, reveal
/// newly added clips, and snap to the top when the filter/query changes.
private extension View {
    @MainActor func scrollTargets(_ proxy: ScrollViewProxy, model: PanelViewModel, store: ClipStore) -> some View {
        // Rows are identified by the clip's id (not the index), so scroll by id.
        func top() { if let f = model.results.first?.id { proxy.scrollTo(f, anchor: .top) } }
        return self
            .onChange(of: model.scrollRequest) { t in
                guard model.results.indices.contains(t) else { return }
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(model.results[t].id, anchor: .center) }
            }
            .onChange(of: store.lastAddedID) { id in
                guard let id, let idx = model.results.firstIndex(where: { $0.id == id }) else { return }
                model.selection = idx
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: model.presentToken) { _ in top() }
            .onChange(of: model.activeKind) { _ in top() }
            .onChange(of: model.pinnedOnly) { _ in top() }
            .onChange(of: model.query) { _ in top() }
    }
}

/// Presents the facet-cube filter menu as a native NSMenu built ON CLICK — one
/// submenu per dimension, checkmarked values toggling on/off. Kept out of the
/// SwiftUI tree so the panel's synchronous per-summon rebuild never pays for the
/// ~110 items; they exist only while the menu is open.
@MainActor
final class FacetMenuController: NSObject {
    private weak var model: PanelViewModel?
    private weak var signals: SignalFilterModel?

    func present(model: PanelViewModel, signals: SignalFilterModel) {
        self.model = model
        self.signals = signals
        let menu = NSMenu()
        let signalCount = signals.count
        if !model.activeFacets.isEmpty || !model.activeUserTags.isEmpty || signalCount > 0 {
            let n = model.activeFacets.count + model.activeUserTags.count + signalCount
            let clear = NSMenuItem(title: "Clear \(n) filter\(n == 1 ? "" : "s")",
                                   action: #selector(clearAll), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
            menu.addItem(.separator())
        }
        addSignalSections(to: menu, model: model, signals: signals)
        for (d, dim) in TagSpace.dimensions.enumerated() {
            let sub = NSMenu()
            let base = TagSpace.range(ofDimension: d).lowerBound
            for (i, tagName) in dim.tags.enumerated() {
                let item = NSMenuItem(title: tagName, action: #selector(toggle(_:)), keyEquivalent: "")
                item.target = self
                item.tag = base + i
                item.state = model.activeFacets.contains(base + i) ? .on : .off
                sub.addItem(item)
            }
            let parent = NSMenuItem(title: dim.name, action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
        }
        let userTags = model.store.distinctUserTags
        if !userTags.isEmpty {
            let sub = NSMenu()
            for tag in userTags {
                let item = NSMenuItem(title: tag, action: #selector(toggleUserTag(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = tag
                item.state = model.activeUserTags.contains(tag) ? .on : .off
                sub.addItem(item)
            }
            let parent = NSMenuItem(title: "Your tags", action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
        }
        // Pop at the cursor (which is on the chip that was just clicked). Screen
        // coordinates; `in: nil` interprets the point that way.
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// The signal sections: sensitivity flags, shape, source app, lifecycle.
    ///
    /// Built from the values **actually present** in the history rather than from
    /// the full vocabulary, for the same reason the category chips only show
    /// non-empty kinds: an entry that can only ever return nothing is a dead end,
    /// and design principle 4 wants every offered value to lead somewhere.
    ///
    /// One O(n) pass over the store, paid only when the menu is opened — the
    /// whole reason this is an NSMenu built on click rather than a SwiftUI Menu
    /// materialised on every summon.
    private func addSignalSections(to menu: NSMenu, model: PanelViewModel, signals: SignalFilterModel) {
        let items = model.store.items
        guard !items.isEmpty else { return }
        let now = Date()

        var flagsPresent: [ClipFlags] = []
        var shapes: Set<String> = []
        var sources: Set<String> = []
        var lifecycles: Set<String> = []
        for item in items {
            for (_, flag) in ClipFlags.allKnown where item.flags.contains(flag) {
                if !flagsPresent.contains(flag) { flagsPresent.append(flag) }
            }
            if let shape = item.shape, !shape.isEmpty { shapes.insert(shape) }
            if let source = DerivedTags.source(item) { sources.insert(source) }
            if let value = DerivedTags.lifecycle(item, now: now) { lifecycles.insert(value) }
            if let value = DerivedTags.linkDisposition(item, now: now) { lifecycles.insert(value) }
        }

        // Flags keep `allKnown` (bit) order rather than discovery order, so the
        // list is stable between openings; everything else sorts alphabetically.
        let flagSignals = ClipFlags.allKnown
            .filter { flagsPresent.contains($0.flag) }
            .map { ClipSignal.flag($0.flag) }

        var added = false
        for (title, group) in [("Sensitive", flagSignals),
                               ("Shape", shapes.sorted().map(ClipSignal.shape)),
                               ("Source app", sources.sorted().map(ClipSignal.source)),
                               ("Lifecycle", lifecycles.sorted().map(ClipSignal.lifecycle))]
        where !group.isEmpty {
            let sub = NSMenu()
            for signal in group {
                let item = NSMenuItem(title: signal.menuTitle,
                                      action: #selector(toggleSignal(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = SignalBox(signal)
                item.state = signals.active.contains(signal) ? .on : .off
                sub.addItem(item)
            }
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
            added = true
        }
        if added { menu.addItem(.separator()) }
    }

    /// Carries a `ClipSignal` through `NSMenuItem.representedObject`, which is an
    /// Objective-C `id`. A class box keeps the round-trip explicit instead of
    /// relying on implicit bridging of a Swift enum.
    private final class SignalBox: NSObject {
        let signal: ClipSignal
        init(_ signal: ClipSignal) { self.signal = signal }
    }

    @objc private func toggleSignal(_ sender: NSMenuItem) {
        guard let signals, let box = sender.representedObject as? SignalBox else { return }
        signals.toggle(box.signal)
        model?.resetSelection()
    }

    @objc private func toggle(_ sender: NSMenuItem) {
        guard let model else { return }
        if model.activeFacets.contains(sender.tag) { model.activeFacets.remove(sender.tag) }
        else { model.activeFacets.insert(sender.tag) }
        model.resetSelection()
    }

    @objc private func clearAll() {
        model?.activeFacets = []
        model?.activeUserTags = []
        signals?.active = []
        model?.resetSelection()
    }

    @objc private func toggleUserTag(_ sender: NSMenuItem) {
        guard let model, let tag = sender.representedObject as? String else { return }
        if model.activeUserTags.contains(tag) { model.activeUserTags.remove(tag) }
        else { model.activeUserTags.insert(tag) }
        model.resetSelection()
    }
}
