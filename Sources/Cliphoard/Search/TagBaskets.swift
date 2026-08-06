import Foundation

/// One axis of the facet cube: an orthogonal question about a clip, answered by
/// the argmax of its `tags` (gated on `TagSpace.assignmentThreshold`).
///
/// **What an axis may NOT be any more.** The 2026-08-06 audit of all 202 real
/// clips (design §1) measured this technique — argmax cosine against a bare tag
/// *word* — and found the abstract axes were coin flips: Intent and Sensitivity
/// scored a top1−top2 margin of 0.03–0.04 on BOTH open-ogma-small (8.9M) and
/// embeddinggemma-300m (300M). A 34× larger model did not move them, so the
/// TECHNIQUE, not model capacity, is the root cause. Content type merely
/// re-derived the known `kind` field; Domain (0.08) was abstract and actionless.
///
/// So `Content type`, `Domain`, `Intent` and `Sensitivity` are **retired** (design
/// §4 drop list) and replaced with NOTHING. They already have deterministic
/// successors in the shipped product — `Detectors` (shape + `ClipFlags`) and
/// `DerivedTags` (source / lifecycle / link-disposition) — which is why deleting
/// them costs the product nothing and *reduces* the chips per clip.
///
/// An axis survives here only if BOTH hold:
///  1. every one of its values names a **concrete, externally-checkable thing**
///     (a programming language, a data structure, a deploy environment, a
///     document type) rather than an abstract judgement about purpose, tone,
///     audience or sensitivity; and
///  2. it is **not already derived deterministically** (app of origin, recency /
///     reuse, link disposition — see `DerivedTags`).
///
/// Adding a new *word*-scored axis is a regression, not a feature. The gated,
/// deterministic detectors and behavioural signals are the only
/// sanctioned way to add embedding-driven vocabulary, and it scores against
/// centroids of concrete example PHRASES, never against a bare word.
struct TagDimension: Codable, Equatable {
    var name: String
    var tags: [String]
}

/// A named classification taxonomy ("basket"). Two shapes:
///
/// - **Hybrid** (`isDimensional`): fixed-width axes — possibly NONE — followed by
///   a topical pool. Axis ids remain contiguous and stable; topical ids occupy
///   the tail.
/// - **Flat**: the legacy pool, where a clip takes its nearest few tags globally
///   (`TagSpace.classify`). Used by the user-editable Custom basket, whose tags
///   are an arbitrary list.
///
/// Switching basket re-tags clips from their cached vectors — no re-embedding —
/// so it's cheap.
struct TagBasket: Identifiable, Codable, Equatable {
    /// Width of a *surviving* axis. Every dimension that is still curated holds
    /// exactly this many tags, so tag-ids map onto contiguous, predictable slices
    /// (dimension `d` owns `d*dimensionSize ..< (d+1)*dimensionSize`) and two
    /// baskets can be concatenated (see `TagBaskets.composed`) without
    /// renumbering anything but the topical tail.
    ///
    /// NOTE — this is a LAYOUT constant, not a vocabulary mandate. Design §4
    /// explicitly drops "the `dimensionSize = 8` invariant", by which it means the
    /// obligation to *invent* eight near-synonyms for an axis so it can exist at
    /// all: that padding is what produced the 0.04-margin coin flips. Baskets are
    /// now free to carry FEWER axes (General carries none), and the rule that
    /// survives is only "if an axis exists, it tiles on an 8-wide slice".
    static let dimensionSize = 8

    var id: String
    var name: String
    /// The cube's axes, in order. Empty for a flat basket.
    var dimensions: [TagDimension]
    /// Free topical vocabulary appended after every axis slice. Empty for the
    /// user-editable flat Custom basket.
    var topical: [String]
    /// Backing store for a flat basket's tag pool. Ignored by a hybrid basket
    /// (the flat view is then derived from the dimensions + topical tail).
    private var flatTags: [String]

