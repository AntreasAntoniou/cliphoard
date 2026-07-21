import Foundation
import CoreML
import Accelerate

// MARK: - Levels & modes

/// Embedding model tier (selects which on-device model produces vectors).
/// Until a CoreML model is bundled for a tier, the engine falls back to the
/// dependency-free `HashingEmbedder` so everything still works.
enum DeepSearchLevel: String, CaseIterable, Identifiable {
    case off, low, normal, high
    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:    return "Off"
        case .low:    return "Low (ogma-micro)"
        case .normal: return "Normal (ogma-small)"
        case .high:   return "High (EmbeddingGemma)"
        }
    }

    /// Bundled CoreML model name (`<name>.mlmodelc`) for this tier.
    /// high also drives image search (via OCR text).
    /// - low → axiotic/ogma-micro (2.3M, 128-dim)
    /// - normal → axiotic/ogma-small (8.6M, 256-dim)
    /// - high → google/embeddinggemma-300m (768-dim)
    var modelName: String? {
        switch self {
        case .off:    return nil
        case .low:    return "ogma-micro"
        case .normal: return "ogma-small"
        case .high:   return "embeddinggemma-300m"
        }
    }

    /// Output embedding dimension for each tier's model.
    var dimension: Int {
        switch self {
        case .off:    return 256
        case .low:    return 128
        case .normal: return 256
        case .high:   return 768
        }
    }
}

/// How the bar searches. Ordered simplest → smartest; `smart` is the default.
/// - `exact`: case-insensitive substring (no vectors) — the literal words you type.
/// - `tag`: classify the query to its nearest preset tag, then O(1) lookup of
///   entries pre-tagged at ingest — search by auto category.
/// - `neural`: pure model-based semantic ranking — every clip scored by the
///   on-device embedding model's query·clip cosine, no substring, no tags.
/// - `smart` (default): the clever hybrid — exact substring hits are guaranteed
///   and rank first, then the rest are ordered by a blend of neural cosine and
///   shared-tag topic agreement.
enum SearchMode: String, CaseIterable, Identifiable {
    case exact, tag, neural, smart
    var id: String { rawValue }
    var title: String {
        switch self {
        case .exact:  return "Exact"
        case .tag:    return "Tag"
        case .neural: return "Neural"
        case .smart:  return "Smart"
        }
    }
    var blurb: String {
        switch self {
        case .exact:  return "The literal words you type"
        case .tag:    return "By auto category"
        case .neural: return "Pure meaning, by the model"
        case .smart:  return "Exact, tag & neural — combined"
        }
    }
    var symbol: String {
        switch self {
        case .exact:  return "magnifyingglass"
        case .tag:    return "tag"
        case .neural: return "brain"
        case .smart:  return "sparkles"
        }
    }
    /// True for modes that need the embedding model / vectors (everything but exact).
    var usesModel: Bool { self != .exact }
}

enum DeepSearch {
    static var level: DeepSearchLevel {
        // Default to ogma-small so semantic search + tagging work out of the box.
        get { DeepSearchLevel(rawValue: UserDefaults.standard.string(forKey: "deepSearchLevel") ?? "normal") ?? .normal }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "deepSearchLevel") }
    }
    static var mode: SearchMode {
        // Default to Smart (exact hits first, then by meaning) — deterministic AND
        // discoverable. Legacy "essence" values fall through to this.
        get { SearchMode(rawValue: UserDefaults.standard.string(forKey: "searchMode") ?? "smart") ?? .smart }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "searchMode") }
    }
}

// MARK: - Embedding

protocol TextEmbedder {
    var dimension: Int { get }
    /// Stable identity of this embedder ("hashing-256", "ogma-small-256", …).
    /// Stored vectors / tag vectors are only comparable within one signature.
    var signature: String { get }
    /// Embed a document/symmetric text.
    func embed(_ text: String) -> [Float]
    /// Embed, distinguishing a query from a document (asymmetric models use the
    /// QRY vs DOC task token). Defaults to the document path.
    func embed(_ text: String, query: Bool) -> [Float]
}

extension TextEmbedder {
    func embed(_ text: String, query: Bool) -> [Float] { embed(text) }
}

