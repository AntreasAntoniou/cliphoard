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
    var activeFilterCount = 0
    @ViewBuilder var filters: () -> Filters

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Group {
                    if let brandImage {
                        Image(nsImage: brandImage).resizable().scaledToFit()
                    } else {
                        Image(systemName: "doc.on.clipboard.fill").foregroundStyle(Theme.accent)
                    }
                }.frame(width: 32, height: 36).accessibilityHidden(true)
                searchField
                HStack(spacing: 6) {
                    Text("Match").font(.system(size: 11)).foregroundStyle(.secondary)
                    SearchChoicePicker(label: "Matching", selection: $matching,
                        choices: SearchControlLabels.matchingModes.map {
                            .init(value: $0, title: $0.title, detail: $0.blurb)
                        }).frame(width: 95, height: 34)
                }
                Button(action: openSettings) {
                    Image(systemName: "gearshape").font(.system(size: 17))
                        .frame(width: 36, height: 36).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Settings · ⌘,")
                    .accessibilityLabel("Settings").keyboardShortcut(",", modifiers: .command)
            }
            HStack(alignment: .top, spacing: 12) {
                HStack(spacing: 6) {
                    Text("Search in").font(.system(size: 11)).foregroundStyle(.secondary)
                    SearchChoicePicker(label: "Search in", selection: $scope,
                        choices: [SearchModality.all, .text, .images, .audio, .video].map {
                            .init(value: $0,
                                  title: SearchControlLabels.scope($0) +
                                    (!isPro && $0 != .text && $0 != .all ? " · Pro" : ""),
                                  detail: SearchControlLabels.scopeDetail($0))
                        }).frame(width: 115, height: 34)
                }
                Divider().frame(height: 28).padding(.top, 3)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { filters().font(.system(size: 11)).frame(height: 34) }
                        .fixedSize()
                    Menu { filters() } label: {
                        Label(activeFilterCount > 0 ? "Filters (\(activeFilterCount))" : "Filters",
                              systemImage: "line.3.horizontal.decrease")
                            .font(.system(size: 12)).frame(height: 34)
                    }.menuStyle(.borderlessButton).fixedSize()
                }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                Button(action: openOptions) {
                    Label("Models & search", systemImage: "cpu")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10).frame(height: 34)
                        .background(Color.primary.opacity(0.035), in: Capsule())
                        .contentShape(Capsule())
                }.buttonStyle(.plain)
                    .help((["Choose local models, search timing and included content"] + badges.map(\.label)).joined(separator: "\n"))
                    .accessibilityLabel("Models and search options")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search clips…", text: $query)
                .textFieldStyle(.plain).font(.system(size: 14))
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
            Divider().frame(height: 20)
            Button(action: searchByImage) {
                Image(systemName: ContentView.matchImageSymbol)
                    .font(.system(size: 16)).frame(width: 32, height: 34)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).help("Search by image — choose a picture, or set up image search")
                .accessibilityLabel("Search by image")
        }
        .padding(.horizontal, 12).frame(height: 36)
        .background(Color.primary.opacity(searchFocused.wrappedValue ? 0.025 : 0.015),
                    in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.accent.opacity(searchFocused.wrappedValue ? 0.8 : 0.3), lineWidth: 1))
    }
}

enum SearchControlLabels {
    static let matchingModes: [SearchMode] = [.exact, .tag, .neural, .smart]

    static func scope(_ mode: SearchModality) -> String {
        mode == .all ? "All content" : mode.title
    }

    static func clipKindDetail(_ kind: ClipKind) -> String {
        switch kind {
        case .text: return "Only clips classified as text, such as notes and code."
        case .link: return "Only clips classified as links."
        case .color: return "Only clips classified as color values."
        case .image: return "Only copied pictures and screenshots."
        case .file: return "Only copied files."
        }
    }

    static func timeDetail(_ filter: TimeFilter) -> String {
        switch filter {
        case .any: return "Show clips from any copied date."
        case .today: return "Only clips copied today, using your local calendar."
        case .yesterday: return "Only clips copied on the previous calendar day."
        case .thisWeek: return "Only clips copied in the current calendar week."
        case .thisMonth: return "Only clips copied in the current calendar month."
        case .last7: return "Only clips copied in the seven days leading up to now."
        case .last30: return "Only clips copied in the thirty days leading up to now."
        case .range: return "Only clips copied between the selected dates, including both days."
        }
    }

    static func scopeDetail(_ mode: SearchModality) -> String {
        switch mode {
        case .all: return "Search the content types enabled in Search options. Media search requires Pro."
        case .text: return "Search clip text using the selected matching mode."
        case .images: return "Search pictures by their content. Requires Pro and an image model."
        case .audio: return "Search indexed sounds and speech. Requires Pro and media setup."
        case .video: return "Search indexed video moments. Requires Pro and media setup."
        }
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
    @Binding var textModel: DeepSearchLevel
    @Binding var imageModel: ImageSearchModel
    let isPro: Bool
    var matching: SearchMode = .smart
    let manageModels: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Models & search", systemImage: "cpu").font(.headline)
            Picker("Search timing", selection: $timing) {
                ForEach(SearchTiming.allCases) { Text($0.title).tag($0).help($0.detail) }
            }
            Text(timing.detail).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Included in All content").font(.subheadline.bold())
            Toggle("Text", isOn: $text).help("Include text when searching All content.")
            Toggle("Images · Pro", isOn: $images).disabled(!isPro).help("Include images when searching All content. Requires Pro.")
            Toggle("Audio · Pro", isOn: $audio).disabled(!isPro).help("Include audio when searching All content. Requires Pro.")
            Toggle("Video · Pro", isOn: $video).disabled(!isPro).help("Include video when searching All content. Requires Pro.")
            Text("These switches apply when All content is selected.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Models").font(.subheadline.bold())
            HStack {
                Text("Text & tags").font(.system(size: 12))
                SearchChoicePicker(label: "Text model", selection: $textModel,
                    choices: DeepSearchLevel.allCases.map {
                        .init(value: $0, title: SearchControlLabels.textModel($0), detail: SearchControlLabels.textDetail($0))
                    }).frame(height: 28)
            }.disabled(matching == .exact)
                .accessibilityIdentifier("search-options-text-model")
            if matching == .exact {
                Text("Exact matching does not use a model. Choose Smart, Neural or Tag in the toolbar to change it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Images · Pro").font(.system(size: 12))
                SearchChoicePicker(label: "Image model", selection: $imageModel,
                    choices: ImageSearchModel.allCases.map {
                        .init(value: $0, title: $0.title, detail: SearchControlLabels.imageDetail($0))
                    }).frame(height: 28)
            }.disabled(!isPro)
                .accessibilityIdentifier("search-options-image-model")
            Text("Audio & video · EmbeddingGemma 2 · Pro")
                .font(.caption).foregroundStyle(.secondary)
            Button("Manage models…", action: manageModels)
            Text("Downloads always ask first. Preparation appears below the toolbar.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(16).frame(width: 360)
    }
}