    /// Discriminator between the two shapes, stored rather than inferred.
    ///
    /// It used to be inferred as `dimensions.isEmpty`, which was fine only while
    /// every hybrid basket was guaranteed to own at least one axis. Retiring the
    /// four abstract axes leaves General with ZERO axes and a topical tail, and
    /// under the old inference that basket would silently flip to "flat" and
    /// report an EMPTY tag list (`flatTags` is empty for a hybrid). So the shape
    /// is now recorded at construction.
    private var isFlat: Bool

    /// Flat tag list: tag-id = index. For a hybrid basket this is the dimensions
    /// concatenated (dimension d owns ids `d*size ..< d*size+size`) followed by
    /// the topical tail; for a flat basket it's the raw pool.
    var tags: [String] {
        isFlat ? flatTags : dimensions.flatMap { $0.tags } + topical
    }

    /// Tag-id range owned by the topical tail: `dimensions.count * dimensionSize
    /// ..< tags.count` whenever the fixed-width invariant holds. Summed from the
    /// real axis widths rather than multiplied so a hand-built uneven basket
    /// (tests, a future migration) — or an axis-less basket like General — still
    /// partitions correctly. Empty (`0..<0`-shaped) for a flat basket.
    var topicalRange: Range<Int> {
        guard !isFlat else { return 0..<0 }
        let start = dimensions.reduce(0) { $0 + $1.tags.count }
        return start..<(start + topical.count)
    }

    /// True when this basket is a facet cube: classify along every dimension it
    /// has (possibly none) PLUS the topical tail, instead of taking the nearest
    /// few tags from one undifferentiated pool.
    var isDimensional: Bool { !isFlat }

    /// Hybrid basket (a facet cube plus a topical tail). Every dimension should
    /// hold `dimensionSize` tags so tag-ids map cleanly onto fixed-width slices.
    /// Zero dimensions is legal and, for General, is now the point.
    init(id: String, name: String, dimensions: [TagDimension], topical: [String] = []) {
        self.id = id; self.name = name
        self.dimensions = dimensions
        self.topical = topical
        self.flatTags = []
        self.isFlat = false
    }

    /// Flat basket (legacy pool). Kept for the Custom basket, which the user
    /// edits as a free-form list.
    init(id: String, name: String, tags: [String]) {
        self.id = id; self.name = name
        self.dimensions = []
        self.topical = []
        self.flatTags = tags
        self.isFlat = true
    }

    /// Stable fingerprint of the tag set, for caching tag vectors. `tags` is the
    /// axes *plus* the topical tail, so editing either side (or composing an
    /// overlay onto General) changes the fingerprint and invalidates the cached
    /// tag vectors — no separate topical term is needed.
    var fingerprint: String { "\(id):\(tags.count):\(HashingEmbedder.fnv1a(tags.joined(separator: "|")))" }

