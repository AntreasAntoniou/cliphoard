import Foundation
import CoreML
import Accelerate
import Tokenizers

// MARK: - Levels & modes

/// Embedding model tier (selects which on-device model produces vectors).
/// Until a CoreML model is bundled for a tier, the engine falls back to the
/// dependency-free `HashingEmbedder` so everything still works.
/// Search tiers. Every model here is permissively licensed — MIT or Apache-2.0 —
/// so the shipped artifact carries no use restrictions beyond Cliphoard's own MIT.
///
/// A `max` tier backed by google/embeddinggemma-300m was removed deliberately.
/// Not for quality: it was simply the only component under a licence (the Gemma
/// Terms of Use, with a prohibited-use policy) that a recipient of an "MIT app"
/// would not expect, and hosting its weights for download made this project their
/// redistributor. `DeepSearch.level` migrates anyone who had selected it to `high`.
enum DeepSearchLevel: String, CaseIterable, Identifiable {
    case off, low, normal, high
    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:    return "Off"
        case .low:    return "Low (open-ogma-micro)"
        case .normal: return "Normal (open-ogma-small)"
        case .high:   return "High (MiniLM)"
        }
    }

    /// Bundled CoreML model name (`<name>.mlmodelc`) for this tier.
    /// - low → axiotic/open-ogma-micro (MIT, 2.5M)
    /// - normal → axiotic/open-ogma-small (MIT, 8.9M)
    /// - high → sentence-transformers/all-MiniLM-L6-v2 (Apache-2.0, 22.7M)
    var modelName: String? {
        switch self {
        case .off:    return nil
        case .low:    return "open-ogma-micro"
        case .normal: return "open-ogma-small"
        case .high:   return "all-MiniLM-L6-v2"
        }
    }

    /// Output embedding dimension for each tier's model. The ogma tiers follow
    /// the selected `VectorDetail` head (1024-d proj_large by default); the HF
    /// tiers have fixed heads.
    var dimension: Int {
        switch self {
        case .off:    return 256
        case .low, .normal: return DeepSearch.detail.dimension
        case .high:   return 384
        }
    }

    /// True for tiers served by an ogma model (task tokens, OgmaTokenizer,
    /// VectorDetail head selection). The HF tiers use HFEmbedder + prompts.
    var isOgma: Bool { self == .low || self == .normal }

    /// Fixed task prompts for asymmetric HF models. Empty for every shipped tier:
    /// MiniLM is symmetric. Kept as a seam because `HFEmbedder` takes both prefixes
    /// and a future asymmetric tier would set them here rather than in the embedder.
    var queryPrefix: String { "" }
    var docPrefix: String { "" }

    /// Calibrated relevance floor for the HF tiers (noise p95 measured on the
    /// local validation set: 0.169 MiniLM — see tools/BENCHMARKS.md).
    var hfRelevanceFloor: Float { 0.20 }
}

/// Which projection head of the open-ogma models drives search. The converted
/// CoreML packages emit BOTH heads on every prediction (the trunk dominates the
/// cost), so switching is just reading a different output — but vectors cached
/// under one head aren't comparable to the other, so a switch re-indexes (the
/// per-model cache keeps a round-trip free).
enum VectorDetail: String, CaseIterable, Identifiable {
    /// 1024-d proj_large head (distilled from bge-large-en-v1.5). The default:
    /// best retrieval quality AND the better-calibrated cosine space (validated
    /// noise-floor p95 ≈ 0.40 vs 0.56 for the 384 head — see tools/validate_models.py).
    case full1024
    /// 384-d proj_small head (distilled from bge-small-en-v1.5): ~2.7× smaller
    /// stored vectors, slightly weaker ranking.
    case compact384

    var id: String { rawValue }

    var title: String {
        switch self {
        case .full1024:   return "Full (1024-d, best)"
        case .compact384: return "Compact (384-d, lighter)"
        }
    }

    var dimension: Int { self == .full1024 ? 1024 : 384 }

    /// CoreML output name in the converted open-ogma packages.
    var outputName: String { self == .full1024 ? "embedding_large" : "embedding" }

