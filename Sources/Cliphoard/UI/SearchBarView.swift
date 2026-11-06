import SwiftUI

/// Presentation only. Search routing, saved model choices and acquisition stay
/// with their existing owners. This view never loads a model or reads history.
struct SearchBarView<Filters: View>: View {
    @Binding var query: String
    @Binding var scope: SearchModality
    @Binding var matching: SearchMode
    var searchFocused: FocusState<Bool>.Binding
    let isPro: Bool
    let openOptions: () -> Void
    let openSettings: () -> Void
    var searchByImage: () -> Void = {}
    var isPending = false
    var timing: SearchTiming = .pause
    var submitSearch: () -> Void = {}
    var badges: [SearchScopeBadge] = []
    var brandImage: NSImage? = nil
    @ViewBuilder var filters: () -> Filters

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let brandImage {
                    Image(nsImage: brandImage).resizable().frame(width: 30, height: 30)
                } else {
                    Image(systemName: "doc.on.clipboard.fill")
                        .font(.system(size: 22)).foregroundStyle(Theme.accent)
                }
            }.frame(width: 30, height: 34).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                FlowLayout(spacing: 8) {
                    searchField
                    Picker("Matching", selection: $matching) {
                        ForEach(SearchControlLabels.matchingModes) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 85, height: 34)
                    .accessibilityLabel("Matching").help(matching.blurb)
                    Picker("Search in", selection: $scope) {
                        ForEach([SearchModality.all, .text, .images, .audio, .video]) { mode in
                            Text(SearchControlLabels.scope(mode) +
                                 (!isPro && mode != .text && mode != .all ? " · Pro" : ""))
                                .tag(mode)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 105, height: 34)
                    .accessibilityLabel("Search in")
                    .help("Choose text, images, audio, video or all enabled types.")
                    Button(action: searchByImage) {
                        Image(systemName: ContentView.matchImageSymbol)
                            .font(.system(size: 15)).frame(width: 26, height: 34)
                    }.buttonStyle(.plain)
                        .help("Search by image — choose a picture, or set up image search")
                        .accessibilityLabel("Search by image")
                    Button(action: openOptions) {
                        Image(systemName: "slider.horizontal.3").frame(width: 26, height: 34)
                    }.buttonStyle(.plain).help("Search options: timing and content types")
                        .accessibilityLabel("Search options")
                    Button(action: openSettings) {
                        Image(systemName: "gearshape").frame(width: 26, height: 34)
                    }.buttonStyle(.plain).help("Settings").accessibilityLabel("Settings")
                    filters().font(.system(size: 11)).frame(height: 34)
                }
                if !badges.isEmpty {
                    FlowLayout(spacing: 6) { badgeViews }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search clips…", text: $query)
                .textFieldStyle(.plain).font(.system(size: 13))
                .focused(searchFocused).accessibilityLabel("Search clipboard")
                .frame(minWidth: 60, maxWidth: .infinity)
            if isPending {
                Button(action: submitSearch) {
                    Image(systemName: "return").font(.system(size: 12, weight: .semibold))
                }.buttonStyle(.borderedProminent)
                    .accessibilityLabel("Search now").help("Search now, or press Return")
            }
            if !query.isEmpty {
                Button { query = ""; searchFocused.wrappedValue = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10).frame(width: 220, height: 34)
        .background(Color.primary.opacity(searchFocused.wrappedValue ? 0.09 : 0.05),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Theme.accent.opacity(searchFocused.wrappedValue ? 0.6 : 0.15), lineWidth: 1))
    }

    private var badgeViews: some View {
        ForEach(badges) { badge in
            Label(badge.label, systemImage: badge.symbol)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .foregroundStyle(Theme.accent)
                .background(Theme.accent.opacity(0.09), in: Capsule())
                .fixedSize()
                .help("Configured search: " + badge.label + ". Model readiness is shown separately.")
        }
    }

}

enum SearchControlLabels {
    static let matchingModes: [SearchMode] = [.exact, .tag, .neural, .smart]

    static func scope(_ mode: SearchModality) -> String {
        mode == .all ? "All types" : mode.title
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

struct SearchScopeBadge: Identifiable, Equatable {
    let mode: SearchModality
    let model: String
    var id: String { mode.rawValue }
    var label: String { mode.title + " · " + model }
    var symbol: String {
        switch mode { case .text: return "text.alignleft"; case .images: return "photo"
        case .audio: return "waveform"; case .video: return "film"; case .all: return "square.grid.2x2" }
    }
    static func selected(mode: SearchModality, capabilities: SearchCapabilities,
                         level: DeepSearchLevel, pro: Bool, matching: SearchMode = .smart) -> [Self] {
        let textModel: String
        switch level { case .off: textModel = "Basic"; case .low: textModel = "Ogma Micro"
        case .normal: textModel = "Ogma Small"; case .high: textModel = "MiniLM"; case .gemma2: textModel = "Gemma 2" }
        return [SearchModality.text, .images, .audio, .video].filter {
            capabilities.requested($0, mode: mode, pro: pro)
        }.map { lane in
            Self(mode: lane, model: lane == .text ? (matching == .exact ? "Exact" : textModel) : (lane == .images && capabilities.imageModel == .clip ? "CLIP" : "Gemma 2"))
        }
    }
}

/// Local controls only; acquisition remains behind the existing model consent UI.
struct SearchOptionsView: View {
    @Binding var timing: SearchTiming
    @Binding var text: Bool
    @Binding var images: Bool
    @Binding var audio: Bool
    @Binding var video: Bool
    let isPro: Bool
    let manageModels: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Search options", systemImage: "slider.horizontal.3").font(.headline)
            Picker("Search timing", selection: $timing) {
                ForEach(SearchTiming.allCases) { Text($0.title).tag($0) }
            }
            Text(timing.detail).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Included in All types").font(.subheadline.bold())
            Toggle("Text", isOn: $text)
            Toggle("Images · Pro", isOn: $images).disabled(!isPro)
            Toggle("Audio · Pro", isOn: $audio).disabled(!isPro)
            Toggle("Video · Pro", isOn: $video).disabled(!isPro)
            Text("These switches apply when All types is selected.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Button("Manage models…", action: manageModels)
            Text("Choose models in Settings. Downloads always ask first.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(16).frame(width: 300)
    }
}