    /// Fingerprint of the vocabulary the tag-ids CURRENTLY ON DISK were minted
    /// against, or nil if never recorded.
    ///
    /// `ModelEmbedding.tags` stores integer ids resolved POSITIONALLY through
    /// `TagBaskets.active.tags`. Nothing else on disk records which vocabulary
    /// produced them, so any edit to a basket silently re-points every stored id
    /// at a different word — e.g. the old `Domain` value "personal" (global id 12)
    /// lands on "password" under a 16-tag General, and a private note renders a
    /// `password` chip. Ids past the new end simply vanish.
    ///
    /// This is not only a migration concern: switching the overlay in Settings has
    /// always renumbered the ids, and that reclassify is an async task with no
    /// completion marker, so quitting mid-pass leaves clips permanently carrying a
    /// MIX of old and new ids with nothing able to detect it. The marker below is
    /// what makes that state observable and self-healing.
    static var persistedVocabulary: String? {
        get { UserDefaults.standard.string(forKey: persistedVocabularyKey) }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: persistedVocabularyKey) }
            else { UserDefaults.standard.removeObject(forKey: persistedVocabularyKey) }
        }
    }
    static let persistedVocabularyKey = "persistedTagVocabulary"

    // MARK: Codable (resilient: old baskets persisted before `dimensions` existed
    // still decode as flat).
    private enum CodingKeys: String, CodingKey { case id, name, dimensions, topical, flatTags, tags, isFlat }
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
        // Payloads written before the shape was stored carry neither key; the old
        // inference (`dimensions.isEmpty`) reproduces their meaning exactly,
        // because no basket could be hybrid-with-no-axes back then. A payload with
        // a topical tail but no axes could only have come from a NEW build, and
        // that build always writes `isFlat`.
        isFlat = try c.decodeIfPresent(Bool.self, forKey: .isFlat)
            ?? (dimensions.isEmpty && topical.isEmpty)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(dimensions, forKey: .dimensions)
        try c.encode(topical, forKey: .topical)
        try c.encode(flatTags, forKey: .flatTags)
        try c.encode(isFlat, forKey: .isFlat)
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

    // MARK: The retirement (design §4)
    //
    // Every basket below shed the axes the 202-clip audit condemned. Nothing was
    // put in their place — the replacements already shipped as deterministic
    // rules (`Detectors`, `DerivedTags`), so the net effect is FEWER auto-tags per
    // clip, which is the entire point.
    //
    //   basket      axes before → after   dropped
    //   ─────────────────────────────────────────────────────────────────────────
    //   general        4 → 0    Content type, Domain, Intent, Sensitivity
    //   dev            4 → 2    Intent, Sensitivity
    //   writer         4 → 1    Domain, Intent, Tone
    //   design         4 → 1    Domain, Intent, Source
    //   research       4 → 1    Field, Intent, Source
    //   finance        4 → 1    Sensitivity, Intent, Party
    //   personal       4 → 1    Sensitivity, Intent, Recurrence
    //   marketing      4 → 2    Intent, Audience
    //   data           4 → 1    Domain, Intent, Sensitivity
    //   devops         4 → 2    Intent, Sensitivity
    //   legal          4 → 1    Sensitivity, Intent, Party
    //   ─────────────────────────────────────────────────────────────────────────
    //   total         44 → 13
    //
    // Beyond the four named axes, the same two tests (see `TagDimension`) removed:
    //  · Tone / Audience / Party / Field — abstract judgements with no glance
    //    action, i.e. Intent and Domain wearing a specialist hat.
    //  · Source (designer, researcher) and Recurrence (personal) — already
    //    derived, exactly and for free, by `DerivedTags.source` and
    //    `DerivedTags.lifecycle` from `clip.sourceApp` / `useCount` / age. Asking
    //    a 8.9M-parameter model to guess what a metadata field already knows is
    //    strictly worse than reading the field.
    //
    // What survives is concrete and externally checkable: a language, a data
    // structure, a deploy environment, a document type. The topical tail is
    // unchanged and still capped at three, thresholded entries.

    /// General: **zero axes**. Every axis it used to carry was one of the four the
    /// audit condemned, and design §4 says to replace them with nothing. What a
    /// clip gets from the model is now at most three *thresholded* topical tags,
    /// on top of the deterministic chips the UI already renders.
    static let general = hybrid("general", "General", [
    ], [])   // §4: every one of the old 16 either duplicates a deterministic
             // detector (url/path/command/code/color/amount/id -> Detectors.shape;
             // email/phone/address/password -> ClipFlags) or maps to no glance
             // action at all (date/name/quote/note). General emits NO model-derived
             // tags; the chips a user sees come from detectors, metadata and their
             // own labels.

    /// Developer keeps `Artifact` (a diff is not a stack trace is not a schema)
    /// and `Language` (python/swift/sql are genuinely separable, and the audit
    /// never faulted them). Intent and Sensitivity are gone.
    static let developer = hybrid("dev", "Developer", [
        ("Artifact", ["code", "config", "command", "log", "error", "snippet", "diff", "schema"]),
        ("Language", ["python", "javascript", "swift", "shell", "sql", "markup", "rust", "go"]),
    ], ["git", "regex", "docker", "kubernetes", "api", "stacktrace", "dependency", "uuid", "json", "yaml", "test", "build"])

    /// Writer keeps `Form` — an outline really does look different from a
    /// headline. `Tone` went with `Intent`: "persuasive vs neutral vs formal" is
    /// the same synonym soup, and no chip on it leads to an action.
    static let writer = hybrid("writer", "Writer / Content", [
        ("Form", ["draft", "quote", "note", "outline", "headline", "paragraph", "list", "revision"]),
    ], ["title", "intro", "conclusion", "citation", "epigraph", "dialogue", "metaphor", "hook", "cta", "byline", "footnote", "excerpt", "summary", "tagline", "pullquote", "caption"])

    /// Designer keeps `Asset` (a hex colour, a font name and a shadow spec are
    /// distinguishable by *shape*, not by vibe). `Source` is dropped because
    /// `DerivedTags.source` reads the originating app exactly.
    static let designer = hybrid("design", "Designer", [
        ("Asset", ["color", "font", "spec", "asset-link", "measurement", "icon", "gradient", "shadow"]),
    ], ["hex", "rgba", "hsl", "px", "rem", "spacing", "radius", "opacity", "css", "tailwind", "breakpoint", "grid", "palette", "token", "kerning", "leading"])

    /// Researcher keeps `Content` (a citation, an equation and an abstract are
    /// structurally distinct). `Field` is Domain in a lab coat; `Source` is
    /// derived metadata.
    static let researcher = hybrid("research", "Researcher / Academic", [
        ("Content", ["citation", "quote", "data", "note", "abstract", "figure", "definition", "hypothesis"]),
    ], ["doi", "bibtex", "arxiv", "citation", "dataset", "equation", "p-value", "methodology", "abstract", "reference", "corpus", "benchmark", "hypothesis", "figure", "table", "appendix"])

    /// Finance keeps `Doc`. `Party` (client vs vendor vs partner vs investor) is
    /// an unknowable judgement about a relationship, not a property of the text.
    static let finance = hybrid("finance", "Finance / Business", [
        ("Doc", ["invoice", "figure", "contract", "email", "receipt", "statement", "quote", "report"]),
    ], ["iban", "invoice", "tax", "vat", "currency", "account", "balance", "deadline", "po-number", "quote", "budget", "expense", "revenue", "contract", "terms"])

    /// Personal keeps `Category`. `Recurrence` is dropped outright: momentary /
    /// today / expired is `DerivedTags.lifecycle`, computed from real timestamps
    /// instead of guessed from prose.
    static let personal = hybrid("personal", "Personal / Life", [
        ("Category", ["contact", "address", "credential", "note", "link", "booking", "id", "reminder"]),
    ], ["otp", "booking", "tracking", "wifi", "appointment", "birthday", "gift-idea", "recipe", "pin", "membership"])

    /// Marketing keeps `Channel` and `Asset` — both name concrete artefacts.
    /// `Audience` (broad/niche/lead/community) is unmeasurable from a clipboard
    /// snippet.
    static let marketing = hybrid("marketing", "Marketing / Social", [
        ("Channel", ["post", "ad", "email", "dm", "story", "thread", "newsletter", "landing"]),
        ("Asset", ["copy", "headline", "cta", "hashtag", "link", "caption", "subject", "bio"]),
    ], ["hashtag", "cta", "utm", "caption", "headline", "subject-line", "emoji", "mention", "tagline", "hook", "offer", "promo-code", "handle", "bio", "thread"])

    /// Data keeps `Structure` — the one axis here a model can actually see in the
    /// bytes (a CSV is not JSON is not a SQL query).
    static let data = hybrid("data", "Data / Analyst", [
        ("Structure", ["table", "json", "csv", "query", "chart", "schema", "key-value", "blob"]),
    ], ["sql", "csv", "json", "schema", "query", "column", "join", "aggregate", "dashboard", "metric", "kpi", "pivot", "dataset", "api", "regex"])

    /// DevOps keeps `Artifact` and `Environment` — "prod" vs "staging" is usually
    /// literally spelled out in the string being classified.
    static let devops = hybrid("devops", "DevOps / Sysadmin", [
        ("Artifact", ["command", "config", "log", "secret", "script", "manifest", "endpoint", "path"]),
        ("Environment", ["prod", "staging", "dev", "local", "ci", "cloud", "on-prem", "test"]),
    ], ["ssh", "kubernetes", "docker", "ip", "port", "dns", "cert", "systemd", "cron", "terraform", "ansible", "hostname", "namespace"])

    /// Legal keeps `Doc`. `Party` goes for the same reason as in Finance.
    static let legal = hybrid("legal", "Legal / Admin", [
        ("Doc", ["clause", "id", "reference", "date", "form", "letter", "notice", "statement"]),
    ], ["case-no", "statute", "clause", "date", "deadline", "signature", "reference-no", "ni-number", "passport", "jurisdiction", "party", "exhibit", "form", "notice", "docket"])

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

    // MARK: - Composition (General + one optional specialist overlay)

    /// The specialist basket layered on top of General, by id (nil = General
    /// alone). Persisted so the choice survives relaunch. Setting it drops the
    /// memoized `composed` basket; every read of `composed` re-checks the stored
    /// id anyway, so an out-of-band write can't leave a stale cube behind.
    static var overlayID: String? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "overlayBasket"),
                  !raw.isEmpty else { return nil }
            return raw
        }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: "overlayBasket")
            } else {
                UserDefaults.standard.removeObject(forKey: "overlayBasket")
            }
            cachedComposed = nil
        }
    }

    /// The overlay basket itself, resolved from `overlayID`. Nil when no overlay
    /// is selected, when the stored id no longer exists (a basket was renamed or
    /// dropped between versions), or when it points at General itself — General
    /// is always the base, never its own overlay.
    static var overlay: TagBasket? {
        // General is the base (never its own overlay); "custom" is the flat pool,
        // selected as a whole basket via `active`, not composed onto General.
        guard let oid = overlayID, oid != general.id, oid != "custom" else { return nil }
        return all.first { $0.id == oid && $0.isDimensional }
    }

    /// Memoized derived basket, keyed by the overlay id it was built from.
    private static var cachedComposed: (String, TagBasket)?

    /// The basket the app actually classifies with: General on its own, or
    /// General MERGED with a specialist overlay. The merge is deduplicated, not a
    /// raw concatenation: specialists may reuse a topical term (url, path, email)
    /// and could still redefine a same-named axis. A plain concatenation would
    /// then produce two same-named axes and duplicate topical tags — duplicate
    /// tag-name vectors that corrupt classification. Instead:
    ///
    /// Since the retirement, General contributes ZERO axes, so a composed basket
    /// carries only the overlay's surviving concrete axes (1–2) plus the merged
    /// topical tail. Overlay selection can no longer *add* an abstract axis to
    /// General, because General has none to redefine and no specialist keeps one.
    ///  - Axes keep General's ordering; where the overlay redefines an axis of the
    ///    same name, the overlay's more-specific vocabulary WINS; the overlay's
    ///    genuinely new axes are appended after General's.
    ///  - Topical is the union, General first, later duplicates dropped.
    /// All curated axes are `dimensionSize`-wide, so the merged basket still tiles
    /// cleanly (axes first, one contiguous topical tail).
    ///
    /// Derived, not stored: no clip is re-embedded when the overlay changes, the
    /// tags are simply recomputed from the cached vectors.
    static var composed: TagBasket {
        guard let overlay else { return general }
        if let (key, basket) = cachedComposed, key == overlay.id { return basket }
        let overlayByName = Dictionary(overlay.dimensions.map { ($0.name, $0) },
                                       uniquingKeysWith: { first, _ in first })
        let generalNames = Set(general.dimensions.map { $0.name })
        let mergedDimensions = general.dimensions.map { overlayByName[$0.name] ?? $0 }
            + overlay.dimensions.filter { !generalNames.contains($0.name) }
        var seenTopical = Set<String>()
        let mergedTopical = (general.topical + overlay.topical).filter { seenTopical.insert($0).inserted }
        let basket = TagBasket(id: "composed:\(overlay.id)",
                               name: "\(general.name) + \(overlay.name)",
                               dimensions: mergedDimensions,
                               topical: mergedTopical)
        cachedComposed = (overlay.id, basket)
        return basket
    }

    /// Kept for every existing caller (`TagSpace`, Settings): the basket in force
    /// right now, which under the hybrid model is the composed one.
    static var active: TagBasket {
        // Selecting the flat Custom pool classifies with it directly; otherwise
        // the app runs General with an optional specialist overlay.
        overlayID == "custom" ? custom : composed
    }
}
