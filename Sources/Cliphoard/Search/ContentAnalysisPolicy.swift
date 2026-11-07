import Foundation

/// Local preferences, independent of search features and of the Pro entitlement.
enum ContentAnalysisPreferences {
    static let changed = Notification.Name("CliphoardContentAnalysisChanged")
    static func enabled(_ key: String, default fallback: Bool = true, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }
    static var nsfwEnabled: Bool { enabled("nsfwEnabled") }
    static var focusOnly: Bool { enabled("nsfwFocusOnly", default: false) }
    static var documentText: Bool { enabled("documentTextEnabled", default: false) }
    static var documentTags: Bool { enabled("documentTagsEnabled") }
    static func fileTextAllowed(_ item: ClipItem) -> Bool {
        guard documentText else { return false }
        let ext = ((item.filePath ?? "") as NSString).pathExtension.lowercased()
        if ext == "pdf" { return enabled("documentPDFEnabled") }
        if ext == "rtf" { return enabled("documentRichTextEnabled") }
        return true
    }
    static var nsfwActive: Bool { nsfwEnabled && (!focusOnly || FocusProtectionState.active != false) }
}

/// Unknown Focus state is protective until the current filter has been read.
/// Never persist yesterday's active Focus as today's authoritative state.
enum FocusProtectionState {
    private static let lock = NSLock()
    private static var value: Bool?
    static var active: Bool? { lock.lock(); defer { lock.unlock() }; return value }
    static func set(_ active: Bool?) { lock.lock(); value = active; lock.unlock() }
}

enum NSFWDetection {
    // Heuristics describe a possible match, never a safety guarantee. Keep neutral
    // medical, art and everyday people examples in the contrast set.
    static let positivePrompts = ["sexually explicit pornography", "explicit nude sexual content", "sexual activity and explicit sexual sounds"]
    static let negativePrompts = ["ordinary work document or screenshot", "people in everyday clothing", "landscape animals or objects", "medical anatomy or health education", "music conversation or ordinary environmental sounds"]
    static let minimumScore: Float = 0.20
    static let minimumMargin: Float = 0.06

    static func possibleMatch(vector: [Float], positive: [[Float]], negative: [[Float]]) -> Bool {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite), vector.contains(where: { $0 != 0 }),
              !positive.isEmpty, !negative.isEmpty,
              (positive + negative).allSatisfy({ $0.count == vector.count && $0.allSatisfy(\.isFinite) && $0.contains(where: { $0 != 0 }) }) else { return false }
        let yes = positive.map { SemanticRanker.cosine(vector, $0) }.max() ?? -1
        let no = negative.map { SemanticRanker.cosine(vector, $0) }.max() ?? 1
        return yes >= minimumScore && yes - no >= minimumMargin
    }

    /// Explicit labels and paths are checked even when the underlying media is Pro-only.
    /// Token boundaries avoid substring matches such as "Essex" or "Scunthorpe".
    static func explicitLabel(_ text: String) -> Bool {
        let decoded = text.removingPercentEncoding ?? text
        return decoded.range(of: #"(?i)(?:^|[^\p{L}\p{N}])(?:nsfw|porn|pornography|xxx|sexually[ _-]+explicit)(?:$|[^\p{L}\p{N}])"#,
                             options: .regularExpression) != nil
    }
    static func labelled(_ item: ClipItem) -> Bool {
        if exempt(item) { return false }
        return explicitLabel(item.text) || explicitLabel(item.filePath ?? "")
            || explicitLabel(item.ocrText ?? "") || item.userTags.contains(where: explicitLabel)
    }
    static func exempt(_ item: ClipItem) -> Bool { item.userTags.contains { $0.lowercased() == "nsfw-exempt" } }
    static func permitsMedia(isVideoOrAudio: Bool, isPro: Bool, active: Bool) -> Bool {
        active && (!isVideoOrAudio || isPro)
    }
}
