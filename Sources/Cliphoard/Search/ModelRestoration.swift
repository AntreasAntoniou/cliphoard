import Foundation

/// A successful explicit setup is durable; a decline or cancellation takes precedence.
/// Migration requires saved enable/selection, and restore still verifies actual local assets.
enum ModelRestorationPreferences {
    static func key(_ requirement: SearchModelRequirement) -> String { "modelPreparation-v1-" + requirement.id }
    static func completed(_ requirement: SearchModelRequirement, defaults: UserDefaults = .standard) {
        defaults.set("ready", forKey: key(requirement))
    }
    static func deferPreparation(_ requirement: SearchModelRequirement, defaults: UserDefaults = .standard) {
        defaults.set("deferred", forKey: key(requirement))
    }
    static func authorized(_ requirement: SearchModelRequirement, defaults: UserDefaults = .standard) -> Bool {
        if let decision = defaults.string(forKey: key(requirement)) { return decision == "ready" }
        switch requirement {
        case .pictures:
            // The old default-true getter is deliberately insufficient: NSFW also uses this cache.
            return defaults.object(forKey: "imageUnderstandingEnabled") != nil && defaults.bool(forKey: "imageUnderstandingEnabled")
        case .media:
            return selected(defaults: defaults).contains(.media)
        case .speech(let model):
            return selected(defaults: defaults).contains(.speech(model))
        case .text: return false // Existing text startup policy owns its own consent.
        }
    }
    static func selected(defaults: UserDefaults = .standard) -> [SearchModelRequirement] {
        let coverage = MediaSpeechCoverage(rawValue: defaults.string(forKey: "mediaSpeechCoverage") ?? "") ?? .off
        let speech = MediaSpeechModel(rawValue: defaults.string(forKey: "mediaSpeechModel") ?? "") ?? .turbo
        return SearchModelRequirement.selected(mode: SearchPreferences.modality(defaults),
            capabilities: SearchPreferences.capabilities(defaults), level: DeepSearch.level, pro: true,
            speech: coverage == .off ? nil : speech)
    }
}

/// Admission is independent of a cache-presence hint. Live owners recheck these gates after awaits.
enum ModelRestorationPolicy {
    static func requirements(pro: Bool, safeMode: Bool, storageComplete: Bool,
                             defaults: UserDefaults = .standard) -> [SearchModelRequirement] {
        guard pro, !safeMode, storageComplete else { return [] }
        var result = ModelRestorationPreferences.selected(defaults: defaults).filter {
            ModelRestorationPreferences.authorized($0, defaults: defaults)
        }
        if ModelRestorationPreferences.authorized(.pictures, defaults: defaults),
           defaults.object(forKey: "imageUnderstandingEnabled") != nil,
           defaults.bool(forKey: "imageUnderstandingEnabled"), !result.contains(.pictures) {
            result.append(.pictures)
        }
        return result
    }
}

/// Startup ordering shared by production and bounded async regression fixtures.
@MainActor
enum ModelRestorationSequence {
    static func run(allowed: () -> Bool, pictures: () async -> Void, media: () async -> Void) async {
        guard !Task.isCancelled, allowed() else { return }
        await pictures()
        guard !Task.isCancelled, allowed() else { return }
        await media()
    }
}
