import SwiftUI

/// Pure dependency selection: choosing a search category never authorizes a download.
enum SearchModelRequirement: Hashable, Identifiable {
    case text(DeepSearchLevel), pictures, media, speech(MediaSpeechModel)
    var id: String {
        switch self { case .text(let level): return "text-" + level.rawValue
        case .pictures: return "pictures"; case .media: return "media"
        case .speech(let model): return "speech-" + model.rawValue }
    }
    var title: String {
        switch self { case .text(let level): return level.title
        case .pictures: return "CLIP · OpenVision"; case .media: return "EmbeddingGemma 2 · media"
        case .speech(let model): return model.label }
    }
    static func selected(mode: SearchModality, capabilities: SearchCapabilities,
                         level: DeepSearchLevel, pro: Bool, speech: MediaSpeechModel? = nil) -> [Self] {
        var result: [Self] = []
        if capabilities.requested(.text, mode: mode, pro: pro), level != .off { result.append(.text(level)) }
        if capabilities.requested(.images, mode: mode, pro: pro), capabilities.imageModel == .clip {
            result.append(.pictures)
        }
        if !capabilities.gemmaScopes(mode: mode, pro: pro).isEmpty { result.append(.media) }
        if let speech, capabilities.requested(.audio, mode: mode, pro: pro) || capabilities.requested(.video, mode: mode, pro: pro) {
            result.append(.speech(speech))
        }
        return result
    }
}

/// Index readiness is separate from having downloaded/prepared a model.
struct PictureIndexStatus: Equatable {
    let indexed: Int
    let eligible: Int
    let working: Bool
    var remaining: Int { max(0, eligible - indexed) }
    var message: String {
        if working { return "Indexing pictures in the background · \(indexed) of \(eligible) ready" }
        if eligible == 0 { return "No eligible clipboard pictures to index." }
        if indexed == 0 { return "Picture model ready, but clipboard pictures are not indexed yet." }
        if indexed == 1 { return "1 of \(eligible) pictures indexed. CLIP description search needs at least two indexed pictures; basic text and OCR matching remain available." }
        return "\(indexed) of \(eligible) clipboard pictures searchable by description."
    }
    var canIndex: Bool { !working && remaining > 0 }
    /// Healthy, idle models do not need a permanent status banner in the bar.
    var needsAttention: Bool { working || remaining > 0 || indexed == 1 }
}