    /// Minimum query·clip cosine the thresholded modes treat as "related", per
    /// head — the two heads live in differently-calibrated spaces (measured on
    /// the local validation set: gold-vs-noise separation).
    var relevanceFloor: Float { self == .full1024 ? 0.40 : 0.58 }
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
        //
        // "max" (the retired EmbeddingGemma tier) migrates to `high`, NOT to the
        // `?? .normal` fallback: someone who deliberately picked the largest model
        // should land on the next-largest, not be dropped two tiers silently. The
        // stored value is left alone so this stays a read-time reinterpretation —
        // the vectors under the old signature are simply stale and get re-indexed.
        get {
            let stored = UserDefaults.standard.string(forKey: "deepSearchLevel") ?? "normal"
            if stored == "max" { return .high }
            return DeepSearchLevel(rawValue: stored) ?? .normal
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "deepSearchLevel") }
    }
    static var mode: SearchMode {
        // Default to Smart (exact hits first, then by meaning) — deterministic AND
        // discoverable. Legacy "essence" values fall through to this.
        get { SearchMode(rawValue: UserDefaults.standard.string(forKey: "searchMode") ?? "smart") ?? .smart }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "searchMode") }
    }
    static var detail: VectorDetail {
        // Default to the full 1024-d head — strongest retrieval, best-separated space.
        get { VectorDetail(rawValue: UserDefaults.standard.string(forKey: "vectorDetail") ?? "full1024") ?? .full1024 }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "vectorDetail") }
    }
}

// MARK: - Embedding

protocol TextEmbedder {
    var dimension: Int { get }
    /// Stable identity of this embedder ("hashing-256", "open-ogma-small-1024-v1",
    /// …). Stored vectors / tag vectors are only comparable within one signature.
    var signature: String { get }
    /// Minimum query·clip cosine the thresholded search modes treat as related.
    /// Embedding spaces calibrate differently (the open-ogma heads sit far apart),
    /// so the floor travels with the embedder instead of being a global constant.
    var relevanceFloor: Float { get }
    /// Embed a document/symmetric text.
    func embed(_ text: String) -> [Float]
    /// Embed, distinguishing a query from a document (asymmetric models use the
    /// QRY vs DOC task token). Defaults to the document path.
    func embed(_ text: String, query: Bool) -> [Float]
}

extension TextEmbedder {
    func embed(_ text: String, query: Bool) -> [Float] { embed(text) }
    /// Historical default, matching the hashing space's calibration.
    var relevanceFloor: Float { 0.20 }
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
    let relevanceFloor: Float
    private let model: MLModel
    private let tokenizer: OgmaTokenizer
    /// Which CoreML output carries the selected head ("embedding_large" for the
    /// 1024-d proj_large, "embedding" for the 384-d proj_small).
    private let outputName: String
    private let maxLen = 256

    private enum Task: Int32 { case qry = 4, doc = 5, sym = 6 }

