import AppIntents
import Foundation

/// System Settings associates this filter with named Focus modes. No private Focus
/// database, names, notification scraping or separate permission is needed.
struct NSFWFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "NSFW protection"
    static var description = IntentDescription("Hide possible NSFW clipboard content while this Focus is active.")
    @Parameter(title: "Protect NSFW content", default: false)
    var protectNSFW: Bool
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "NSFW protection", subtitle: protectNSFW ? "Active in this Focus" : "Use Cliphoard options")
    }
    @MainActor func perform() async throws -> some IntentResult {
        FocusProtectionState.set(protectNSFW)
        NotificationCenter.default.post(name: ContentAnalysisPreferences.changed, object: nil)
        return .result()
    }
    static func suggestedFocusFilters(for context: FocusFilterSuggestionContext) async -> [NSFWFocusFilter] {
        var filter = NSFWFocusFilter(); filter.protectNSFW = true; return [filter]
    }
}
