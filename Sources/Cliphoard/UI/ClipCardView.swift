import SwiftUI

/// A single clipboard entry rendered as a Paste-style card.
struct ClipCardView: View {
    let item: ClipItem
    let index: Int
    let selected: Bool
    let storeDir: URL
    /// A few of this clip's auto-assigned tags, so users see how it's classified.
    var tags: [String] = []
    var onActivate: () -> Void
    var onPin: () -> Void
    var onDelete: () -> Void

    @State private var hovering = false

    /// Decoded thumbnails keyed by file name, so the body doesn't re-decode the
    /// image on every hover/selection re-evaluation (audit BL-09/H8).
    private static let imageCache = NSCache<NSString, NSImage>()

    /// Loads the downsampled `<uuid>-thumb.png` if it exists, else the full-res
    /// original, decoding at most once per file name thanks to `imageCache`.
    private func cachedImage(for file: String) -> NSImage? {
        let thumbName = (file as NSString).deletingPathExtension + "-thumb.png"
        let thumbURL = storeDir.appendingPathComponent(thumbName)
        let useThumb = FileManager.default.fileExists(atPath: thumbURL.path)
        let name = useThumb ? thumbName : file
        if let cached = Self.imageCache.object(forKey: name as NSString) { return cached }
        let url = useThumb ? thumbURL : storeDir.appendingPathComponent(file)
        // Payloads (and their thumbnails) are sealed at rest — read the bytes,
        // decrypt via Crypto.open, then decode. Legacy plaintext PNGs pass
        // through Crypto.open untouched, so old histories still render.
        guard let stored = try? Data(contentsOf: url),
              let decoded = Crypto.open(stored),
              let image = NSImage(data: decoded) else { return nil }
        Self.imageCache.setObject(image, forKey: name as NSString)
        return image
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            tagRow
            footer
        }
        .frame(width: Theme.cardWidth, height: Theme.cardHeight)
        .background(Theme.cardBackground())
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(selected ? Theme.accent : (hovering ? Theme.t.borderHover : Theme.t.border),
                              lineWidth: selected ? Theme.t.selectedBorderWidth : 1)
        )
        .shadow(color: .black.opacity(selected ? 0.25 : 0.12), radius: selected ? 10 : 5, y: 3)
        // No scaleEffect: shrinking unselected cards shifted their header baselines
        // out of row alignment. Selection reads via the ring + shadow instead.
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: selected)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Paste") { onActivate() }
            Button(item.pinned ? "Unpin" : "Pin") { onPin() }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
        .help(item.preview)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityValue(item.characterCountLabel)
        .accessibilityHint("Press Return to paste, Command-C to copy")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// A spoken label combining the clip kind, its source app, and a short preview.
    private var accessibilityLabelText: String {
        let source = item.sourceApp ?? item.kind.title
        let preview = String(item.preview.prefix(80))
        return "\(item.kind.title), \(source), \(preview)"
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: item.kind.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(item.sourceApp ?? item.kind.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer()
            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.pin)
            }
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .image:
            if let file = item.payloadFile,
               let nsImage = cachedImage(for: file) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                placeholder(symbol: "photo")
            }
        case .color:
            ZStack {
                Theme.color(fromHex: item.colorHex ?? "#000000")
                Text(item.colorHex ?? "")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .padding(4)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 5))
            }
        case .file:
            VStack(spacing: 8) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text((item.filePath as NSString?)?.lastPathComponent ?? "File")
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .link:
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "link")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.accent)
                Text(item.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.blue)
                    .lineLimit(6)
            }
            .padding(10)
        case .text:
            Text(item.text)
                .font(.system(size: 12))
                .lineLimit(11)
                .multilineTextAlignment(.leading)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func placeholder(symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 30))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var tagRow: some View {
        // Tags are only meaningful for textual kinds — an image/color caption
        // produces noise, so suppress the row there. Show whole tags (no mid-word
        // truncation) and collapse the rest to a "+N" chip. Neutral styling keeps
        // the saturated accent reserved for the selection ring / focused field.
        if !tags.isEmpty, item.kind != .image, item.kind != .color {
            HStack(spacing: 4) {
                ForEach(tags.prefix(2), id: \.self) { tag in tagChip(tag) }
                if tags.count > 2 { tagChip("+\(tags.count - 2)") }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
    }

    private func tagChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.t.tagFill, in: Capsule())
            .foregroundStyle(Theme.t.tagText)
    }

    private var footer: some View {
        HStack {
            Text(item.characterCountLabel)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)   // was .tertiary — failed AA on the card material
            Spacer()
            Text(item.createdAt, style: .relative)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