    init(modelName: String, model: MLModel, tokenizer: OgmaTokenizer, dimension: Int,
         outputName: String = "embedding", relevanceFloor: Float = 0.20) {
        self.model = model
        self.tokenizer = tokenizer
        self.dimension = dimension
        self.outputName = outputName
        self.relevanceFloor = relevanceFloor
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
        // Prefer the selected head; fall back to the classic single "embedding"
        // output so an older single-head package still works.
        guard let emb = (out.featureValue(for: outputName)
                         ?? out.featureValue(for: "embedding"))?.multiArrayValue else {
            NSLog("Cliphoard OgmaEmbedder: no '\(outputName)' output; features=\(out.featureNames)")
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

    /// Monotonic token: bumping it invalidates any in-flight async model load,
    /// so a rapid tier flip can't have a stale load overwrite the newer one.
    private static var loadToken = 0

    /// Load the embedder for `level`. Resolution is bundle → local store →
    /// AUTO-DOWNLOAD (ModelAssets.ensure): selecting a tier IS the install —
    /// the user never fetches models by hand. A bundled/stored ogma model loads
    /// synchronously (small files); everything else loads async — `active`
    /// serves hashing meanwhile and swaps when ready, then `onSwap` fires so the
    /// store can re-index into the new space. Lifecycle (loading / downloading
    /// N% / installing / failed) is published via EmbedderState for Settings.
    @discardableResult
    static func configure(level: DeepSearchLevel, onSwap: (() -> Void)? = nil) -> Bool {
        let before = active.signature
        loadToken &+= 1
        let token = loadToken
        guard let name = level.modelName else {          // .off
            active = HashingEmbedder()
            EmbedderState.shared.set(.fallback)
            return active.signature != before
        }
        // Fast path: an ogma model already on disk loads synchronously.
        // OgmaTokenizer implements ONLY ogma's tokenizer (metaspace + offset);
        // the HF tiers go through swift-transformers below.
        if level.isOgma, name.contains("ogma"), let found = ModelAssets.locate(name),
           let model = try? MLModel(contentsOf: found.compiledModel),
           let tokenizer = OgmaTokenizer(folder: found.tokenizerFolder) {
            let detail = DeepSearch.detail
            active = OgmaEmbedder(modelName: name, model: model, tokenizer: tokenizer,
                                  dimension: detail.dimension,
                                  outputName: detail.outputName,
                                  relevanceFloor: detail.relevanceFloor)
            EmbedderState.shared.set(.ready(signature: active.signature))
            return active.signature != before
        }
        // Async path: HF tiers, and any tier whose model needs downloading.
        active = HashingEmbedder()
        EmbedderState.shared.set(.loading(name))
        Task { @MainActor in
            do {
                let found = try await ModelAssets.ensure(name)   // may download+compile
                guard token == loadToken else { return }         // superseded
                EmbedderState.shared.set(.loading(name))
                let model = try await MLModel.load(contentsOf: found.compiledModel,
                                                   configuration: MLModelConfiguration())
                guard token == loadToken else { return }
                if level.isOgma {
                    guard let tokenizer = OgmaTokenizer(folder: found.tokenizerFolder) else {
                        throw CocoaError(.fileReadCorruptFile, userInfo: [
                            NSLocalizedDescriptionKey: "tokenizer unreadable (\(name))"])
                    }
                    let detail = DeepSearch.detail
                    active = OgmaEmbedder(modelName: name, model: model, tokenizer: tokenizer,
                                          dimension: detail.dimension,
                                          outputName: detail.outputName,
                                          relevanceFloor: detail.relevanceFloor)
                } else {
                    let tokenizer = try await AutoTokenizer.from(modelFolder: found.tokenizerFolder)
                    guard token == loadToken else { return }
                    active = HFEmbedder(modelName: name, model: model, tokenizer: tokenizer,
                                        dimension: level.dimension,
                                        queryPrefix: level.queryPrefix,
                                        docPrefix: level.docPrefix,
                                        relevanceFloor: level.hfRelevanceFloor)
                }
                EmbedderState.shared.set(.ready(signature: active.signature))
                onSwap?()
            } catch {
                NSLog("Cliphoard: \(name) unavailable (\(error)) — staying on fallback")
                guard token == loadToken else { return }
                EmbedderState.shared.set(.failed(name, message: error.localizedDescription))
            }
        }
        return active.signature != before
    }

    /// Configure for `level`, then reprocess only the entries not already in the
    /// active model's space. Skipped entirely for the `off` tier, whose substring
    /// search doesn't use vectors — so we don't churn embeddings needlessly.
    /// For the async HF tiers, the re-index re-runs once the real model swaps in.
    static func configureAndReindex(level: DeepSearchLevel, store: ClipStore) {
        configure(level: level) { [weak store] in store?.refreshForActiveModel() }
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

    /// Minimum tag-name cosine required for automatic assignment. Persisted so
    /// users can calibrate it against their own clipboard distribution.
    static var assignmentThreshold: Float {
        get {
            guard UserDefaults.standard.object(forKey: "tagAssignmentThreshold") != nil else { return 0.28 }
            return Float(UserDefaults.standard.double(forKey: "tagAssignmentThreshold"))
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: "tagAssignmentThreshold") }
    }

    // The confidence floor τ for automatic tag assignment (spec §5) IS
    // `assignmentThreshold` above — already tunable and already wired to the
    // Settings "Confidence floor" slider. Assignment and query classification
    // share that one knob; there is deliberately no second `tagTau` config.

    /// The cosine floor a classification call should actually use. An explicit
    /// positive `tau` (the clip-assignment path) wins; `tau == 0` — every legacy
    /// caller, including the query side — keeps the historical
    /// `assignmentThreshold` behaviour unchanged.
    private static func confidenceFloor(_ tau: Float) -> Float { tau > 0 ? tau : assignmentThreshold }

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
    ///
    /// `tau > 0` (the clip-assignment path) gates on that confidence floor; the
    /// default 0 leaves every existing caller on the historical threshold.
    static func classify(_ vector: [Float], embedder: TextEmbedder,
                         topK: Int = 5, tau: Float = 0) -> [Int] {
        guard !vector.isEmpty else { return [] }
        let bar = confidenceFloor(tau)
        let tagVecs = vectors(using: embedder)
        let scored = tagVecs.enumerated().map { ($0.offset, SemanticRanker.cosine(vector, $0.element)) }
        return scored
            .filter { $0.1 >= bar }
            .sorted { $0.1 > $1.1 }
            .prefix(topK)
            .map { $0.0 }
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

    /// Topical tail of the active hybrid basket. Axis ranges end before this.
    static var topicalRange: Range<Int> { TagBaskets.active.topicalRange }

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
    ///
    /// Confidence-gated: an axis whose own argmax sits below `tau` contributes NO
    /// tag, so a clip is only placed on the axes it actually has an opinion about.
    static func classifyDimensions(_ vector: [Float], embedder: TextEmbedder,
                                   tau: Float = 0) -> [Int] {
        guard !vector.isEmpty, isDimensional else { return [] }
        let bar = confidenceFloor(tau)
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
            return bestScore >= bar ? best : nil
        }
    }

    /// Nearest topical ids only, excluding axis words — cosine is computed over
    /// the active basket's `topicalRange` alone, so axis vocabulary can never win
    /// a topical slot. Hybrid ingest uses this alongside confidence-gated
    /// per-axis classification: a clip carries thresholded axis tags PLUS a
    /// thresholded nearest-few from the topical tail.
    static func classifyTopical(_ vector: [Float], embedder: TextEmbedder,
                                topK: Int = 3, tau: Float = 0) -> [Int] {
        guard !vector.isEmpty, !topicalRange.isEmpty else { return [] }
        let bar = confidenceFloor(tau)
        let tagVecs = vectors(using: embedder)
        return topicalRange
            .map { ($0, SemanticRanker.cosine(vector, tagVecs[$0])) }
            .filter { $0.1 >= bar }
            .sorted { $0.1 > $1.1 }
            .prefix(topK)
            .map { $0.0 }
    }

    /// The facet labels for a set of tag ids ("Artifact: diff", …), in dimension
    /// order. For display of a clip's cube coordinates. Empty when the active
    /// basket has no axes left (General), which is now the default.
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
        // Fail closed, and do it HERE as well as in `ClipStore.add`: §3.11 says a
        // sensitive clip is out of the embedding index entirely, and this function
        // is also reachable from the background re-index / reclassify passes. One
        // guard at the single point that calls `embed` is what makes "a secret is
        // never sent through the model" true of every caller, present and future.
        guard !item.isIndexVetoed else { return }
        let embedder = EmbedderProvider.active
        let vec = embedder.embed(SemanticRanker.searchText(item))
        // Don't cache a failed/degenerate embedding — leave the clip stale so it's
        // retried, rather than poisoning its tags/search permanently.
        guard isUsable(vec, dimension: embedder.dimension) else { return }
        item.embeddings[embedder.signature] = ModelEmbedding(vector: vec)
    }

    /// A clip's tag ids for the active basket: for a facet cube, the confident
    /// value on each axis PLUS a thresholded nearest-few from the topical tail;
    /// for a flat pool, the nearest five. Both feed the same `tagIndex`, so the
    /// store's O(1) lookup is agnostic to which shape is used.
    ///
    /// This is the ASSIGNMENT path; the default (`tau == 0`) calls gate on the
    /// tunable `TagSpace.assignmentThreshold` confidence floor, so a clip that
    /// matches nothing confidently ends up with no tags rather than the
    /// least-bad argmax.
    static func tags(for vector: [Float], embedder: TextEmbedder) -> [Int] {
        if TagSpace.isDimensional {
            return TagSpace.classifyDimensions(vector, embedder: embedder)
                + TagSpace.classifyTopical(vector, embedder: embedder, topK: 3)
        }
        return TagSpace.classify(vector, embedder: embedder, topK: 5)
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
        // Recognised image text, when there is any. This ONE case is the entire search
        // integration for images: the embedder, `Detectors.scan`, `lengthConfidence`
        // and all three ranking modes already route through here, so images become
        // first-class in the existing pipeline rather than needing a parallel index,
        // a fusion weight, or a search mode.
        //
        // The empty-string fallback is load-bearing, not defensive. A clip whose
        // recognised text was WITHHELD stores "" (see ClipItem.ocrText), so it falls
        // back to the caption — meaning a screenshot holding a secret reads exactly as
        // it did before this feature existed, everywhere, without a single reader
        // knowing the withhold rule. `nil` (not yet analysed) behaves the same way.
        case .image: return item.ocrText.flatMap { $0.isEmpty ? nil : $0 } ?? item.text
        default:     return item.text
        }
    }

