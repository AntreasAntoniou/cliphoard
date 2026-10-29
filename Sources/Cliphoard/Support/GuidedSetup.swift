import Foundation

/// Draft values only. Navigation never writes preferences, loads a model or
/// trims history; the final view commits only fields explicitly changed here.
struct GuidedSetupDraft {
    enum Step: Int, CaseIterable {
        case welcome, tags, model, history, finish
        var title: String {
            switch self {
            case .welcome: return "Welcome to Cliphoard"
            case .tags: return "Choose your tags"
            case .model: return "Choose a search model"
            case .history: return "Choose how much to keep"
            case .finish: return "Review your choices"
            }
        }
    }
    struct Changes {
        let overlays: [String]?
        let level: DeepSearchLevel?
        let historyLimit: Int?
    }
    static let historyChoices: [(Int, String)] = [
        (100, "100"), (200, "200"), (500, "500"), (1000, "1000"), (5000, "5000"), (0, "Unlimited")
    ]
    private let originalOverlays: [String]
    private let originalLevel: DeepSearchLevel
    private let originalHistoryLimit: Int
    var overlays: [String]
    var level: DeepSearchLevel
    var historyLimit: Int { didSet { confirmedRemovalCount = nil } }
    var step: Step = .welcome
    var confirmedRemovalCount: Int?

    init(overlays: [String], level: DeepSearchLevel, historyLimit: Int) {
        originalOverlays = overlays; originalLevel = level; originalHistoryLimit = historyLimit
        self.overlays = overlays; self.level = level; self.historyLimit = historyLimit
    }
    mutating func next() { step = Step(rawValue: min(step.rawValue + 1, Step.finish.rawValue))! }
    mutating func back() { step = Step(rawValue: max(step.rawValue - 1, 0))! }
    var changes: Changes? {
        guard step == .finish else { return nil }
        return Changes(overlays: overlays == originalOverlays ? nil : overlays,
                       level: level == originalLevel ? nil : level,
                       historyLimit: historyLimit == originalHistoryLimit ? nil : historyLimit)
    }
    func removalCount(unpinnedCount: Int) -> Int {
        guard historyLimit != originalHistoryLimit, historyLimit > 0 else { return 0 }
        return max(0, unpinnedCount - historyLimit)
    }
    func canFinish(unpinnedCount: Int, selectedModelAvailable: Bool) -> Bool {
        guard step == .finish, historyLimit >= 0 else { return false }
        guard level == originalLevel || selectedModelAvailable else { return false }
        let removal = removalCount(unpinnedCount: unpinnedCount)
        return removal == 0 || confirmedRemovalCount == removal
    }
    static func presentsPro(for mode: SearchMode, entitlement: Entitlement) -> Bool {
        !SearchMode.available(entitlement).contains(mode)
    }
}
