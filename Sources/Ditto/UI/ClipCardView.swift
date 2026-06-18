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
        .background(VisualEffectBackground(material: .contentBackground, blending: .withinWindow))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Color.primary.opacity(hovering ? 0.18 : 0.08),
                              lineWidth: selected ? 2.5 : 1)
        )
        .shadow(color: .black.opacity(selected ? 0.25 : 0.12), radius: selected ? 10 : 5, y: 3)
        .scaleEffect(selected ? 1.0 : 0.97)
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
        .accessibilityHint(item.characterCountLabel)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
                    .foregroundStyle(.orange)
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
               let nsImage = NSImage(contentsOf: storeDir.appendingPathComponent(file)) {
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
        if !tags.isEmpty {
            HStack(spacing: 4) {
                ForEach(tags.prefix(3), id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Theme.accent.opacity(0.15), in: Capsule())
                        .foregroundStyle(Theme.accent)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
    }

    private var footer: some View {
        HStack {
            Text(item.characterCountLabel)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            Text(item.createdAt, style: .relative)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