    /// The ONLY sanctioned way to obtain a clip's vector for RANKING. Cache first,
    /// then the veto, then the model.
    ///
    /// Every ranking mode needs this exact sequence, and each used to carry its own
    /// copy. That is how the veto was defeated once already: the modes fell back to
    /// `embedder.embed(searchText(item))` unguarded, so instead of a secret passing
    /// through the model once at capture it passed through on EVERY keystroke. Three
    /// copies of a rule means a fourth mode has to remember it.
    ///
    /// Deliberately a FUNCTION rather than a "vetted text" wrapper type whose private
    /// initialiser would make a forgotten guard a compile error. `isIndexVetoed` is
    /// computed over `flags`, which is a `var` and DOES change after capture — the
    /// image-understanding pass unions into it. A wrapper value proves a fact about
    /// one instant; carried across a suspension point while the flags move, it is a
    /// stale proof that still type-checks. Reading the predicate here, at the moment
    /// of use, has no such window.
    ///
    /// Note this is the READ path. `ClipIndexer.index` keeps its own `guard`, which is
    /// a different shape — it refuses to PRODUCE a vector, rather than substituting an
    /// empty one for ranking. Collapsing the two would lose that distinction.
    static func rankingVector(for item: ClipItem, embedder: TextEmbedder) -> [Float] {
        if let cached = item.embeddings[embedder.signature]?.vector { return cached }
        guard !item.isIndexVetoed else { return [] }
        return embedder.embed(searchText(item))
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return dot // inputs L2-normalised → dot == cosine
    }