/// Real, dependency-free embedder: hashed character tri-grams + word tokens,
/// L2-normalised. Gives fuzzy/sub-token matching and is the fallback whenever a
/// CoreML model isn't bundled. Deterministic (uses a stable FNV-1a hash, not
/// `Hasher`, so vectors persisted on disk stay valid across launches).
struct HashingEmbedder: TextEmbedder {
    let dimension: Int = 256
    let signature = "hashing-256"

    func embed(_ text: String) -> [Float] {
        var vec = [Float](repeating: 0, count: dimension)
        let lower = text.lowercased()
        for token in lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            vec[Int(Self.fnv1a(String(token)) % UInt64(dimension))] += 1
        }
        let chars = Array(lower)
        if chars.count >= 3 {
            for i in 0...(chars.count - 3) {
                vec[Int(Self.fnv1a(String(chars[i..<i + 3])) % UInt64(dimension))] += 1
            }
        }
        return Self.normalize(vec)
    }

    /// Stable across processes (unlike Swift's randomized `Hasher`).
    static func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return hash
    }

    static func normalize(_ v: [Float]) -> [Float] {
        let norm = (v.reduce(0) { $0 + $1 * $1 }).squareRoot()
        return norm > 0 ? v.map { $0 / norm } : v
    }
}

/// On-device CoreML embedder for the ogma models. The converted model's forward
/// already returns a pooled, L2-normalised vector; we just tokenize (Unigram via
/// swift-transformers) and run a prediction, passing the task token separately
/// (4=QRY, 5=DOC, 6=SYM) exactly as the model expects.
final class OgmaEmbedder: TextEmbedder {
    let dimension: Int
    let signature: String
    private let model: MLModel
    private let tokenizer: OgmaTokenizer
    private let maxLen = 256

    private enum Task: Int32 { case qry = 4, doc = 5, sym = 6 }

    init(modelName: String, model: MLModel, tokenizer: OgmaTokenizer, dimension: Int) {
        self.model = model
        self.tokenizer = tokenizer
        self.dimension = dimension
        self.signature = "\(modelName)-\(dimension)-v1"
    }

    func embed(_ text: String) -> [Float] { run(text, task: .doc) }
    func embed(_ text: String, query: Bool) -> [Float] { run(text, task: query ? .qry : .doc) }

    private func run(_ text: String, task: Task) -> [Float] {
        var ids = tokenizer.encode(text).map { Int32($0) }
        if ids.count > maxLen { ids = Array(ids.prefix(maxLen - 1)) + [ids[ids.count - 1]] }
        let len = ids.count
        // Return [] (not a zero vector) on every failure path. A zero vector would
        // be cached as a valid embedding and never retried, permanently corrupting
        // this clip's tags/search; an empty result keeps it stale for re-indexing.
        guard let idArr = try? MLMultiArray(shape: [1, NSNumber(value: len)], dataType: .int32),
              let maskArr = try? MLMultiArray(shape: [1, NSNumber(value: len)], dataType: .int32),
              let taskArr = try? MLMultiArray(shape: [1], dataType: .int32) else {
            return []
        }
        for i in 0..<len { idArr[i] = NSNumber(value: ids[i]); maskArr[i] = 1 }
        taskArr[0] = NSNumber(value: task.rawValue)
        let out: MLFeatureProvider
        do {
            let input = try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": idArr, "attention_mask": maskArr, "task_token_ids": taskArr
            ])
            out = try model.prediction(from: input)
        } catch {
            NSLog("Cliphoard OgmaEmbedder: prediction failed (ids=\(ids.prefix(8))): \(error)")
            return []
        }
        guard let emb = out.featureValue(for: "embedding")?.multiArrayValue else {
            NSLog("Cliphoard OgmaEmbedder: no 'embedding' output; features=\(out.featureNames)")
            return []
        }
        var v = [Float](repeating: 0, count: emb.count)
        for i in 0..<emb.count { v[i] = emb[i].floatValue }
        if DebugLog.enabled {
            NSLog("Cliphoard OgmaEmbedder: ids=\(ids.prefix(8)) len=\(len) embCount=\(emb.count) dtype=\(emb.dataType.rawValue) v0..2=\(v.prefix(3))")
        }
        return v
    }
}

