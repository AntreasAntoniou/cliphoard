import SwiftUI

/// Presentation only. Search routing, saved model choices and acquisition stay
/// with their existing owners. This view never loads a model or reads history.
struct SearchBarView<Filters: View>: View {
    @Binding var query: String
    @Binding var scope: SearchModality
    var searchFocused: FocusState<Bool>.Binding
    let isPro: Bool
    let openOptions: () -> Void
    let openSettings: () -> Void
    var brandImage: NSImage? = nil
    @ViewBuilder var filters: () -> Filters

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Group {
                    if let brandImage {
                        Image(nsImage: brandImage).resizable().frame(width: 30, height: 30)
                    } else {
                        Image(systemName: "doc.on.clipboard.fill")
                            .font(.system(size: 22)).foregroundStyle(Theme.accent)
                    }
                }.accessibilityHidden(true)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search your clips…", text: $query)
                        .textFieldStyle(.plain).font(.system(size: 15))
                        .focused(searchFocused)
                        .accessibilityLabel("Search clipboard")
                        .frame(minWidth: 140, maxWidth: .infinity)
                    if !query.isEmpty {
                        Button { query = ""; searchFocused.wrappedValue = true } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }.buttonStyle(.plain).help("Clear search")
                            .accessibilityLabel("Clear search")
                    }
                    Divider().frame(height: 18)
                    Picker("Search in", selection: $scope) {
                        ForEach([SearchModality.all, .text, .images, .audio, .video]) { mode in
                            Text(SearchControlLabels.scope(mode) +
                                 (!isPro && mode != .text && mode != .all ? " · Pro" : ""))
                                .tag(mode)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 125)
                    .accessibilityLabel("Search in")
                    .help("Choose what to find. Combined uses the content types selected in Search options.")
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Color.primary.opacity(searchFocused.wrappedValue ? 0.09 : 0.05),
                            in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Theme.accent.opacity(searchFocused.wrappedValue ? 0.6 : 0.15), lineWidth: 1))
                Button(action: openOptions) {
                    Label("Search options", systemImage: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .medium))
                }.help("Choose models and which content types Combined searches")
                Button(action: openSettings) {
                    Image(systemName: "gearshape").font(.system(size: 15))
                }.buttonStyle(.plain).help("Settings").accessibilityLabel("Settings")
            }
            filters()
                .font(.system(size: 11))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

enum SearchControlLabels {
    static func scope(_ mode: SearchModality) -> String {
        mode == .all ? "Combined" : mode.title
    }

    static func textModel(_ level: DeepSearchLevel) -> String {
        switch level {
        case .off: return "Basic matching · no download"
        case .low: return "Ogma Micro · compact"
        case .normal: return "Ogma Small · everyday"
        case .high: return "MiniLM"
        case .gemma2: return "EmbeddingGemma 2"
        }
    }

    static func textDetail(_ level: DeepSearchLevel) -> String {
        switch level {
        case .off: return "Find words in your clips without downloading a neural model."
        case .low: return "A small local model for text meaning and automatic tags."
        case .normal: return "Local text search and automatic tags, using Ogma Small."
        case .high: return "An alternative local text model for meaning and automatic tags."
        case .gemma2: return "Text search and automatic tags using the same download as Gemma’s image, audio and video search."
        }
    }

    static func imageDetail(_ model: ImageSearchModel) -> String {
        model == .clip
            ? "Find clipboard pictures by describing them, or by using a similar picture."
            : "Find pictures with the same model used for audio and video. Choose which pictures to index in Media setup."
    }

    static func combinedSummary(_ capabilities: SearchCapabilities, pro: Bool) -> String {
        let names = [SearchModality.text, .images, .audio, .video]
            .filter { capabilities.contains($0, pro: pro) }.map { $0.title }
        return names.isEmpty ? "No content types selected — choose Search options" : names.joined(separator: " · ")
    }
}
