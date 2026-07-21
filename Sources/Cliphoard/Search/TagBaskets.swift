import Foundation

/// One axis of the facet cube. A dimension is an orthogonal question about a
/// clip ("what kind of content is this?", "how sensitive is it?"), answered by
/// exactly one of its `tags`. A dimensional basket classifies every clip along
/// ALL of its dimensions — one value per dimension — rather than picking a few
/// tags from a flat pool. See `TagBasket.dimensions`.
struct TagDimension: Codable, Equatable {
    var name: String
    var tags: [String]
}

/// A named classification taxonomy ("basket"). Two shapes:
///
/// - **Dimensional** (`dimensions` non-empty): a facet cube. The flat `tags`
///   view is the dimensions concatenated in order, so tag-id `i` belongs to
///   dimension `i / dimensionSize`. Every clip gets one value per dimension
///   (argmax within that dimension's slice) — see `TagSpace.classifyDimensions`.
/// - **Flat** (`dimensions` empty): the legacy pool, where a clip takes its
///   nearest few tags globally (`TagSpace.classify`). Used by the user-editable
///   Custom basket, whose tags are an arbitrary list.
///
/// Switching basket re-tags clips from their cached vectors — no re-embedding —
/// so it's cheap.
struct TagBasket: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    /// The cube's axes, in order. Empty for a flat basket.
    var dimensions: [TagDimension]
    /// Backing store for a flat basket's tag pool. Ignored when `dimensions` is
    /// non-empty (the flat view is then derived from the dimensions).
    private var flatTags: [String]

    /// Flat tag list: tag-id = index. For a cube this is the dimensions
    /// concatenated (dimension d owns ids `d*size ..< d*size+size`); for a flat
    /// basket it's the raw pool.
    var tags: [String] { dimensions.isEmpty ? flatTags : dimensions.flatMap { $0.tags } }

    /// True when this basket is a facet cube (classify along every dimension).
    var isDimensional: Bool { !dimensions.isEmpty }

    /// Dimensional basket (a facet cube). Every dimension should hold the same
    /// number of tags so tag-ids map cleanly onto fixed-width slices.
    init(id: String, name: String, dimensions: [TagDimension]) {
        self.id = id; self.name = name
        self.dimensions = dimensions
        self.flatTags = []
    }

    /// Flat basket (legacy pool). Kept for the Custom basket, which the user
    /// edits as a free-form list.
    init(id: String, name: String, tags: [String]) {
        self.id = id; self.name = name
        self.dimensions = []
        self.flatTags = tags
    }

    /// Stable fingerprint of the tag set, for caching tag vectors.
    var fingerprint: String { "\(id):\(tags.count):\(HashingEmbedder.fnv1a(tags.joined(separator: "|")))" }

    // MARK: Codable (resilient: old baskets persisted before `dimensions` existed
    // still decode as flat).
    private enum CodingKeys: String, CodingKey { case id, name, dimensions, flatTags, tags }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        dimensions = try c.decodeIfPresent([TagDimension].self, forKey: .dimensions) ?? []
        // Accept either `flatTags` (new) or `tags` (older single-key form).
        let flat = try c.decodeIfPresent([String].self, forKey: .flatTags)
        let legacy = try c.decodeIfPresent([String].self, forKey: .tags)
        flatTags = flat ?? legacy ?? []
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(dimensions, forKey: .dimensions)
        try c.encode(flatTags, forKey: .flatTags)
    }
}

@MainActor
enum TagBaskets {
    /// The default taxonomy: a 10×10 facet cube. Each clip is classified along
    /// all ten dimensions (one value per dimension). The axes and their words are
    /// derived from the Pieces tagging work (temporary intent, temporary span,
    /// tags; the work/personal/sensitive content classification; persona/domain).
    static let general = TagBasket(id: "general", name: "General", dimensions: [
        TagDimension(name: "Content type", tags: [
            "text", "code", "link", "command", "image",
            "file", "color", "number", "document", "media"]),
        TagDimension(name: "Domain", tags: [
            "software", "web", "business", "finance", "personal",
            "academic", "design", "communication", "data", "admin"]),
        TagDimension(name: "Intent", tags: [
            "reuse", "reference", "share", "task", "read-later",
            "edit", "login", "cite", "debug", "archive"]),
        TagDimension(name: "Sensitivity", tags: [
            "public", "internal", "personal-info", "confidential", "credential",
            "financial", "pii", "health", "legal", "ephemeral"]),
        TagDimension(name: "Temporal span", tags: [
            "momentary", "today", "this-week", "this-month", "this-year",
            "evergreen", "recurring", "scheduled", "expired", "undated"]),
        TagDimension(name: "Source", tags: [
            "editor", "browser", "terminal", "chat", "email",
            "docs", "design-tool", "notes", "spreadsheet", "other-source"]),
        TagDimension(name: "Structure", tags: [
            "token", "phrase", "sentence", "paragraph", "list",
            "table", "key-value", "block", "path", "blob"]),
        TagDimension(name: "Language", tags: [
            "english", "non-english", "python", "javascript", "shell",
            "sql", "markup", "config", "math", "no-language"]),
        TagDimension(name: "Action", tags: [
            "paste", "open", "run", "search", "translate",
            "save", "reply", "schedule", "convert", "copy"]),
        TagDimension(name: "Salience", tags: [
            "critical", "high", "normal", "low", "frequent",
            "rare", "pinned", "shared", "draft", "done"]),
    ])

    static let builtIn: [TagBasket] = [general]

    /// User-editable flat basket, persisted in UserDefaults (defaults to the
    /// cube's flat tag view). Editing it as a free-form list makes it flat, not a
    /// cube — dimensional features only apply to dimensional baskets.
    static var custom: TagBasket {
        get {
            let tags = (UserDefaults.standard.array(forKey: "customTags") as? [String]) ?? general.tags
            return TagBasket(id: "custom", name: "Custom", tags: tags)
        }
        set { UserDefaults.standard.set(newValue.tags, forKey: "customTags") }
    }

    static var all: [TagBasket] { builtIn + [custom] }

    static var activeID: String {
        get { UserDefaults.standard.string(forKey: "activeBasket") ?? "general" }
        set { UserDefaults.standard.set(newValue, forKey: "activeBasket") }
    }

    static var active: TagBasket { all.first { $0.id == activeID } ?? general }
}
