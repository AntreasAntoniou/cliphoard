import AppKit
import Combine

/// Owns the clipboard history: persistence, dedup, pinning, search and limits.
@MainActor
final class ClipStore: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    /// The id of the clip most recently added or bumped — lets the bar scroll to
    /// reveal it wherever it lands in the (pinned-first) order.
    @Published private(set) var lastAddedID: UUID?

    /// Inverted index tag-id → entries, for O(1) "tag search" retrieval without
    /// any query-time embedding or per-item dot products.
    private(set) var tagIndex: [Int: [ClipItem]] = [:]

    /// Live progress of a background (re)indexing pass, or nil when idle.
    @Published private(set) var indexing: IndexingProgress?

    struct IndexingProgress {
        var done: Int
        var total: Int
        /// Estimated seconds remaining (from the observed per-item rate).
        var etaSeconds: Double?
        var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    }

    /// Maximum number of unpinned items kept (0 = unlimited). Pinned items are
    /// always kept regardless.
    var historyLimit: Int {
        get { UserDefaults.standard.object(forKey: "historyLimit") as? Int ?? 200 }
        set { UserDefaults.standard.set(newValue, forKey: "historyLimit"); trim() }
    }

    private let dir: URL
    private let indexURL: URL

    /// - Parameter directory: storage location. Defaults to
    ///   `~/Library/Application Support/Ditto`; tests inject a temp directory.
    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ditto", isDirectory: true)
        dir = base
        indexURL = dir.appendingPathComponent("history.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    /// Directory where binary payloads (images) live.
    var storeDirectory: URL { dir }

    // MARK: Mutations

    func add(_ item: ClipItem) {
        // Drop a consecutive duplicate, but bump it to the front instead.
        if let existing = items.first(where: { $0.signature == item.signature }) {
            existing.lastUsedAt = Date()
            move(existing, toFront: true)
            lastAddedID = existing.id
            save()
            return
        }
        // Embed + tag at ingest (for the active model) so semantic search is
        // ready immediately. Skipped in the `off` tier, which uses no vectors.
        if DeepSearch.level != .off && ClipIndexer.isStale(item) { ClipIndexer.index(item) }
        items.insert(item, at: 0)
        trim()
        // Keep the pinned-first / recency order consistent with every other path
        // (togglePin, load, move) so a fresh copy doesn't briefly jump ahead of
        // pinned items only to be reordered on the next mutation.
        sortStable()
        rebuildTagIndex()
        lastAddedID = item.id
        save()
        Feedback.playCapture()
    }

    /// Entries pre-classified under a preset tag — O(1) lookup, no dot products.
    func items(taggedWith tagID: Int) -> [ClipItem] { tagIndex[tagID] ?? [] }

    private func rebuildTagIndex() {
        let sig = EmbedderProvider.active.signature
        var index: [Int: [ClipItem]] = [:]
        for item in items {
            for tag in item.embeddings[sig]?.tags ?? [] { index[tag, default: []].append(item) }
        }
        tagIndex = index
    }

    /// Point the store at the now-active model: rebuild the tag index for its
    /// cached tags and fill in any clips it hasn't embedded yet.
    func refreshForActiveModel() {
        rebuildTagIndex()
        reindexStale()
    }

    /// Embed only the entries the active model hasn't processed yet (a clip the
    /// model already embedded — e.g. on a round-trip model switch — is skipped).
    /// Runs in the background, yields between items so the UI stays responsive,
    /// and is resumable — an interrupted pass leaves the rest for next time.
    func reindexStale() {
        let stale = items.filter { ClipIndexer.isStale($0) }
        guard !stale.isEmpty else { return }
        let total = stale.count
        let started = Date()
        indexing = IndexingProgress(done: 0, total: total, etaSeconds: nil)
        Task { @MainActor in
            var done = 0
            for item in stale {
                ClipIndexer.index(item)
                done += 1
                // Publish progress + reveal new tags every few items.
                if done % 8 == 0 || done == total {
                    let elapsed = Date().timeIntervalSince(started)
                    let eta = done > 0 ? elapsed / Double(done) * Double(total - done) : nil
                    indexing = IndexingProgress(done: done, total: total, etaSeconds: eta)
                    rebuildTagIndex()
                    await Task.yield()
                }
            }
            rebuildTagIndex()
            save()
            indexing = nil
            DebugLog.write("reindexed \(done) stale items → \(EmbedderProvider.active.signature)")
        }
    }

    func togglePin(_ item: ClipItem) {
        item.pinned.toggle()
        // Keep pinned items grouped toward the front for predictability.
        sortStable()
        save()
    }

    func delete(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
        if let f = item.payloadFile {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
        rebuildTagIndex()
        save()
    }

    /// Clear everything that is not pinned.
    func clearUnpinned() {
        let removed = items.filter { !$0.pinned }
        items.removeAll { !$0.pinned }
        for item in removed {
            if let f = item.payloadFile {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
            }
        }
        rebuildTagIndex()
        save()
    }

    func markUsed(_ item: ClipItem) {
        item.lastUsedAt = Date()
        item.useCount += 1
        move(item, toFront: true)
        save()
    }

    // MARK: Querying

    func filtered(kind: ClipKind?, query: String, pinnedOnly: Bool) -> [ClipItem] {
        var result = items
        if pinnedOnly { result = result.filter { $0.pinned } }
        if let kind { result = result.filter { $0.kind == kind } }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            result = result.filter {
                $0.text.lowercased().contains(q)
                || ($0.filePath?.lowercased().contains(q) ?? false)
                || ($0.colorHex?.lowercased().contains(q) ?? false)
            }
        }
        return result
    }

    func counts() -> [ClipKind: Int] {
        var d: [ClipKind: Int] = [:]
        for item in items { d[item.kind, default: 0] += 1 }
        return d
    }

    // MARK: Helpers

    private func move(_ item: ClipItem, toFront: Bool) {
        guard items.contains(where: { $0.id == item.id }) else { return }
        // sortStable() fully determines order (pinned-first, then recency), so an
        // explicit front-insert is unnecessary; just re-sort in place.
        sortStable()
    }

    /// Pinned first (by recency), then the rest by recency.
    private func sortStable() {
        items.sort { a, b in
            if a.pinned != b.pinned { return a.pinned && !b.pinned }
            return a.lastUsedAt > b.lastUsedAt
        }
    }

    private func trim() {
        guard historyLimit > 0 else { return } // 0 = unlimited
        let unpinned = items.filter { !$0.pinned }
        guard unpinned.count > historyLimit else { return }
        let toRemove = unpinned.suffix(unpinned.count - historyLimit)
        for item in toRemove {
            if let f = item.payloadFile {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
            }
        }
        let removeIDs = Set(toRemove.map { $0.id })
        items.removeAll { removeIDs.contains($0.id) }
    }

    // MARK: Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            NSLog("Ditto: failed to save history: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        if let decoded = try? JSONDecoder().decode([ClipItem].self, from: data) {
            items = decoded
            // Migrate legacy single-vector fields into the per-model cache.
            for item in items {
                if item.embeddings.isEmpty, let v = item.vector {
                    item.embeddings[item.vectorModel ?? "hashing-256"] =
                        ModelEmbedding(vector: v, tags: item.tagIDs ?? [])
                }
                item.vector = nil; item.tagIDs = nil; item.vectorModel = nil
            }
            // Don't embed here — the embedder isn't configured yet at store init.
            // `refreshForActiveModel()` (after the model loads) fills any gaps.
            sortStable()
            rebuildTagIndex()
        }
    }
}
