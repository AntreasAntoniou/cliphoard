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
/// - **Hybrid** (`dimensions` non-empty): fixed-width axes followed by a topical
///   pool. Axis ids remain contiguous and stable; topical ids occupy the tail.
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
    /// Free topical vocabulary appended after every axis slice. Empty for the
    /// user-editable flat Custom basket.
    var topical: [String]
    /// Backing store for a flat basket's tag pool. Ignored when `dimensions` is
    /// non-empty (the flat view is then derived from the dimensions).
    private var flatTags: [String]

    /// Flat tag list: tag-id = index. For a cube this is the dimensions
    /// concatenated (dimension d owns ids `d*size ..< d*size+size`); for a flat
    /// basket it's the raw pool.
    var tags: [String] {
        dimensions.isEmpty ? flatTags : dimensions.flatMap { $0.tags } + topical
    }

    /// Tag-id range owned by the topical tail. Empty for a flat basket.
    var topicalRange: Range<Int> {
        guard !dimensions.isEmpty else { return tags.count..<tags.count }
        let start = dimensions.reduce(0) { $0 + $1.tags.count }
        return start..<(start + topical.count)
    }

    /// True when this basket is a facet cube (classify along every dimension).
    var isDimensional: Bool { !dimensions.isEmpty }

    /// Dimensional basket (a facet cube). Every dimension should hold the same
    /// number of tags so tag-ids map cleanly onto fixed-width slices.
    init(id: String, name: String, dimensions: [TagDimension], topical: [String] = []) {
        self.id = id; self.name = name
        self.dimensions = dimensions
        self.topical = topical
        self.flatTags = []
    }

    /// Flat basket (legacy pool). Kept for the Custom basket, which the user
    /// edits as a free-form list.
    init(id: String, name: String, tags: [String]) {
        self.id = id; self.name = name
        self.dimensions = []
        self.topical = []
        self.flatTags = tags
    }

    /// Stable fingerprint of the tag set, for caching tag vectors.
    var fingerprint: String { "\(id):\(tags.count):\(HashingEmbedder.fnv1a(tags.joined(separator: "|")))" }

    // MARK: Codable (resilient: old baskets persisted before `dimensions` existed
    // still decode as flat).
    private enum CodingKeys: String, CodingKey { case id, name, dimensions, topical, flatTags, tags }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        dimensions = try c.decodeIfPresent([TagDimension].self, forKey: .dimensions) ?? []
        topical = try c.decodeIfPresent([String].self, forKey: .topical) ?? []
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
        try c.encode(topical, forKey: .topical)
        try c.encode(flatTags, forKey: .flatTags)
    }
}

@MainActor
enum TagBaskets {
    private static func hybrid(_ id: String, _ name: String,
                               _ dimensions: [(String, [String])], _ topical: [String]) -> TagBasket {
        TagBasket(id: id, name: name,
                  dimensions: dimensions.map { TagDimension(name: $0.0, tags: $0.1) },
                  topical: topical)
    }

    static let general = hybrid("general", "General", [
        ("Content type", ["text", "code", "link", "command", "image", "file", "document", "number"]),
        ("Domain", ["software", "web", "business", "finance", "personal", "academic", "design", "admin"]),
        ("Intent", ["reuse", "reference", "share", "task", "read-later", "edit", "login", "cite"]),
        ("Sensitivity", ["public", "internal", "personal-info", "confidential", "credential", "financial", "pii", "ephemeral"]),
    ], ["url", "email", "phone", "address", "path", "date", "amount", "name", "quote", "command", "color", "id", "password", "note", "link", "code"])

    static let developer = hybrid("dev", "Developer", [
        ("Artifact", ["code", "config", "command", "log", "error", "snippet", "diff", "schema"]),
        ("Language", ["python", "javascript", "swift", "shell", "sql", "markup", "rust", "go"]),
        ("Intent", ["reuse", "debug", "reference", "share", "edit", "run", "cite", "archive"]),
        ("Sensitivity", ["public", "internal", "credential", "token", "api-key", "pii", "confidential", "ephemeral"]),
    ], ["git", "regex", "docker", "kubernetes", "api", "endpoint", "stacktrace", "dependency", "env-var", "path", "uuid", "url", "json", "yaml", "test", "build"])

