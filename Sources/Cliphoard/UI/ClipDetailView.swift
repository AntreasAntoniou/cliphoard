import SwiftUI
import AppKit

/// Expanded per-clip supercard. It observes `ClipStore` so sealed tag edits and
/// pin/delete changes immediately redraw the same source item.
@MainActor
struct ClipDetailView: View {
    @ObservedObject var sensitiveReveal = SensitiveClipReveal.shared
    let item: ClipItem
    @ObservedObject var store: ClipStore
    let focusTags: Bool
    var onPaste: () -> Void
    var onCopy: () -> Void
    var onClose: () -> Void
    /// Navigate the inspector to another clip. Optional so the "similar images" strip
    /// degrades to plain thumbnails rather than dead buttons if a caller does not wire it.
    var onInspectOther: ((ClipItem) -> Void)? = nil
    var onFileVerb: ((FileVerb) -> Void)? = nil

    /// Whether the store will accept a write right now.
    ///
    /// DERIVED, not a parameter. This view already observes the store, so the store is the
    /// single source of truth and no call site can hand it a wrong answer — the
    /// `historyIsMutable: true` that would ship a live editor on a frozen store is now a
    /// COMPILE ERROR rather than something a test has to catch. Measured before the change:
    /// mutating that one argument left all 435 tests green.
    ///
    /// `ClipCardView` keeps its parameter, and that asymmetry is correct rather than an
    /// inconsistency: it deliberately holds no store (only `storeDir`, so a store change
    /// does not re-render every card), so it cannot derive the fact and a non-defaulted
    /// `let` is the right shape THERE.
    private var historyIsMutable: Bool { !store.safeMode }

    @State private var newTag = ""
    @State private var similarIDs: [UUID] = []
    @State private var similarItemID: UUID?

    private struct SimilarRequest: Equatable {
        let id: UUID
        let revision: Int
        let count: Int
    }

    private func loadSimilarImages() async {
        similarIDs = []
        similarItemID = nil
        guard !sensitiveReveal.isConcealed(item), let feature = item.imageFeature else { return }
        let query = InspectorImageSearch.Feature(id: item.id, revision: feature.revision, vector: feature.vector)
        let candidates = store.items.compactMap { clip -> InspectorImageSearch.Feature? in
            guard !clip.isIndexVetoed, let feature = clip.imageFeature else { return nil }
            return .init(id: clip.id, revision: feature.revision, vector: feature.vector)
        }
        guard let ids = try? await InspectorImageSearch.search(query: query, candidates: candidates, limit: 8),
              !Task.isCancelled, !sensitiveReveal.isConcealed(item) else { return }
        similarIDs = ids
        similarItemID = item.id
    }

    /// Derived, never stored — see `ClipStore.tags(of:)`.
    private var activeTagIDs: [Int] { store.tags(of: item) }

    private var axisTags: [(dimension: String, value: String)] {
        TagSpace.facetLabels(for: activeTagIDs)
    }

    private var topicalTags: [String] {
        activeTagIDs.compactMap { id in
            guard TagSpace.topicalRange.contains(id), TagSpace.names.indices.contains(id) else { return nil }
            return TagSpace.names[id]
        }
    }

    @ViewBuilder var body: some View {
        if sensitiveReveal.isConcealed(item) {
            VStack {
                HStack { Spacer(); Button("Close inspector", action: onClose) }.padding()
                SensitiveClipPlaceholder(item: item)
            }
            .frame(minWidth: 560, idealWidth: 680, minHeight: 520, idealHeight: 650)
            .background(Theme.barBackground())
        } else {
            revealedBody
        }
    }