/// Owns the currently-active embedder. Loads CoreML models asynchronously and
/// swaps them in when ready; until then (and when a tier has no bundled model)
/// the `HashingEmbedder` is used so search always works.
@MainActor
enum EmbedderProvider {
    private(set) static var active: TextEmbedder = HashingEmbedder()

    /// Load the embedder for `level` (CoreML model + hand-rolled tokenizer, both
    /// synchronous). Falls back to the HashingEmbedder when the tier has no model
    /// bundled or loading fails.
    @discardableResult
    static func configure(level: DeepSearchLevel) -> Bool {
        let before = active.signature
        // OgmaTokenizer implements ONLY ogma's tokenizer (metaspace + offset); it
        // would mis-tokenize a non-ogma model (e.g. EmbeddingGemma). Gate to ogma.
        if let name = level.modelName, name.hasPrefix("ogma"),
           let modelURL = Bundle.main.url(forResource: name, withExtension: "mlmodelc"),
           let tokFolder = Bundle.main.url(forResource: "\(name)-tokenizer", withExtension: nil),
           let model = try? MLModel(contentsOf: modelURL),
           let tokenizer = OgmaTokenizer(folder: tokFolder) {
            active = OgmaEmbedder(modelName: name, model: model, tokenizer: tokenizer,
                                  dimension: level.dimension)
        } else {
            if level != .off { NSLog("Cliphoard: embedder unavailable for \(level.rawValue) — using fallback") }
            active = HashingEmbedder()
        }
        return active.signature != before
    }

    /// Configure for `level`, then reprocess only the entries not already in the
    /// active model's space. Skipped entirely for the `off` tier, whose substring
    /// search doesn't use vectors — so we don't churn embeddings needlessly.
    static func configureAndReindex(level: DeepSearchLevel, store: ClipStore) {
        configure(level: level)
        if level != .off { store.refreshForActiveModel() }
    }
}

// MARK: - Preset tag taxonomy (100 tags)

@MainActor
enum TagSpace {
    /// Tag names of the currently-selected basket. Index = stable tag id (within
    /// the active basket). See `TagBaskets`.
    static var names: [String] { TagBaskets.active.tags }

    static var count: Int { names.count }

    /// Tag vectors in the active embedder's space, cached per (embedder, basket)
    /// — two models can share a dimension, and the basket can change the tags.
    private static var cache: (String, [[Float]])?

    static func vectors(using embedder: TextEmbedder) -> [[Float]] {
        let key = embedder.signature + "#" + TagBaskets.active.fingerprint
        if let (k, v) = cache, k == key { return v }
        let v = names.map { embedder.embed($0) }
        cache = (key, v)
        return v
    }

    /// Top-K nearest tag ids for an entry vector, over the WHOLE tag pool. Used
    /// by flat baskets at ingest and by the query side of tag/smart search
    /// ("what categories is this query nearest?").
    static func classify(_ vector: [Float], embedder: TextEmbedder, topK: Int = 5) -> [Int] {
        guard !vector.isEmpty else { return [] }
        let tagVecs = vectors(using: embedder)
        let scored = tagVecs.enumerated().map { ($0.offset, SemanticRanker.cosine(vector, $0.element)) }
        return scored.sorted { $0.1 > $1.1 }.prefix(topK).map { $0.0 }
    }

    /// Nearest single tag id for a query (used by tag search).
    static func nearestTag(toQuery query: String, embedder: TextEmbedder) -> Int? {
        classify(embedder.embed(query, query: true), embedder: embedder, topK: 1).first
    }

    // MARK: - Dimensional (facet-cube) support

    /// True when the active basket is a facet cube (classify along every axis).
    static var isDimensional: Bool { TagBaskets.active.isDimensional }

    /// The active basket's dimensions, in order (empty for a flat basket).
    static var dimensions: [TagDimension] { TagBaskets.active.dimensions }

    static var dimensionCount: Int { dimensions.count }