    /// How much to trust a clip's cosine, from its text length. Ultra-short
    /// clips ("c", "ok", "styled") mean-pool over almost no content tokens, so
    /// their vectors collapse toward the space's generic center and sit ~0.43
    /// from EVERYTHING (measured: "fun" vs 1-char junk ≈ 0.41–0.54, vs real
    /// unrelated docs ≈ 0.13–0.30) — classic hubness. Shrinking their cosines
    /// keeps them out of the thresholded modes unless nothing better exists
    /// (the top-K fallback still shows them for genuinely short-hit searches).
    /// Ramps linearly to full trust at 12 chars; query side is never discounted.
    static func lengthConfidence(_ item: ClipItem) -> Float {
        min(1, Float(searchText(item).count) / 12)
    }

    /// Essence search: full query·item cosine, best-first, thresholded.
    static func essence(query: String, items: [ClipItem], embedder: TextEmbedder) -> [ClipItem] {
        let qv = embedder.embed(query, query: true)
        let q = query.lowercased()
        let scored = items.map { item -> (ClipItem, Float) in
            let vec = rankingVector(for: item, embedder: embedder)
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
            let vec = rankingVector(for: item, embedder: embedder)
            // Confidence-weighted: hub vectors from ultra-short clips must not
            // clear the floor on their unreliable ~0.4 ambient cosine.
            return (item, cosine(qv, vec) * lengthConfidence(item))
        }
        let kept = scored.filter { $0.1 >= embedder.relevanceFloor }.sorted { $0.1 > $1.1 }
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
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let qv = embedder.embed(query, query: true)
        // The query's nearest preset categories — the "tag" leg of the hybrid.
        let queryTags = Set(TagSpace.classify(qv, embedder: embedder, topK: 3))
        let queryTagNames = Set(queryTags.compactMap {
            TagSpace.names.indices.contains($0) ? TagSpace.names[$0] : nil
        })

        let scored = items.map { item -> (item: ClipItem, score: Float, exact: Bool) in
            let emb = item.embeddings[embedder.signature]
            // Vetoed clips still match by exact substring; they just cannot rank
            // semantically. The veto is about the MODEL, not about retrieval.
            // See `rankingVector`, which is the only place that rule now lives.
            let vec = rankingVector(for: item, embedder: embedder)
            let exact = searchText(item).lowercased().contains(q)
            // Confidence-weighted neural leg (see lengthConfidence): an
            // ultra-short clip's cosine AND its vector-derived tags are both
            // unreliable, so the whole semantic contribution is shrunk. Exact
            // substring hits are untouched — they don't rely on the vector.
            let confidence = lengthConfidence(item)
            let neural = cosine(qv, vec) * confidence
            // Derived, not read from storage — the ids are a view of the vector.
            let itemTags: [Int] = emb.map { ClipIndexer.tags(for: $0.vector, embedder: embedder) } ?? []
            let shared = Set(itemTags).intersection(queryTags).count
            let tagBoost = Float(min(shared, 2)) * 0.10 * confidence  // up to +0.20 for topic agreement
            let userTagMatch = item.userTags.contains { $0 == q || queryTagNames.contains($0) }
            let userTagBoost: Float = userTagMatch ? 3.0 : 0
            let exactScore: Float = exact ? 10 : 0
            let score: Float = exactScore + neural + tagBoost + userTagBoost
            return (item, score, exact)
        }
        // Keep every exact hit; keep the rest only when meaning OR shared topic
        // clears the embedder's calibrated floor (tagBoost can lift a same-topic
        // clip over it), so the list stays relevant instead of padded with noise.
        return scored
            .filter { $0.exact || $0.score >= embedder.relevanceFloor - 0.02 }
            .sorted { $0.score > $1.score }
            .map { $0.item }
    }

