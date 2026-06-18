import Foundation
import CoreML

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

/// How the bar searches.
/// - `exact`: case-insensitive substring (no vectors).
/// - `tag`: classify the query to its nearest preset tag (100 comparisons),
///   then O(1) lookup of entries pre-tagged at ingest — no per-item dot product.
/// - `essence`: full query·item cosine over every entry's stored vector.
enum SearchMode: String, CaseIterable, Identifiable {
    case exact, tag, essence
    var id: String { rawValue }
    var title: String {
        switch self {
        case .exact:   return "Exact"
        case .tag:     return "Tag"
        case .essence: return "Essence"
        }
    }
}

enum DeepSearch {
    static var level: DeepSearchLevel {
        get { DeepSearchLevel(rawValue: UserDefaults.standard.string(forKey: "deepSearchLevel") ?? "off") ?? .off }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "deepSearchLevel") }
    }
    static var mode: SearchMode {
        get { SearchMode(rawValue: UserDefaults.standard.string(forKey: "searchMode") ?? "exact") ?? .exact }
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
        self.signature = "\(modelName)-\(dimension)"
    }

    func embed(_ text: String) -> [Float] { run(text, task: .doc) }
    func embed(_ text: String, query: Bool) -> [Float] { run(text, task: query ? .qry : .doc) }

    private func run(_ text: String, task: Task) -> [Float] {
        var ids = tokenizer.encode(text).map { Int32($0) }
        if ids.count > maxLen { ids = Array(ids.prefix(maxLen - 1)) + [ids[ids.count - 1]] }
        let len = ids.count
        guard let idArr = try? MLMultiArray(shape: [1, NSNumber(value: len)], dataType: .int32),
              let maskArr = try? MLMultiArray(shape: [1, NSNumber(value: len)], dataType: .int32),
              let taskArr = try? MLMultiArray(shape: [1], dataType: .int32) else {
            return [Float](repeating: 0, count: dimension)
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
            NSLog("Ditto OgmaEmbedder: prediction failed (ids=\(ids.prefix(8))): \(error)")
            return [Float](repeating: 0, count: dimension)
        }
        guard let emb = out.featureValue(for: "embedding")?.multiArrayValue else {
            NSLog("Ditto OgmaEmbedder: no 'embedding' output; features=\(out.featureNames)")
            return [Float](repeating: 0, count: dimension)
        }
        var v = [Float](repeating: 0, count: emb.count)
        for i in 0..<emb.count { v[i] = emb[i].floatValue }
        if DebugLog.enabled {
            NSLog("Ditto OgmaEmbedder: ids=\(ids.prefix(8)) len=\(len) embCount=\(emb.count) dtype=\(emb.dataType.rawValue) v0..2=\(v.prefix(3))")
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
        if let name = level.modelName,
           let modelURL = Bundle.main.url(forResource: name, withExtension: "mlmodelc"),
           let tokFolder = Bundle.main.url(forResource: "\(name)-tokenizer", withExtension: nil),
           let model = try? MLModel(contentsOf: modelURL),
           let tokenizer = OgmaTokenizer(folder: tokFolder) {
            active = OgmaEmbedder(modelName: name, model: model, tokenizer: tokenizer,
                                  dimension: level.dimension)
        } else {
            if level != .off { NSLog("Ditto: embedder unavailable for \(level.rawValue) — using fallback") }
            active = HashingEmbedder()
        }
        return active.signature != before
    }

    /// Configure for `level`, then reprocess only the entries not already in the
    /// active model's space. Skipped entirely for the `off` tier, whose substring
    /// search doesn't use vectors — so we don't churn embeddings needlessly.
    static func configureAndReindex(level: DeepSearchLevel, store: ClipStore) {
        configure(level: level)
        if level != .off { store.reindexStale() }
    }
}

// MARK: - Preset tag taxonomy (100 tags)

@MainActor
enum TagSpace {
    /// 100 fixed content tags. Index in this array is the stable tag id.
    static let names: [String] = [
        "source code", "error message", "stack trace", "log line", "shell command",
        "terminal output", "git commit", "git diff", "python code", "javascript code",
        "swift code", "html markup", "css style", "sql query", "json data",
        "yaml config", "xml document", "markdown text", "regular expression", "api endpoint",
        "url link", "email address", "phone number", "postal address", "person name",
        "company name", "product name", "date", "time", "number",
        "currency amount", "percentage", "math equation", "uuid", "hash digest",
        "base64 blob", "ip address", "domain name", "file path", "directory path",
        "environment variable", "api key", "access token", "password", "username",
        "configuration", "dependency", "package version", "changelog", "license text",
        "legal clause", "contract term", "invoice", "receipt", "order number",
        "tracking number", "flight booking", "hotel booking", "meeting invite", "calendar event",
        "deadline", "reminder", "task item", "todo note", "project name",
        "ticket id", "issue report", "bug report", "feature request", "design note",
        "color value", "hex color", "font name", "image caption", "alt text",
        "translation", "quotation", "citation", "bibliography reference", "question",
        "answer", "definition", "instruction", "recipe", "ingredient list",
        "measurement", "coordinate", "country", "city", "language",
        "greeting", "signature", "title heading", "bullet list", "table data",
        "csv row", "spreadsheet cell", "math formula", "chemical formula", "miscellaneous text"
    ]

    static var count: Int { names.count }

    /// Tag vectors in the active embedder's space, cached per embedder signature
    /// (two models can share a dimension but live in different spaces).
    private static var cache: (String, [[Float]])?

    static func vectors(using embedder: TextEmbedder) -> [[Float]] {
        if let (sig, v) = cache, sig == embedder.signature { return v }
        let v = names.map { embedder.embed($0) }
        cache = (embedder.signature, v)
        return v
    }

    /// Top-K nearest tag ids for an entry vector.
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
}

// MARK: - Ingest indexing

@MainActor
enum ClipIndexer {
    /// Compute and attach the entry's vector + top-5 tag ids using the active
    /// embedder. Entries are documents, so use the DOC task token.
    static func index(_ item: ClipItem) {
        let embedder = EmbedderProvider.active
        let vec = embedder.embed(SemanticRanker.searchText(item))
        item.vector = vec
        item.tagIDs = TagSpace.classify(vec, embedder: embedder, topK: 5)
        item.vectorModel = embedder.signature
    }

    /// True when the clip still needs (re)processing for the active embedder.
    static func isStale(_ item: ClipItem) -> Bool {
        item.vector == nil || item.vectorModel != EmbedderProvider.active.signature
    }
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
        for i in a.indices { dot += a[i] * b[i] }
        return dot // inputs L2-normalised
    }

    /// Essence search: full query·item cosine, best-first, thresholded.
    static func essence(query: String, items: [ClipItem], embedder: TextEmbedder) -> [ClipItem] {
        let qv = embedder.embed(query, query: true)
        let q = query.lowercased()
        let scored = items.map { item -> (ClipItem, Float) in
            let vec = item.vector ?? embedder.embed(searchText(item))
            let substring = searchText(item).lowercased().contains(q)
            return (item, (substring ? 1 : 0) + cosine(qv, vec))
        }
        let kept = scored.filter { $0.1 >= 0.12 }.sorted { $0.1 > $1.1 }
        return (kept.isEmpty ? scored.sorted { $0.1 > $1.1 }.prefix(min(items.count, 12)).map { ($0.0, $0.1) }
                             : kept).map { $0.0 }
    }
}
