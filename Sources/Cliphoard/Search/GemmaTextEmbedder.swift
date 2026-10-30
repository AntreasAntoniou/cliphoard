import Foundation

/// Nonblocking bridge for legacy synchronous search callers. Cold requests return no
/// vector, queue serial inference, and notify the UI when ready. Indexing awaits
/// the same task explicitly; pending/failed vectors are never persisted.
final class GemmaTextEmbedder: TextEmbedder, @unchecked Sendable {
    let dimension: Int
    let signature: String
    let relevanceFloor: Float
    private let truncate: Bool
    private struct Key: Hashable { let text: String; let query: Bool }
    private struct Outcome { let vector: [Float]; var admissionRejected = false }
    private let lock = NSLock()
    private var cache: [Key: [Float]] = [:]
    private var pending: [Key: Task<Outcome, Never>] = [:]
    private let lane = EmbeddingInferenceLane()
    private var stopped = false
    private var cacheOrder: [Key] = []
    private let compute: @Sendable (String, Bool) async throws -> [Float]
    private let changed: @Sendable () -> Void
    private let close: @Sendable () async -> Void

    init(dimension: Int = 768, signature: String = GemmaMediaAssets.signature + "-text-prefix1024-v1",
         relevanceFloor: Float = 0.20, truncate: Bool = true, compute: @escaping @Sendable (String, Bool) async throws -> [Float],
         changed: @escaping @Sendable () -> Void,
         close: @escaping @Sendable () async -> Void = {}) {
        self.dimension = dimension; self.signature = signature
        self.relevanceFloor = relevanceFloor; self.truncate = truncate
        self.compute = compute; self.changed = changed; self.close = close
    }
    static func boundedText(_ text: String) -> String {
        var result = "", bytes = 0
        for scalar in text.unicodeScalars {
            let n = scalar.utf8.count
            if bytes + n > GemmaMediaEmbedder.maximumTextBytes { break }
            result.unicodeScalars.append(scalar); bytes += n
        }
        return result
    }
    func embed(_ text: String) -> [Float] { embed(text, query: false) }
    func embed(_ text: String, query: Bool) -> [Float] {
        let key = Key(text: truncate ? Self.boundedText(text) : text, query: query)
        lock.lock(); let value = cache[key]; lock.unlock()
        if let value { return value }
        _ = request(key)
        return []
    }
    func cachedDocument(_ text: String) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return cache[Key(text: truncate ? Self.boundedText(text) : text, query: false)] ?? []
    }
    func vector(_ text: String, query: Bool = false,
                admit: @escaping @MainActor @Sendable () async -> Bool = { true }) async -> [Float] {
        guard await admit() else { return [] }
        let key = Key(text: truncate ? Self.boundedText(text) : text, query: query)
        let first = await request(key, admit: admit, notify: false).value
        // A previous indexing generation may own the shared queued task. Its
        // refusal cannot reject a newly admitted caller for the same text.
        if first.admissionRejected, !Task.isCancelled, await admit() {
            return await request(key, admit: admit, notify: false).value.vector
        }
        return first.vector
    }
    func cancel() {
        lock.lock(); stopped = true
        let tasks = Array(pending.values); pending.removeAll(); cache.removeAll(); cacheOrder.removeAll()
        lock.unlock()
        tasks.forEach { $0.cancel() }
        Task { await close() }
    }
    private func request(_ key: Key, admit: @escaping @MainActor @Sendable () async -> Bool = { true }, notify: Bool = true) -> Task<Outcome, Never> {
        lock.lock(); defer { lock.unlock() }
        if stopped || key.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return Task { Outcome(vector: []) } }
        if let value = cache[key] { return Task { Outcome(vector: value) } }
        if let task = pending[key] { return task }
        // Bound pending work; reserve a slot for an interactive query. Cold callers
        // can retry on the next readiness update instead of allocating unbounded tasks.
        guard pending.count < (key.query ? 257 : 256) else { return Task { Outcome(vector: []) } }
        let task = Task.detached(priority: key.query ? .userInitiated : .utility) { [weak self, compute, dimension, lane] () -> Outcome in
            await lane.acquire(query: key.query)
            guard !Task.isCancelled, await admit() else { self?.complete(key, value: []); await lane.release(); return Outcome(vector: [], admissionRejected: true) }
            let value = (try? await compute(key.text, key.query)) ?? []
            guard !Task.isCancelled, value.count == dimension,
                  value.allSatisfy(\.isFinite), value.contains(where: { $0 != 0 }) else {
                self?.complete(key, value: [])
                await lane.release()
                return Outcome(vector: [])
            }
            self?.complete(key, value: value, notify: notify)
            await lane.release()
            return Outcome(vector: value)
        }
        pending[key] = task
        return task
    }
    private func complete(_ key: Key, value: [Float], notify: Bool = false) {
        lock.lock()
        pending[key] = nil
        let publish = !stopped && !value.isEmpty
        if publish {
            if cache[key] == nil { cacheOrder.append(key) }
            cache[key] = value
            if cacheOrder.count > 4096 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
        }
        lock.unlock()
        if publish && notify { changed() }
    }
}

/// A single neural operation at a time, with interactive queries ahead of queued
/// background documents/tags. Actor suspension never holds the UI thread.
private actor EmbeddingInferenceLane {
    private var occupied = false
    private var queries: [CheckedContinuation<Void, Never>] = []
    private var documents: [CheckedContinuation<Void, Never>] = []
    func acquire(query: Bool) async {
        if !occupied { occupied = true; return }
        await withCheckedContinuation { continuation in
            if query { queries.append(continuation) } else { documents.append(continuation) }
        }
    }
    func release() {
        if !queries.isEmpty { queries.removeFirst().resume() }
        else if !documents.isEmpty { documents.removeFirst().resume() }
        else { occupied = false }
    }
}