/// Lives in the bar, observing the same long-lived jobs as Settings. Closing the
/// panel neither restarts a transfer nor loses its progress. No inference or I/O
/// is performed by a view body; consent buttons invoke the existing async owners.
@MainActor
struct SearchModelPreparationView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: ClipStore
    @ObservedObject var media: MediaSearchController
    @ObservedObject private var text = EmbedderState.shared
    @State private var pending: SearchModelRequirement?

    private var requirements: [SearchModelRequirement] {
        SearchModelRequirement.selected(mode: settings.searchModality,
            capabilities: SearchCapabilities(text: settings.searchTextEnabled, images: settings.searchImagesEnabled,
                audio: settings.searchAudioEnabled, video: settings.searchVideoEnabled, imageModel: settings.imageSearchModel),
            level: settings.deepSearchLevel, pro: store.entitlement.isPro,
            speech: media.speechCoverage == .off ? nil : media.speechModel)
    }
    private func ready(_ requirement: SearchModelRequirement) -> Bool {
        switch requirement {
        case .text: if case .ready = text.state { return true }; return false
        case .pictures: if case .ready = store.imageModelState { return true }; return store.imageSearchModelReady
        case .media: return media.prepared
        case .speech(let model): return media.preparedSpeechModel == model
        }
    }
    private func working(_ requirement: SearchModelRequirement) -> Bool {
        switch requirement {
        case .text(let level): return Self.isWorking(text.state) || (level == .gemma2 && media.busy)
        case .pictures: return store.imageModelPreparing
        case .media: return media.busy || (settings.deepSearchLevel == .gemma2 && Self.isWorking(text.state))
        case .speech: return media.busy
        }
    }
    static func isWorking(_ state: EmbedderState.State) -> Bool {
        switch state { case .loading, .downloading, .installing: return true; default: return false }
    }
    private var missing: [SearchModelRequirement] { requirements.filter { !ready($0) && !working($0) } }
    private var mayPrepare: Bool { !store.safeMode && store.storageComplete }
    private var pictureIndexStatus: PictureIndexStatus {
        let eligible = store.items.filter { $0.kind == .image && !$0.isIndexVetoed && !SensitiveClipPolicy.requiresAuthentication($0) }
        let indexed = eligible.filter { $0.embeddings[CLIPEmbedder.signature]?.vector.count == CLIPEmbedder.dimension }.count
        return PictureIndexStatus(indexed: indexed, eligible: eligible.count,
            working: store.imageProgress != nil)
    }
    private var includesPictures: Bool {
        store.entitlement.isPro && (settings.searchModality == .images || (settings.searchModality == .all && settings.searchImagesEnabled))
    }
    private func cached(_ requirement: SearchModelRequirement) -> Bool {
        switch requirement {
        case .text(let level): return level == .gemma2 ? GemmaMediaAssets.localCandidateExists() : level.modelName.map { ModelAssets.canPrepareLocally($0) } ?? true
        case .pictures: return ModelAssets.canPrepareImageModelsLocally()
        case .media: return media.mediaDownloaded
        case .speech(let model): return MediaSpeechTranscriber.localCandidateExists(model: model)
        }
    }
    private func size(_ requirement: SearchModelRequirement) -> String {
        let bytes: Int64
        switch requirement {
        case .text(let level): bytes = level == .gemma2 ? GemmaMediaAssets.byteCount : ModelAssets.catalog[level.modelName ?? ""]?.bytes ?? 0
        case .pictures: bytes = ModelAssets.catalog["openvision-tiny-p8"]?.bytes ?? 0
        case .media: bytes = GemmaMediaAssets.byteCount
        case .speech(let model): bytes = model.downloadBytes
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    private func promptForSelection() {
        // Selection changes invalidate any previous consent; keystrokes and
        // progress updates do not repeatedly reopen a declined prompt.
        pending = mayPrepare ? missing.first : nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            stateRow(text.state, title: "Text model", cancel: EmbedderProvider.cancelPreparation)
            stateRow(store.imageModelState, title: "Picture model", cancel: store.cancelImageModelPreparation)
            if let title = media.preparationTitle {
                progressRow(title, progress: media.preparationProgress, cancel: media.cancel)
            }
            if includesPictures && settings.imageSearchModel == .clip && store.imageSearchModelReady {
                let index = pictureIndexStatus
                if index.needsAttention {
                HStack {
                    Text(settings.imageSearchModel.title + ": " + index.message)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    if index.working {
                        ProgressView().controlSize(.small)
                    } else if index.canIndex {
                        Button("Index pictures") {
                            guard mayPrepare, includesPictures, settings.imageSearchModel == .clip,
                                  store.imageSearchModelReady else { return }
                            store.scheduleImageUnderstanding()
                        }.disabled(!mayPrepare)
                    }
                }
                }
            }
            if requirements.contains(.media), !media.prepared, !media.busy,
               media.status.hasPrefix("Couldn’t") || media.status.hasPrefix("Preparation stopped") {
                Text(media.status).font(.caption).foregroundStyle(.orange)
            }
            if !missing.isEmpty {
                HStack {
                    Text(mayPrepare ? "Optional search models aren’t ready yet." : "Model preparation is unavailable while history is in recovery mode.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button("Set up search…") { pending = missing.first }.disabled(!mayPrepare)
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 4)
        // Consent has its own natural-height surface. It must not share the
        // 100pt scrolling status region with progress rows and lose its buttons.
        .popover(item: $pending, arrowEdge: .bottom) { target in
            if requirements.contains(target), !ready(target), !working(target) {
                consent(target).frame(width: 420).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: requirements) { _ in promptForSelection() }
        .onChange(of: store.entitlement.isPro) { _ in pending = nil }
    }
    private func consent(_ target: SearchModelRequirement) -> some View {
        // Capture the permission shown on this rendering. A cache disappearing
        // before the click must not turn a local-only action into a download.
        let download = !cached(target)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Prepare \(target.title)?").font(.callout.bold())
            Text(!download
                 ? "Downloaded files are available. Check them and prepare the model locally on this Mac?"
                 : "Download approximately \(size(target)) from Hugging Face, then prepare it on this Mac? Extra disk space is needed during preparation. Your clips stay local.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            Text(target == .pictures ? "This also enables background picture indexing. You can keep searching and copying clips."
                 : "You can keep searching and copying clips. Media files are indexed only when you choose them.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Not now") { pending = nil }
                Spacer()
                Button(!download ? "Prepare on this Mac" : "Download & prepare") {
                    // Recheck current selection, entitlement and busy state at the
                    // actual action, not only when the prompt was first rendered.
                    guard mayPrepare, requirements.contains(target), !ready(target), !working(target) else { pending = nil; return }
                    pending = nil
                    switch target {
                    case .text(let level): EmbedderProvider.configureAndReindex(level: level, store: store, allowDownloads: download, userInitiated: true)
                    case .pictures:
                        settings.imageUnderstanding = true
                        store.prepareImageSearchModel(allowDownload: download)
                    case .media: media.prepare(download: download)
                    case .speech: media.prepareSpeech(allowDownload: download)
                    }
                }.buttonStyle(.borderedProminent).disabled(!mayPrepare)
            }
        }
        .padding(10).background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
    @ViewBuilder private func stateRow(_ state: EmbedderState.State, title: String, cancel: @escaping () -> Void) -> some View {
        switch state {
        case .downloading(let name, let progress): progressRow("Downloading \(name)…", progress: progress, cancel: cancel)
        case .loading(let name), .installing(let name): progressRow("Preparing \(name) on this Mac…", progress: nil, cancel: cancel)
        case .failed(_, let message): Text("\(title): \(message) Use Prepare to try again.").font(.caption).foregroundStyle(.orange)
        default: EmptyView()
        }
    }
    private func progressRow(_ title: String, progress: Double?, cancel: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.caption).lineLimit(1)
            if let progress {
                ProgressView(value: min(1, max(0, progress))).progressViewStyle(.linear).frame(minWidth: 80, maxWidth: 220)
                Text("\(Int(min(1, max(0, progress)) * 100))%").font(.caption.monospacedDigit())
            } else {
                ProgressView().progressViewStyle(.linear).frame(minWidth: 80, maxWidth: 220)
                Text("Preparing…").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", action: cancel)
        }
        .accessibilityElement(children: .contain)
    }
}