    static let writer = hybrid("writer", "Writer / Content", [
        ("Form", ["draft", "quote", "note", "outline", "headline", "paragraph", "list", "revision"]),
        ("Domain", ["fiction", "essay", "blog", "script", "academic", "marketing", "personal", "journalism"]),
        ("Intent", ["edit", "cite", "publish", "reference", "reuse", "share", "read-later", "archive"]),
        ("Tone", ["formal", "casual", "persuasive", "technical", "humorous", "neutral", "urgent", "draft"]),
    ], ["title", "intro", "conclusion", "citation", "epigraph", "dialogue", "metaphor", "hook", "cta", "byline", "footnote", "excerpt", "summary", "tagline", "pullquote", "caption"])

    static let designer = hybrid("design", "Designer", [
        ("Asset", ["color", "font", "spec", "asset-link", "measurement", "icon", "gradient", "shadow"]),
        ("Domain", ["ui", "brand", "print", "web", "motion", "product", "illustration", "type"]),
        ("Intent", ["reuse", "reference", "share", "edit", "apply", "cite", "archive", "sample"]),
        ("Source", ["figma", "sketch", "photoshop", "illustrator", "browser", "canva", "code", "notes"]),
    ], ["hex", "rgba", "hsl", "px", "rem", "spacing", "radius", "opacity", "css", "tailwind", "breakpoint", "grid", "palette", "token", "kerning", "leading"])

    static let researcher = hybrid("research", "Researcher / Academic", [
        ("Content", ["citation", "quote", "data", "note", "abstract", "figure", "definition", "hypothesis"]),
        ("Field", ["cs", "ml", "biology", "physics", "medicine", "social", "humanities", "math"]),
        ("Intent", ["cite", "read-later", "annotate", "reference", "reuse", "share", "verify", "archive"]),
        ("Source", ["paper", "book", "preprint", "dataset", "web", "slides", "email", "notes"]),
    ], ["doi", "bibtex", "arxiv", "citation", "dataset", "equation", "p-value", "methodology", "abstract", "reference", "corpus", "benchmark", "hypothesis", "figure", "table", "appendix"])

    static let finance = hybrid("finance", "Finance / Business", [
        ("Doc", ["invoice", "figure", "contract", "email", "receipt", "statement", "quote", "report"]),
        ("Sensitivity", ["public", "internal", "financial", "pii", "confidential", "credential", "legal", "ephemeral"]),
        ("Intent", ["reference", "reuse", "share", "cite", "submit", "reconcile", "archive", "edit"]),
        ("Party", ["client", "vendor", "internal", "bank", "tax", "partner", "investor", "personal"]),
    ], ["amount", "iban", "invoice", "tax", "vat", "currency", "account", "balance", "deadline", "po-number", "quote", "budget", "expense", "revenue", "contract", "terms"])

    static let personal = hybrid("personal", "Personal / Life", [
        ("Category", ["contact", "address", "credential", "note", "link", "booking", "id", "reminder"]),
        ("Sensitivity", ["public", "personal-info", "pii", "credential", "health", "financial", "private", "ephemeral"]),
        ("Intent", ["reuse", "reference", "share", "login", "schedule", "read-later", "save", "archive"]),
        ("Recurrence", ["momentary", "today", "this-week", "recurring", "evergreen", "scheduled", "expired", "undated"]),
    ], ["phone", "email", "address", "otp", "password", "booking", "tracking", "wifi", "appointment", "birthday", "gift-idea", "recipe", "url", "code", "pin", "membership"])