    // MARK: - Light-learning user-tag suggestions (spec §5.1)

    /// Stable key for one dismissed `(tag, clip)` suggestion pair. A dismissal is
    /// per-pair, not per-tag: saying "no, this clip isn't `invoices`" must not
    /// stop `invoices` being suggested for a different clip.
    static func dismissalKey(tag: String, clipID: UUID) -> String {
        tag + "\u{1}" + clipID.uuidString
    }

    /// Default separation a suggested tag must hold over the next-best candidate.
    ///
    /// WHY a margin at all: the real-clip audit (spec §1) measured absolute
    /// cosines clustering around ~0.35–0.42 for *every* axis, and scaling the
    /// model 34× (8.9M → 300M) left the top1−top2 margins **equal or worse**.
    /// An absolute floor alone therefore cannot separate "this really is
    /// `invoices`" from "this is equally close to `invoices` and `receipts`" —
    /// it just reproduces the coin flip in a new mechanism. The margin is the
    /// scale-free part of the signal: it survives re-calibration of the space,
    /// which the absolute floor does not. It is the primary gate; sigma is the
    /// secondary one.
    static let suggestionMargin: Float = 0.05

    /// Where the suggestion floor sits between a space's measured noise floor
    /// and a perfect 1.0. Chosen so the hashing space (`relevanceFloor` 0.20)
    /// lands on 0.44 — reproducing the historical hard-coded 0.45 — while the
    /// far stricter ogma 384 head (0.58) is pulled up to ~0.71 instead of
    /// inheriting a floor it would clear on pure ambient similarity.
    static let suggestionFloorFraction: Float = 0.30

    /// Suggestion floor derived from a space's search relevance floor.
    ///
    /// WHY not a constant: a cosine is only meaningful relative to the space it
    /// was measured in. `VectorDetail` already records that the ogma heads
    /// calibrate very differently (noise p95 ≈ 0.40 for 1024-d vs ≈ 0.58 for
    /// 384-d), and the HF tiers differ again (0.169 MiniLM, 0.256 Gemma). A
    /// fixed 0.45 is simultaneously too strict for the 1024-d head, roughly
    /// right for hashing, and *below the noise floor* for the 384-d head —
    /// i.e. in that space it would suggest tags on pure noise. Suggesting a
    /// durable label is a stronger claim than showing a search hit, so the
    /// floor sits well above the space's own relevance floor rather than at it.
    static func suggestionFloor(relevanceFloor: Float) -> Float {
        let base = min(max(relevanceFloor, 0), 0.99)
        return base + (1 - base) * suggestionFloorFraction
    }

