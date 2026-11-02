import Foundation

enum SearchModality: String, CaseIterable, Identifiable {
    case text, images, audio, video, all
    var id: String { rawValue }
    var title: String { rawValue == "all" ? "All enabled" : rawValue.capitalized }
}
enum ImageSearchModel: String, CaseIterable, Identifiable {
    case clip, gemma2
    var id: String { rawValue }
    var title: String { self == .clip ? "CLIP · OpenVision" : "EmbeddingGemma 2" }
}
struct SearchCapabilities: Equatable {
    var text: Bool, images: Bool, audio: Bool, video: Bool
    var imageModel: ImageSearchModel
    func requested(_ modality: SearchModality, mode: SearchModality, pro: Bool) -> Bool {
        guard modality != .all, mode == .all || mode == modality else { return false }
        if mode == modality { return modality == .text || pro }
        return contains(modality, pro: pro)
    }
    func gemmaScopes(mode: SearchModality, pro: Bool) -> Set<SearchModality> {
        Set([SearchModality.images, .audio, .video].filter {
            requested($0, mode: mode, pro: pro) && ($0 != .images || imageModel == .gemma2)
        })
    }
    func readyLanes(mode: SearchModality, pro: Bool, clipReady: Bool, gemmaReady: Bool) -> Set<SearchModality> {
        Set([SearchModality.text, .images, .audio, .video].filter {
            guard requested($0, mode: mode, pro: pro) else { return false }
            switch $0 {
            case .text: return true // Basic text matching is always available.
            case .images: return imageModel == .clip ? clipReady : gemmaReady
            case .audio, .video: return gemmaReady
            case .all: return false
            }
        })
    }
    func contains(_ modality: SearchModality, pro: Bool) -> Bool {
        switch modality {
        case .text: return text
        case .images: return pro && images
        case .audio: return pro && audio
        case .video: return pro && video
        case .all: return text || (pro && (images || audio || video))
        }
    }
}
enum SearchPreferences {
    /// Changing the search category is a new scope choice. In particular, All
    /// must not inherit the Images chip from the preceding image-only search.
    static func kindFilter(afterSelecting modality: SearchModality, current: ClipKind?) -> ClipKind? {
        switch modality {
        case .all: return nil
        case .images: return current == .image ? current : nil
        case .audio, .video: return current == .file ? current : nil
        case .text: return current == .image ? nil : current
        }
    }
    static func initialModality(legacy: SearchMode) -> SearchModality {
        switch legacy { case .image: return .images; case .media, .smart, .neural: return .all; default: return .text }
    }
    static func modality(_ defaults: UserDefaults = .standard) -> SearchModality {
        SearchModality(rawValue: defaults.string(forKey: "searchModality") ?? "") ?? initialModality(legacy: DeepSearch.mode)
    }
    static func capabilities(_ defaults: UserDefaults = .standard) -> SearchCapabilities {
        let legacyMedia = DeepSearch.mode == .media
        func enabled(_ name: String, fallback: Bool) -> Bool {
            defaults.object(forKey: name) == nil ? fallback : defaults.bool(forKey: name)
        }
        return SearchCapabilities(text: enabled("searchTextEnabled", fallback: true),
            images: enabled("searchImagesEnabled", fallback: true),
            audio: enabled("searchAudioEnabled", fallback: legacyMedia),
            video: enabled("searchVideoEnabled", fallback: legacyMedia),
            imageModel: ImageSearchModel(rawValue: defaults.string(forKey: "imageSearchModel") ?? "") ?? (legacyMedia ? .gemma2 : .clip))
    }
    /// Rank positions, never incomparable cosine magnitudes. Stable UUID ties and
    /// per-lane dedup make result order independent of dictionary iteration order.
    static func fuse(_ lanes: [SearchModality: [UUID]]) -> [UUID] {
        var scores: [UUID: Double] = [:]
        for modality in SearchModality.allCases where modality != .all {
            var seen = Set<UUID>()
            for (rank, id) in (lanes[modality] ?? []).enumerated() where seen.insert(id).inserted {
                scores[id, default: 0] += 1 / Double(60 + rank + 1)
            }
        }
        return scores.keys.sorted { scores[$0] == scores[$1] ? $0.uuidString < $1.uuidString : scores[$0]! > scores[$1]! }
    }
}

/// A still picture cannot borrow an audio/video track, and an audio-only file
/// cannot become a Video result merely because it has a transcript.
enum MediaScopePolicy {
    static func includes(moment: MediaSearchCache.Modality, stillImage: Bool, scope: SearchModality) -> Bool {
        if stillImage { return scope == .images }
        switch scope {
        case .audio: return moment == .audio
        case .video: return moment == .video
        default: return false
        }
    }
    static func includesSpeech(stillImage: Bool, hasVideo: Bool, scope: SearchModality) -> Bool {
        !stillImage && (scope == .audio || (scope == .video && hasVideo))
    }
}