    /// Half-open tag-id range owned by dimension `d`. Ranges are cumulative over
    /// each dimension's actual size, so cubes with uneven axes still map cleanly.
    static func range(ofDimension d: Int) -> Range<Int> {
        let dims = dimensions
        guard dims.indices.contains(d) else { return 0..<0 }
        var start = 0
        for i in 0..<d { start += dims[i].tags.count }
        return start..<(start + dims[d].tags.count)
    }

    /// Which dimension owns tag-id `tag` (or nil for a flat basket / out-of-range).
    static func dimension(ofTag tag: Int) -> Int? {
        guard isDimensional else { return nil }
        var start = 0
        for (d, dim) in dimensions.enumerated() {
            let end = start + dim.tags.count
            if tag >= start && tag < end { return d }
            start = end
        }
        return nil
    }

    /// Classify a vector along EVERY dimension: the argmax tag within each
    /// dimension's slice. Returns one tag-id per dimension, in dimension order —
    /// so a clip is described by a value on every axis. Empty for a flat basket
    /// (callers use `classify(topK:)` there instead).
    static func classifyDimensions(_ vector: [Float], embedder: TextEmbedder) -> [Int] {
        guard !vector.isEmpty, isDimensional else { return [] }
        let tagVecs = vectors(using: embedder)
        return (0..<dimensionCount).compactMap { d in
            let r = range(ofDimension: d)
            guard !r.isEmpty else { return nil }
            var best = r.lowerBound
            var bestScore = SemanticRanker.cosine(vector, tagVecs[r.lowerBound])
            for i in r.dropFirst() {
                let s = SemanticRanker.cosine(vector, tagVecs[i])
                if s > bestScore { bestScore = s; best = i }
            }
            return best
        }
    }

    /// The facet labels for a set of tag ids ("Content type: code", …), in
    /// dimension order. For display of a clip's cube coordinates.
    static func facetLabels(for tagIDs: [Int]) -> [(dimension: String, value: String)] {
        let names = self.names
        return tagIDs.sorted().compactMap { id in
            guard names.indices.contains(id), let d = dimension(ofTag: id) else { return nil }
            return (dimensions[d].name, names[id])
        }
    }
}

// MARK: - Ingest indexing

@MainActor
enum ClipIndexer {
    /// Compute and attach the entry's vector + top-5 tag ids using the active
    /// embedder. Entries are documents, so use the DOC task token.
    static func index(_ item: ClipItem) {
        let embedder = EmbedderProvider.active
        let vec = embedder.embed(SemanticRanker.searchText(item))
        // Don't cache a failed/degenerate embedding — leave the clip stale so it's
        // retried, rather than poisoning its tags/search permanently.
        guard isUsable(vec, dimension: embedder.dimension) else { return }
        item.embeddings[embedder.signature] = ModelEmbedding(vector: vec, tags: tags(for: vec, embedder: embedder))
    }

    /// A clip's tag ids for the active basket: one value per dimension for a
    /// facet cube, or the nearest five for a flat pool. Both feed the same
    /// `tagIndex`, so the store's O(1) lookup is agnostic to which shape is used.
    static func tags(for vector: [Float], embedder: TextEmbedder) -> [Int] {
        TagSpace.isDimensional
            ? TagSpace.classifyDimensions(vector, embedder: embedder)
            : TagSpace.classify(vector, embedder: embedder, topK: 5)
    }

    /// A vector is usable if it's the right length and not all-zeros.
    static func isUsable(_ vec: [Float], dimension: Int) -> Bool {
        vec.count == dimension && vec.contains { $0 != 0 }
    }

    /// True when the clip has no usable embedding for the active model yet (no
    /// entry, or a degenerate zero/wrong-length vector from a past failure).
    static func isStale(_ item: ClipItem) -> Bool {
        guard let emb = item.embeddings[EmbedderProvider.active.signature] else { return true }
        return !isUsable(emb.vector, dimension: EmbedderProvider.active.dimension)
    }

    // refineKind was removed: a clip's KIND is now decided solely by deterministic
    // detection (ClipboardMonitor.detectKind / pasteboard type). Letting embeddings
    // reclassify kinds put non-URLs into the Links category and was unreliable.
}

// MARK: - Ranking