    /// Best-effort calibration for an embedding space we only know by signature.
    ///
    /// The pure suggestion API is handed an `embedderSignature`, not a live
    /// embedder, so this recovers the space's relevance floor from the stable
    /// signature shape the embedders mint (`"\(modelName)-\(dimension)-v1"`,
    /// plus `"hashing-256"`), reusing `DeepSearchLevel`/`VectorDetail` as the
    /// single source of truth instead of duplicating constants. An unknown
    /// signature falls back to the hashing calibration — the historical
    /// behaviour — because guessing a *higher* floor for a space we cannot
    /// identify would silently switch suggestions off; the margin check is what
    /// keeps an uncalibrated space honest, and callers that hold a live
    /// embedder should pass `embedderRelevanceFloor` and skip the sniffing.
    static func calibratedRelevanceFloor(forSignature signature: String) -> Float {
        let hashingFloor: Float = 0.20
        guard let level = DeepSearchLevel.allCases.first(where: {
            guard let name = $0.modelName else { return false }
            return signature.hasPrefix(name + "-")
        }) else { return hashingFloor }
        guard level.isOgma else { return level.hfRelevanceFloor }
        // Ogma tiers emit whichever projection head VectorDetail selected; the
        // dimension in the signature is what says which space these vectors live in.
        let dimension = signature.split(separator: "-").compactMap { Int($0) }.last
        return dimension == VectorDetail.compact384.dimension
            ? VectorDetail.compact384.relevanceFloor
            : VectorDetail.full1024.relevanceFloor
    }