    static let marketing = hybrid("marketing", "Marketing / Social", [
        ("Channel", ["post", "ad", "email", "dm", "story", "thread", "newsletter", "landing"]),
        ("Asset", ["copy", "headline", "cta", "hashtag", "link", "caption", "subject", "bio"]),
        ("Intent", ["publish", "schedule", "reuse", "reference", "edit", "share", "test", "archive"]),
        ("Audience", ["broad", "niche", "customer", "lead", "internal", "press", "community", "personal"]),
    ], ["hashtag", "cta", "utm", "caption", "headline", "subject-line", "emoji", "mention", "link", "tagline", "hook", "offer", "promo-code", "handle", "bio", "thread"])

    static let data = hybrid("data", "Data / Analyst", [
        ("Structure", ["table", "json", "csv", "query", "chart", "schema", "key-value", "blob"]),
        ("Domain", ["sales", "product", "finance", "ops", "marketing", "research", "engineering", "hr"]),
        ("Intent", ["reuse", "reference", "analyze", "share", "cite", "transform", "archive", "verify"]),
        ("Sensitivity", ["public", "internal", "pii", "confidential", "financial", "aggregated", "raw", "ephemeral"]),
    ], ["sql", "csv", "json", "schema", "query", "column", "join", "aggregate", "dashboard", "metric", "kpi", "pivot", "dataset", "api", "endpoint", "regex"])

    static let devops = hybrid("devops", "DevOps / Sysadmin", [
        ("Artifact", ["command", "config", "log", "secret", "script", "manifest", "endpoint", "path"]),
        ("Environment", ["prod", "staging", "dev", "local", "ci", "cloud", "on-prem", "test"]),
        ("Intent", ["run", "debug", "reference", "reuse", "deploy", "monitor", "archive", "share"]),
        ("Sensitivity", ["public", "internal", "credential", "token", "ssh-key", "secret", "pii", "ephemeral"]),
    ], ["ssh", "kubernetes", "docker", "ip", "port", "env-var", "path", "dns", "cert", "systemd", "cron", "terraform", "ansible", "endpoint", "hostname", "namespace"])

    static let legal = hybrid("legal", "Legal / Admin", [
        ("Doc", ["clause", "id", "reference", "date", "form", "letter", "notice", "statement"]),
        ("Sensitivity", ["public", "confidential", "legal", "pii", "privileged", "financial", "personal", "ephemeral"]),
        ("Intent", ["reference", "cite", "submit", "sign", "reuse", "share", "file", "archive"]),
        ("Party", ["client", "court", "counterparty", "self", "agency", "employer", "vendor", "personal"]),
    ], ["case-no", "statute", "clause", "date", "deadline", "signature", "reference-no", "ni-number", "passport", "address", "jurisdiction", "party", "exhibit", "form", "notice", "docket"])

    static let builtIn: [TagBasket] = [
        general, developer, writer, designer, researcher, finance,
        personal, marketing, data, devops, legal,
    ]

    /// User-editable flat basket, persisted in UserDefaults (defaults to the
    /// cube's flat tag view). Editing it as a free-form list makes it flat, not a
    /// cube — dimensional features only apply to dimensional baskets.
    ///
    /// Memoized: the getter is on hot paths (toolbar body, TagSpace lookups) and
    /// decoding a 100-string array out of UserDefaults on every access showed up
    /// as summon latency. All mutations go through this setter (main actor), so
    /// the cache can't go stale.
    private static var cachedCustom: TagBasket?
    static var custom: TagBasket {
        get {
            if let c = cachedCustom { return c }
            let tags = (UserDefaults.standard.array(forKey: "customTags") as? [String]) ?? general.tags
            let basket = TagBasket(id: "custom", name: "Custom", tags: tags)
            cachedCustom = basket
            return basket
        }
        set {
            UserDefaults.standard.set(newValue.tags, forKey: "customTags")
            cachedCustom = TagBasket(id: "custom", name: "Custom", tags: newValue.tags)
        }
    }

    static var all: [TagBasket] { builtIn + [custom] }

    static var activeID: String {
        get { UserDefaults.standard.string(forKey: "activeBasket") ?? "general" }
        set { UserDefaults.standard.set(newValue, forKey: "activeBasket") }
    }

    static var active: TagBasket { all.first { $0.id == activeID } ?? general }
}
