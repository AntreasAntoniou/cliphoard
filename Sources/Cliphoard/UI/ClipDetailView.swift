import SwiftUI
import AppKit

/// Expanded per-clip supercard. It observes `ClipStore` so sealed tag edits and
/// pin/delete changes immediately redraw the same source item.
struct ClipDetailView: View {
    let item: ClipItem
    @ObservedObject var store: ClipStore
    let focusTags: Bool
    var onPaste: () -> Void
    var onCopy: () -> Void
    var onClose: () -> Void
    /// Navigate the inspector to another clip. Optional so the "similar images" strip
    /// degrades to plain thumbnails rather than dead buttons if a caller does not wire it.
    var onInspectOther: ((ClipItem) -> Void)? = nil

    @State private var newTag = ""

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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    content
                    recognisedText
                    similarImages
                    metadata
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
                if let image = payloadImage {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 320)
                } else { Text("Image unavailable").foregroundStyle(.secondary) }
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

    private var payloadImage: NSImage? {
        guard let file = item.payloadFile,
              let stored = try? Data(contentsOf: store.storeDirectory.appendingPathComponent(file)),
              let opened = Crypto.open(stored) else { return nil }
        return NSImage(data: opened)
    }

    /// If recognised text is searchable, the user must be able to SEE it. A hidden
    /// derived field that silently governs what search finds is the thing this whole
    /// feature had to avoid — and someone who can read it can also tell us it is wrong.
    @ViewBuilder private var recognisedText: some View {
        if item.kind == .image, let ocr = item.ocrText {
            GroupBox("Recognised text") {
                if ocr.isEmpty {
                    // Says which of the two empty cases this is, because "nothing found"
                    // and "we refused to store it" mean very different things to a user
                    // who just screenshotted something sensitive.
                    Text(item.isIndexVetoed || !item.flags.isDisjoint(with: ClipItem.ocrWithholdFlags)
                         ? "Not stored — this image looked like it contained a secret, "
                           + "one-time code, payment detail or address."
                         : "No text found in this image.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(ocr)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder private var similarImages: some View {
        let similar = store.similarImages(to: item, limit: 8)
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

    @ViewBuilder private func thumbnail(for other: ClipItem) -> some View {
        if let file = other.payloadFile,
           let stored = try? Data(contentsOf: store.storeDirectory.appendingPathComponent(file)),
           let opened = Crypto.open(stored), let image = NSImage(data: opened) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6).fill(Theme.t.tagFill)
                .frame(width: 72, height: 72)
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
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
                            .disabled(store.safeMode)
                        if !suggestions.isEmpty {
                            Menu {
                                ForEach(suggestions, id: \.self) { suggestion in
                                    Button(suggestion) { newTag = suggestion; commitTag() }
                                }
                            } label: { Image(systemName: "text.badge.plus") }
                            .menuStyle(.borderlessButton)
                            .disabled(store.safeMode)
                        }
                        // Frozen stores refuse the write, and on an unreadable row the
                        // labels in memory are its ciphertext parsed as tags — so editing
                        // them would seal garbage over the real ones.
                        Button("Add", action: commitTag)
                            .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty
                                      || store.safeMode)
                    }
                }

                suggestedRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
        guard !q.isEmpty else { return Array(store.distinctUserTags.prefix(6)) }
        return store.distinctUserTags.filter { $0.contains(q) && !item.userTags.contains($0) }.prefix(6).map { $0 }
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
        return SemanticRanker.suggestedUserTags(
            for: item, userTagIndex: store.userTagIndex,
            dismissed: dismissed, embedderSignature: EmbedderProvider.active.signature)
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
                            .disabled(store.safeMode)
                            Button { _ = store.dismissSuggestedUserTag(tag, for: item) } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Dismiss suggestion \(tag)")
                            .disabled(store.safeMode)
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
            Button("Paste", action: onPaste).keyboardShortcut(.defaultAction)
            Button("Copy", action: onCopy)
            Button(item.pinned ? "Unpin" : "Pin") { store.togglePin(item) }
            Spacer()
            Button("Delete", role: .destructive) { store.delete(item); onClose() }
                .disabled(store.safeMode)   // refuses while frozen; do not look live
        }
    }
}