    /// Which of the user's OWN tags this clip probably belongs to.
    ///
    /// The "light learning" of spec §3.10/§5.1: no model is trained: once a user
    /// tag has been applied by hand enough times (`minApplies`), its members'
    /// vectors define a centroid — the empirical meaning of that label in this
    /// user's head — and a clip near that centroid is a candidate. Suggestions
    /// are surfaced, never auto-applied.
    ///
    /// A tag ships only if it clears **both** gates:
    ///  1. **Floor** — centroid cosine ≥ `sigma`, defaulting to a floor derived
    ///     from the space's own calibration (see `suggestionFloor`), not a
    ///     hard-coded constant.
    ///  2. **Margin** — it beats the NEXT-BEST candidate that also cleared the
    ///     floor by ≥ `margin`. Candidates are ranked and walked top-down; the
    ///     first pair that sits inside the margin is a confusable cluster, so
    ///     that tag *and everything below it* are dropped (fail closed: when we
    ///     cannot tell `invoices` from `receipts`, blank is the honest answer,
    ///     and nothing ranked below a confusable pair is more trustworthy than
    ///     the pair itself).
    ///
    /// DECISION — a lone candidate is still suggested. The bottom-ranked
    /// candidate has no next-best to be confused with, so it passes the margin
    /// gate by definition; in particular, if exactly one tag clears the floor it
    /// is suggested on the floor alone. This is deliberate: the margin measures
    /// *confusability between competing labels*, and with one label there is no
    /// competition — the user's own hand-applied evidence is the only hypothesis
    /// on the table. Note the comparison set is candidates that cleared the
    /// floor: a tag sitting just under sigma does not veto the winner, because
    /// it already failed the evidence bar on its own terms.
    ///
    /// Deliberately PURE and store-free: the index, the dismissal set and the
    /// calibration are passed in, so it is trivially unit-testable and has no
    /// `ClipStore`, `EmbedderProvider`, database or main-actor dependency.
    ///
    /// - Parameters:
    ///   - userTagIndex: tag → the clips that already carry it (`ClipStore.userTagIndex`).
    ///   - dismissed: `dismissalKey(tag:clipID:)` values the user has rejected.
    ///   - embedderSignature: only vectors from this space are comparable.
    ///   - minApplies: hand-applies required before a tag may form a centroid.
    ///   - embedderRelevanceFloor: the active embedder's `relevanceFloor`, when the
    ///     caller has one; otherwise it is recovered from `embedderSignature`.
    ///   - sigma: explicit absolute-cosine floor, overriding the calibration.
    ///   - margin: required separation over the next-best candidate.
    /// - Returns: at most three tags, strongest cosine first.
    static func suggestedUserTags(for clip: ClipItem,
                                  userTagIndex: [String: [ClipItem]],
                                  dismissed: Set<String>,
                                  embedderSignature: String,
                                  minApplies: Int = 4,
                                  embedderRelevanceFloor: Float? = nil,
                                  sigma: Float? = nil,
                                  margin: Float = suggestionMargin) -> [String] {
        guard let clipVector = clip.embeddings[embedderSignature]?.vector,
              !clipVector.isEmpty else { return [] }
        let carried = Set(clip.userTags)
        // Fail closed on nonsense knobs: a caller passing 0 applies, or a zero /
        // negative margin, must not end up with a *weaker* gate than the defaults
        // imply. A non-positive margin is precisely the absolute-floor-only gate
        // the audit condemned, so it falls back to the default rather than
        // switching the confusability check off.
        let requiredApplies = max(1, minApplies)
        let requiredMargin = margin > 0 ? margin : suggestionMargin
        let floor = sigma ?? suggestionFloor(
            relevanceFloor: embedderRelevanceFloor
                ?? calibratedRelevanceFloor(forSignature: embedderSignature))

        var candidates: [(tag: String, score: Float)] = []
        for (tag, members) in userTagIndex {
            // Evidence gate FIRST, before any vector work: a 1–2 sample tag must
            // never even form a centroid. A centroid over one clip is just that
            // clip, so it would score ~1.0 against its own neighbourhood and
            // sail past every downstream check — the cheapest way to poison the
            // suggestion list is to let a single accidental hand-apply become a
            // "learned" label.
            // DISMISSED tags are deliberately still SCORED (and filtered only at
            // the offering step below): excluding them at candidacy let a
            // confusable twin be promoted the instant its partner was dismissed —
            // "no, not `invoices`" would quietly become "how about `receipts`?".
            // A dismissal is a judgement about the CONCEPT, so it must still be
            // able to veto its near-twin.
            //
            // CARRIED tags are excluded outright: the user has already resolved
            // that label for this clip, so a second, related label is additional
            // information rather than confusion — and counting it would suppress
            // almost every suggestion on any clip that already has a strong tag.
            guard members.count >= requiredApplies, !carried.contains(tag) else { continue }
            // Members embedded in another space (or not yet embedded) simply
            // don't vote — they can't be compared to this clip's vector.
            let vectors = members.compactMap { $0.embeddings[embedderSignature]?.vector }
                .filter { $0.count == clipVector.count }
            // …and the same evidence bar applies to the votes that actually
            // count: 4 applies of which only 1 is comparable here is 1 sample of
            // evidence in THIS space, not 4. Still before the centroid is built.
            guard vectors.count >= requiredApplies else { continue }

            var centroid = [Float](repeating: 0, count: clipVector.count)
            for v in vectors {
                for i in 0..<centroid.count { centroid[i] += v[i] }
            }
            let n = Float(vectors.count)
            for i in 0..<centroid.count { centroid[i] /= n }
            // The mean of unit vectors isn't itself a unit vector, and `cosine` is
            // a bare dot product — re-normalise so the comparison is a real cosine.
            let score = cosine(clipVector, HashingEmbedder.normalize(centroid))
            // Keep EVERY scored tag, including those under the floor. Filtering
            // by the floor here would let a sub-floor runner-up vanish before it
            // could veto a near-tied winner — reproducing the absolute-floor-only
            // gate the audit condemned. The floor is applied at acceptance.
            candidates.append((tag, score))
        }
        // Tag name breaks exact ties so the output is deterministic — dictionary
        // iteration order must never decide which label the user is shown.
        candidates.sort { $0.score == $1.score ? $0.tag < $1.tag : $0.score > $1.score }

        var accepted: [String] = []
        for (i, candidate) in candidates.enumerated() {
            // Confusability is measured against the true next-best tag, whether or
            // not that tag is itself offerable or above the floor.
            if i + 1 < candidates.count,
               candidate.score - candidates[i + 1].score < requiredMargin {
                break   // confusable with the next tag → this one and the rest are out
            }
            // Acceptance gates, applied only now: the absolute floor, and the
            // offerability filters (already on the clip / previously dismissed).
            guard candidate.score >= floor else { break }   // sorted: nothing below can pass
            guard !dismissed.contains(dismissalKey(tag: candidate.tag, clipID: clip.id)) else { continue }
            accepted.append(candidate.tag)
            if accepted.count == 3 { break }
        }
        return accepted
    }
}