enum SemanticRanker {
    static func searchText(_ item: ClipItem) -> String {
        switch item.kind {
        case .file:  return (item.filePath as NSString?)?.lastPathComponent ?? item.text
        case .color: return item.colorHex ?? item.text
        default:     return item.text
        }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return dot // inputs L2-normalised → dot == cosine
    }

    /// Essence search: full query·item cosine, best-first, thresholded.
    static func essence(query: String, items: [ClipItem], embedder: TextEmbedder) -> [ClipItem] {
        let qv = embedder.embed(query, query: true)
        let q = query.lowercased()
        let scored = items.map { item -> (ClipItem, Float) in
            let vec = item.embeddings[embedder.signature]?.vector ?? embedder.embed(searchText(item))
            let substring = searchText(item).lowercased().contains(q)
            return (item, (substring ? 1 : 0) + cosine(qv, vec))
        }
        let kept = scored.filter { $0.1 >= 0.12 }.sorted { $0.1 > $1.1 }
        return (kept.isEmpty ? scored.sorted { $0.1 > $1.1 }.prefix(min(items.count, 12)).map { ($0.0, $0.1) }
                             : kept).map { $0.0 }
    }

    /// Pure NEURAL search: rank every clip by the model's query·clip cosine in the
    /// embedding space — no substring, no tags, just meaning. This is the raw
    /// semantic signal, exposed as its own mode. Thresholded, but with a top-K
    /// fallback so the model's closest guesses are never hidden when the bar isn't
    /// cleared.
    static func neural(query: String, items: [ClipItem], embedder: TextEmbedder) -> [ClipItem] {
        let qv = embedder.embed(query, query: true)
        let scored = items.map { item -> (ClipItem, Float) in
            let vec = item.embeddings[embedder.signature]?.vector ?? embedder.embed(searchText(item))
            return (item, cosine(qv, vec))
        }
        let kept = scored.filter { $0.1 >= 0.20 }.sorted { $0.1 > $1.1 }
        if kept.isEmpty {
            return scored.sorted { $0.1 > $1.1 }.prefix(min(items.count, 8)).map { $0.0 }
        }
        return kept.map { $0.0 }
    }

    /// Hybrid "Smart" search — the clever combination of all three signals:
    ///   • EXACT substring hits are guaranteed and always rank first.
    ///   • NEURAL cosine similarity in the model's space orders the rest by meaning.
    ///   • TAG agreement — the query's nearest preset categories vs the clip's own
    ///     ingest tags — boosts clips that share the query's *topic* even when the
    ///     wording and vectors are only loosely related.
    /// score = exactBonus + cosine + tagBoost. Exact hits (bonus 10) sort above
    /// everything; among the rest, meaning + shared category decide the order.
    /// Non-exact clips must clear a threshold on (cosine + tagBoost) so nothing
    /// unrelated is padded in.
    ///
    /// `@MainActor` because the tag leg reads `TagSpace` (main-actor cache); it is
    /// only ever called from the main-actor view model, like the `tag` mode.
    @MainActor
    static func smart(query: String, items: [ClipItem], embedder: TextEmbedder) -> [ClipItem] {
        let q = query.lowercased()
        let qv = embedder.embed(query, query: true)
        // The query's nearest preset categories — the "tag" leg of the hybrid.
        let queryTags = Set(TagSpace.classify(qv, embedder: embedder, topK: 3))

        let scored = items.map { item -> (item: ClipItem, score: Float, exact: Bool) in
            let emb = item.embeddings[embedder.signature]
            let vec = emb?.vector ?? embedder.embed(searchText(item))
            let exact = searchText(item).lowercased().contains(q)
            let neural = cosine(qv, vec)
            let shared = emb.map { Set($0.tags).intersection(queryTags).count } ?? 0
            let tagBoost = Float(min(shared, 2)) * 0.10          // up to +0.20 for topic agreement
            let score = (exact ? 10 : 0) + neural + tagBoost
            return (item, score, exact)
        }
        // Keep every exact hit; keep the rest only when meaning OR shared topic
        // clears the bar, so the list stays relevant instead of padded with noise.
        return scored
            .filter { $0.exact || $0.score >= 0.18 }
            .sorted { $0.score > $1.score }
            .map { $0.item }
    }
}