    private var revealedBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    content
                    recognisedText
                    similarImages
                    metadata
                    GroupBox("NSFW category") {
                        HStack {
                            Button("Mark as NSFW") {
                                _ = store.updateUserTags(item, to: item.userTags.filter { $0 != "nsfw-exempt" } + ["nsfw"])
                                _ = store.setNSFW(true, on: item)
                            }
                            Button("Exclude this item from NSFW detection") {
                                _ = store.updateUserTags(item, to: item.userTags.filter { $0 != "nsfw" } + ["nsfw-exempt"])
                                _ = store.setNSFW(false, on: item)
                            }
                        }.disabled(!historyIsMutable)
                    }
                    tagsSection.id("tags")
                    actions
                }
                .padding(22)
            }
            .onAppear {
                if focusTags { DispatchQueue.main.async { proxy.scrollTo("tags", anchor: .top) } }
            }
        }
        .frame(minWidth: 560, idealWidth: 680, minHeight: 520, idealHeight: 650)
        .background(Theme.barBackground())
        .task(id: SimilarRequest(id: item.id, revision: store.imageUnderstandingRevision, count: store.items.count)) {
            await loadSimilarImages()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: item.kind.symbolName).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.sourceApp ?? item.kind.title).font(.headline)
                Text(item.characterCountLabel).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("Close inspector")
        }
    }

    @ViewBuilder private var content: some View {
        GroupBox("Content") {
            switch item.kind {
            case .image:
                InspectorPayloadImage(item: item, directory: store.storeDirectory, maxPixelSize: 1_280)
                    .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 320)
            case .color:
                HStack(spacing: 16) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Theme.color(fromHex: item.colorHex ?? "#000000"))
                        .frame(width: 120, height: 120)
                    Text(item.colorHex ?? item.text)
                        .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    Spacer()
                }
            default:
                if let rtf = item.rtf,
                   let rich = NSAttributedString(rtf: rtf, documentAttributes: nil) {
                    Text(AttributedString(rich))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(item.kind == .file ? (item.filePath ?? item.text) : item.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// If recognised text is searchable, the user must be able to SEE it. A hidden
    /// derived field that silently governs what search finds is the thing this whole
    /// feature had to avoid — and someone who can read it can also tell us it is wrong.
    @ViewBuilder private var recognisedText: some View {
        if item.kind == .image || item.kind == .file, let ocr = item.ocrText {
            GroupBox(item.kind == .file ? "Extracted file text" : "Recognised text") {
                if ocr.isEmpty {
                    // Says which of the two empty cases this is, because "nothing found"
                    // and "we refused to store it" mean very different things to a user
                    // who just screenshotted something sensitive.
                    Text(item.isIndexVetoed || !item.flags.isDisjoint(with: ClipItem.ocrWithholdFlags)
                         ? "Not stored — this content looked like it contained a secret, "
                           + "one-time code, payment detail or address."
                         : "No readable text found.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    if item.kind == .file {
                        Text("Extracted snapshot · up to 100 PDF pages / 200,000 characters. Refresh file text in Options after editing the file.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(ocr)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder private var similarImages: some View {
        // Recheck live membership and protection before exposing a worker result.
        let wanted = similarItemID == item.id ? similarIDs : []
        let byID: [UUID: ClipItem] = wanted.isEmpty ? [:] : Dictionary(uniqueKeysWithValues: store.items.filter { wanted.contains($0.id) }.map { ($0.id, $0) })
        let similar = wanted.compactMap { byID[$0] }.filter { !$0.isIndexVetoed && !sensitiveReveal.isConcealed($0) }
        if !similar.isEmpty {
            GroupBox("Similar images") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(similar, id: \.id) { other in
                            if let onInspectOther {
                                Button { onInspectOther(other) } label: { thumbnail(for: other) }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(
                                        "Similar image from \(other.sourceApp ?? "an unknown app"), "
                                        + "copied \(other.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            } else {
                                thumbnail(for: other)
                                    .accessibilityLabel(
                                        "Similar image from \(other.sourceApp ?? "an unknown app")")
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func thumbnail(for other: ClipItem) -> some View {
        InspectorPayloadImage(item: other, directory: store.storeDirectory, maxPixelSize: 144, contentMode: .fill)
            .frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var metadata: some View {
        GroupBox("Metadata") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                metadataRow("Kind", item.kind.title)
                metadataRow("Source", item.sourceApp ?? "Unknown")
                metadataRow("Created", item.createdAt.formatted(date: .abbreviated, time: .shortened))
                metadataRow("Last used", item.lastUsedAt.formatted(date: .abbreviated, time: .shortened))
                metadataRow("Uses", "\(item.useCount)")
                metadataRow("Pinned", item.pinned ? "Yes" : "No")
                if item.kind == .file {
                    metadataRow("Path", item.filePath ?? "—")
                    if let reason = FileClipAction.unavailableReason(path: item.filePath) {
                        metadataRow("Status", "Missing — \(reason). Copy Path still works.")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private var tagsSection: some View {
        GroupBox("Tags") {
            VStack(alignment: .leading, spacing: 13) {
                tagLayer("Axes", axisTags.map { "\($0.dimension): \($0.value)" })
                tagLayer("Topical", topicalTags)

                VStack(alignment: .leading, spacing: 7) {
                    Text("YOURS").font(.caption2.bold()).foregroundStyle(.secondary)
                    if item.userTags.isEmpty {
                        Text("No custom tags yet").font(.caption).foregroundStyle(.secondary)
                    } else {
                        FlowLayout(spacing: 6) {
                            ForEach(item.userTags, id: \.self) { tag in
                                HStack(spacing: 4) {
                                    Text("#\(tag)")
                                    Button {
                                        _ = store.updateUserTags(item, to: item.userTags.filter { $0 != tag })
                                    } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.plain).accessibilityLabel("Remove \(tag)")
                                    .disabled(!historyIsMutable)
                                }
                                .font(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Theme.accent.opacity(0.13), in: Capsule())
                            }
                        }
                    }

                    HStack {
                        TextField("Add a tag", text: $newTag)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(commitTag)
                            .disabled(!historyIsMutable)
                        if !suggestions.isEmpty {
                            Menu {
                                ForEach(suggestions, id: \.self) { suggestion in
                                    Button(suggestion) { newTag = suggestion; commitTag() }
                                }
                            } label: { Image(systemName: "text.badge.plus") }
                            .menuStyle(.borderlessButton)
                            .disabled(!historyIsMutable)
                        }
                        // Frozen stores refuse the write, and on an unreadable row the
                        // labels in memory are its ciphertext parsed as tags — so editing
                        // them would seal garbage over the real ones.
                        Button("Add", action: commitTag)
                            .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty
                                      || !historyIsMutable)
                    }
                }

                suggestedRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // THIS is the mechanism: one gate on the section, inherited by every descendant.
        // `.disabled` inheritance is not assumed — `testDisabledPropagatesThroughAGroupBoxToItsDescendants`
        // renders a real hosting view and reads `@Environment(\.isEnabled)` in a descendant,
        // in BOTH directions, on every test run.
        //
        // The per-control gates are OPPORTUNISTIC REDUNDANCY against a framework behaviour
        // we have measured but do not own — explicitly NOT a list that must be complete.
        // The previous comment called them "belt and braces", which was false: the per-tag
        // Remove had no gate of its own and rested on inheritance regardless, so it was a
        // hand-maintained list that was short by one. Read as a list, being short by one is
        // a defect and this had been short three rounds running; read as redundancy, it is
        // not. It now covers that control too, and if inheritance ever regresses this loses
        // ONE control rather than seven at once.
        //
        // No test pins the individual gates, deliberately: they are redundant with a
        // verified mechanism, so nothing behavioural can kill them and a source-text grep
        // asserting their presence would be the exact artefact this file keeps removing.
        .disabled(!historyIsMutable)
    }

    @ViewBuilder private func tagLayer(_ title: String, _ values: [String]) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title.uppercased()).font(.caption2.bold()).foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(values, id: \.self) { value in
                        Text(value).font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Theme.t.tagFill, in: Capsule())
                    }
                }
            }
        }
    }

    private var suggestions: [String] {
        let q = newTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return Array(SensitiveClipPolicy.visibleUserTags(in: store.items).prefix(6)) }
        return SensitiveClipPolicy.visibleUserTags(in: store.items).filter { $0.contains(q) && !item.userTags.contains($0) }.prefix(6).map { $0 }
    }

    /// Opt-in light-learning (spec §5.1): tags whose member-centroid is near this
    /// clip, surfaced to accept or dismiss. Distinct from the text autocomplete
    /// above — these come from what you've actually tagged, not what you're typing.
    private var suggestionsEnabled: Bool {
        UserDefaults.standard.object(forKey: "userTagSuggestionsEnabled") == nil
            ? true : UserDefaults.standard.bool(forKey: "userTagSuggestionsEnabled")
    }

    private var learningSuggestions: [String] {
        let dismissed = Set(store.dismissedUserTags(for: item).map {
            SemanticRanker.dismissalKey(tag: $0, clipID: item.id)
        })
        let allowed = Set(SensitiveClipPolicy.visibleUserTags(in: store.items))
        return SemanticRanker.suggestedUserTags(
            for: item, userTagIndex: store.userTagIndex,
            dismissed: dismissed, embedderSignature: EmbedderProvider.active.signature)
            .filter { allowed.contains($0) }
    }

    @ViewBuilder private var suggestedRow: some View {
        let learned = suggestionsEnabled ? learningSuggestions : []
        if !learned.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text("SUGGESTED").font(.caption2.bold()).foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(learned, id: \.self) { tag in
                        HStack(spacing: 5) {
                            Button { _ = store.updateUserTags(item, to: item.userTags + [tag]) } label: {
                                Text("+ #\(tag)")
                            }
                            .buttonStyle(.plain).accessibilityLabel("Add suggested tag \(tag)")
                            .disabled(!historyIsMutable)
                            Button { _ = store.dismissSuggestedUserTag(tag, for: item) } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Dismiss suggestion \(tag)")
                            .disabled(!historyIsMutable)
                        }
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Theme.accent.opacity(0.08), in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.3)))
                    }
                }
            }
        }
    }

    private func commitTag() {
        guard let tag = ClipItem.normalizedUserTags([newTag]).first else { return }
        if store.updateUserTags(item, to: item.userTags + [tag]) { newTag = "" }
    }

    private var actions: some View {
        HStack {
            Button(DistributionChannel.primaryActionTitle, action: onPaste).keyboardShortcut(.defaultAction)
            Button("Copy", action: onCopy)
            if item.kind == .file, let onFileVerb {
                let reason = FileClipAction.unavailableReason(path: item.filePath)
                ForEach(FileVerb.allCases, id: \.self) { verb in
                    Button(FileClipAction.title(verb, reason: reason)) { onFileVerb(verb) }
                        .disabled(verb.needsFile && reason != nil)
                }
            }
            Button(item.pinned ? "Unpin" : "Pin") { store.togglePin(item) }
            Spacer()
            Button("Delete", role: .destructive) { store.delete(item); onClose() }
                .disabled(!historyIsMutable)   // refuses while frozen; do not look live
        }
    }
}
