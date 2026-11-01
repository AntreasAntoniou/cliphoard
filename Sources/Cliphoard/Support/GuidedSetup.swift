import Foundation

/// Draft values only. Navigation never writes preferences, loads a model or
/// trims history; the final view commits only fields explicitly changed here.
struct GuidedSetupDraft {
    enum Step: Int, CaseIterable {
        case welcome, tags, model, pictures, media, history, pro, finish
        var title: String {
            switch self {
            case .welcome: return "Welcome to Cliphoard"
            case .tags: return "Choose your tags"
            case .model: return "Text search & automatic tags"
            case .pictures: return "Find pictures your way"
            case .media: return "Find sounds & video moments"
            case .history: return "Choose how much to keep"
            case .pro: return "Discover Cliphoard Pro"
            case .finish: return "Review your choices"
            }
        }
    }
    struct Changes {
        let overlays: [String]?
        let level: DeepSearchLevel?
        let historyLimit: Int?
        let media: MediaChanges
    }
    struct MediaChoices: Equatable {
        var text = true
        var images = true
        var audio = false
        var video = false
        var imageModel: ImageSearchModel = .clip
        var sampling: MediaSamplingPreset = .balanced
        var speech: MediaSpeechCoverage = .off
        var speechModel: MediaSpeechModel = .turbo
    }
    /// Optional fields preserve settings changed elsewhere while the welcome
    /// window is open. Merely visiting a step never writes preferences.
    struct MediaChanges {
        let text: Bool?
        let images: Bool?
        let audio: Bool?
        let video: Bool?
        let imageModel: ImageSearchModel?
        let sampling: MediaSamplingPreset?
        let speech: MediaSpeechCoverage?
        let speechModel: MediaSpeechModel?
        var isEmpty: Bool {
            text == nil && images == nil && audio == nil && video == nil && imageModel == nil
                && sampling == nil && speech == nil && speechModel == nil
        }
    }
    static let historyChoices: [(Int, String)] = [
        (100, "100"), (200, "200"), (500, "500"), (1000, "1000"), (5000, "5000"), (0, "Unlimited")
    ]
    private let originalOverlays: [String]
    private let originalLevel: DeepSearchLevel
    private let originalHistoryLimit: Int
    private let originalMedia: MediaChoices
    var overlays: [String]
    var level: DeepSearchLevel
    var media: MediaChoices
    var historyLimit: Int { didSet { confirmedRemovalCount = nil } }
    var step: Step = .welcome
    var confirmedRemovalCount: Int?

    init(overlays: [String], level: DeepSearchLevel, historyLimit: Int, media: MediaChoices = MediaChoices()) {
        originalOverlays = overlays; originalLevel = level; originalHistoryLimit = historyLimit
        self.overlays = overlays; self.level = level; self.historyLimit = historyLimit
        self.media = media; self.originalMedia = media
    }
    mutating func next() { step = Step(rawValue: min(step.rawValue + 1, Step.finish.rawValue))! }
    mutating func back() { step = Step(rawValue: max(step.rawValue - 1, 0))! }
    var changes: Changes? {
        guard step == .finish else { return nil }
        return Changes(overlays: overlays == originalOverlays ? nil : overlays,
                       level: level == originalLevel ? nil : level,
                       historyLimit: historyLimit == originalHistoryLimit ? nil : historyLimit,
                       media: MediaChanges(text: media.text == originalMedia.text ? nil : media.text,
                           images: media.images == originalMedia.images ? nil : media.images,
                           audio: media.audio == originalMedia.audio ? nil : media.audio,
                           video: media.video == originalMedia.video ? nil : media.video,
                           imageModel: media.imageModel == originalMedia.imageModel ? nil : media.imageModel,
                           sampling: media.sampling == originalMedia.sampling ? nil : media.sampling,
                           speech: media.speech == originalMedia.speech ? nil : media.speech,
                           speechModel: media.speechModel == originalMedia.speechModel ? nil : media.speechModel))
    }
    func removalCount(unpinnedCount: Int) -> Int {
        guard historyLimit != originalHistoryLimit, historyLimit > 0 else { return 0 }
        return max(0, unpinnedCount - historyLimit)
    }
    func canFinish(unpinnedCount: Int, selectedModelAvailable: Bool, allowDeferredModel: Bool = false) -> Bool {
        guard step == .finish, historyLimit >= 0 else { return false }
        guard level == originalLevel || selectedModelAvailable || allowDeferredModel else { return false }
        let removal = removalCount(unpinnedCount: unpinnedCount)
        return removal == 0 || confirmedRemovalCount == removal
    }
    static func presentsPro(for mode: SearchMode, entitlement: Entitlement) -> Bool {
        !SearchMode.available(entitlement).contains(mode)
    }
}
