import SwiftUI

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

    init(model: PanelViewModel, store: ClipStore, pasteStatus: PasteStatus) {
        self.model = model
        self.store = store
        self.pasteStatus = pasteStatus
        _settings = StateObject(wrappedValue: AppSettings(store: store))
    }

    var body: some View {
        VStack(spacing: 0) {
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
        // Brief success confirmation: a real paste bumps this token, so the flash
        // makes a successful paste distinguishable from a silent no-op.
        .onChange(of: pasteStatus.pasteConfirmToken) { _ in
            withAnimation(.easeOut(duration: 0.15)) { showPasteConfirm = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                withAnimation(.easeIn(duration: 0.25)) { showPasteConfirm = false }
            }
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

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "command").foregroundStyle(Theme.accent)
                Text(model.showSettings ? "Settings" : "Yank")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
            }

            if !model.showSettings { categoryChips }

            Spacer()

            if !model.showSettings {
                HStack(spacing: 8) {
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

    // MARK: Cards

    private var cards: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    let results = model.results
                    // Leading sentinel: resets scroll to here (not to card 0), so the
                    // first card keeps its margin instead of jamming against the edge.
                    Color.clear.frame(width: 0.5, height: 1).id("head")
                    if results.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(results.enumerated()), id: \.element.id) { idx, item in
                            ClipCardView(
                                item: item,
                                index: idx,
                                selected: idx == model.selection,
                                storeDir: store.storeDirectory,
                                tags: tagNames(for: item),
                                onActivate: { model.onPaste?(item, false) },
                                onPin: { store.togglePin(item) },
                                onDelete: { store.delete(item) }
                            )
                            // Identity is the clip's id (from ForEach) — NOT the index.
                            // An index-based .id reused stale views across filters
                            // (e.g. URLs showing under Images). Scroll by id below.
                            .onTapGesture { model.click(idx) }
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
                    let results = model.results
                    if results.isEmpty {
                        emptyState.frame(maxWidth: .infinity)
                    } else {
                        ForEach(Array(results.enumerated()), id: \.element.id) { idx, item in
                            clipRow(idx, item).id(item.id)
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
                        let results = model.results
                        if results.isEmpty {
                            emptyState.frame(maxWidth: .infinity)
                        } else {
                            ForEach(Array(results.enumerated()), id: \.element.id) { idx, item in
                                clipRow(idx, item).id(item.id)
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
            ForEach(tagNames(for: item).prefix(1), id: \.self) { tag in
                Text(tag)
                    .font(.system(size: 9.5, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.t.tagFill, in: Capsule())
                    .foregroundStyle(Theme.t.tagText)
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
                let tags = tagNames(for: item)
                if !tags.isEmpty {
                    FlowLayout(spacing: 5) {
                        ForEach(tags, id: \.self) { tag in
                            Text(tag).font(.system(size: 10))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Theme.t.tagFill, in: Capsule())
                                .foregroundStyle(Theme.t.tagText)
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

    /// The active model's top tag names for a clip (falls back to any cached
    /// model's tags), so the card can show how the system classified it.
    @MainActor private func tagNames(for item: ClipItem) -> [String] {
        // Only the ACTIVE model's tags — no fallback to a stale model's tags, so a
        // freshly captured clip and an old one are always consistent. Suppress tags
        // entirely on the HashingEmbedder fallback: without a real semantic model
        // its classifications are unreliable and were showing misleading pills.
        guard DeepSearch.level != .off,
              EmbedderProvider.active.signature.hasPrefix("ogma"),
              let ids = item.embeddings[EmbedderProvider.active.signature]?.tags else { return [] }
        // Return all assigned tags; the card shows a couple whole tags + "+N".
        return ids.compactMap { TagSpace.names.indices.contains($0) ? TagSpace.names[$0] : nil }
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
            Text(model.query.isEmpty ? "Nothing copied yet" : "No matches")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Copy something and it will appear here.")
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
                Text("Yank · ⌃⌥⌘V").font(.system(size: 11)).foregroundStyle(.tertiary)
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
                Text("\(model.results.count) item\(model.results.count == 1 ? "" : "s")")
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
