import AppKit
import Combine

/// Owns the clipboard history. Durable storage is a SQLite database with
/// incremental row writes (no whole-file rewrites); `items` is the in-memory
/// projection that drives the reactive UI and in-memory search.
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
    private let db: Database?

    /// The in-flight background indexing pass, if any. A new pass cancels the
    /// previous one so overlapping model/basket changes don't run two passes
    /// that fight over the published `indexing` state.
    private var indexingTask: Task<Void, Never>?

    /// - Parameter directory: storage location. Defaults to
    ///   `~/Library/Application Support/Ditto`; tests inject a temp directory.
    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ditto", isDirectory: true)
        dir = base
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        db = Database(path: dir.appendingPathComponent("ditto.sqlite").path)
        migrateLegacyJSONIfNeeded()
        items = db?.loadAll() ?? []
        sortStable()
        rebuildTagIndex()
        sweepOrphanPayloads()
    }

    /// Best-effort: delete any "*.png" payload files in the store directory that
    /// are no longer referenced by a live item's `payloadFile`. Guards against
    /// images leaking on disk after a crash, an interrupted delete, or a stale
    /// database. Errors are ignored — this is purely housekeeping.
    private func sweepOrphanPayloads() {
        let referenced = Set(items.compactMap { $0.payloadFile })
        // A clip "<uuid>.png" may have a sidecar thumbnail "<uuid>-thumb.png"
        // (ClipboardMonitor.writeThumbnail). Keep a thumbnail whose original is
        // still referenced — otherwise the sweep deletes every thumbnail on launch.
        func isLiveThumbnail(_ name: String) -> Bool {
            guard name.hasSuffix("-thumb.png") else { return false }
            return referenced.contains(String(name.dropLast("-thumb.png".count)) + ".png")
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return }
        for url in entries where url.pathExtension.lowercased() == "png" {
            let name = url.lastPathComponent
            if !referenced.contains(name) && !isLiveThumbnail(name) {
                try? FileManager.default.removeItem(at: url)
            }
        }
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
            db?.updateMeta(existing)
            return
        }
        // Embed + tag at ingest (for the active model) so semantic search is
        // ready immediately. Skipped in the `off` tier, which uses no vectors.
        if DeepSearch.level != .off && ClipIndexer.isStale(item) {
            ClipIndexer.index(item)
            ClipIndexer.refineKind(item)   // let the embedding correct the bucket
        }
        items.insert(item, at: 0)
        trim()
        // Keep the pinned-first / recency order consistent with every other path.
        sortStable()
        rebuildTagIndex()
        lastAddedID = item.id
        db?.insert(item)
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
        let sig = EmbedderProvider.active.signature
        let stale = items.filter { ClipIndexer.isStale($0) }
        guard !stale.isEmpty else { return }
        let total = stale.count
        let started = Date()
        indexing = IndexingProgress(done: 0, total: total, etaSeconds: nil)
        indexingTask?.cancel()
        indexingTask = Task { @MainActor in
            var done = 0
            for item in stale {
                if Task.isCancelled { break }
                ClipIndexer.index(item)
                if let emb = item.embeddings[sig] {
                    db?.upsertEmbedding(clipID: item.id, model: sig, embedding: emb)
                }
                done += 1
                if done % 8 == 0 || done == total {
                    let elapsed = Date().timeIntervalSince(started)
                    let eta = done > 0 ? elapsed / Double(done) * Double(total - done) : nil
                    indexing = IndexingProgress(done: done, total: total, etaSeconds: eta)
                    rebuildTagIndex()
                    await Task.yield()
                }
            }
            rebuildTagIndex()
            indexing = nil
            indexingTask = nil
            DebugLog.write("reindexed \(done) stale items → \(sig)")
        }
    }

    /// Recompute tags for every clip from its already-cached vector — used when
    /// the tag basket changes. No re-embedding of clips (only the basket's tag
    /// names are embedded, once); just re-runs the cheap nearest-tag step.
    func reclassifyAllTags() {
        let sig = EmbedderProvider.active.signature
        let targets = items.filter { $0.embeddings[sig] != nil }
        rebuildTagIndex()                       // drop stale mappings immediately
        guard !targets.isEmpty else { return }
        let total = targets.count
        let started = Date()
        indexing = IndexingProgress(done: 0, total: total, etaSeconds: nil)
        indexingTask?.cancel()
        indexingTask = Task { @MainActor in
            var done = 0
            for item in targets {
                if Task.isCancelled { break }
                if var emb = item.embeddings[sig] {
                    emb.tags = TagSpace.classify(emb.vector, embedder: EmbedderProvider.active, topK: 5)
                    item.embeddings[sig] = emb
                    db?.upsertEmbedding(clipID: item.id, model: sig, embedding: emb)
                }
                done += 1
                if done % 16 == 0 || done == total {
                    let elapsed = Date().timeIntervalSince(started)
                    indexing = IndexingProgress(done: done, total: total,
                        etaSeconds: done > 0 ? elapsed / Double(done) * Double(total - done) : nil)
                    rebuildTagIndex()
                    await Task.yield()
                }
            }
            rebuildTagIndex()
            indexing = nil
            indexingTask = nil
        }
    }

    func togglePin(_ item: ClipItem) {
        item.pinned.toggle()
        sortStable()
        db?.updateMeta(item)
    }

    func delete(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
        removePayload(item)
        rebuildTagIndex()
        db?.delete(id: item.id)
    }

    /// Clear everything that is not pinned.
    func clearUnpinned() {
        let removed = items.filter { !$0.pinned }
        items.removeAll { !$0.pinned }
        removed.forEach(removePayload)
        rebuildTagIndex()
        db?.deleteUnpinned()
    }

    func markUsed(_ item: ClipItem) {
        item.lastUsedAt = Date()
        item.useCount += 1
        move(item, toFront: true)
        db?.updateMeta(item)
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
        sortStable()   // pinned-first, then recency — fully determines order
    }

    private func sortStable() {
        items.sort { a, b in
            if a.pinned != b.pinned { return a.pinned && !b.pinned }
            return a.lastUsedAt > b.lastUsedAt
        }
    }

    private func removePayload(_ item: ClipItem) {
        if let f = item.payloadFile {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
            // Remove the sidecar thumbnail too.
            let thumb = (f as NSString).deletingPathExtension + "-thumb.png"
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(thumb))
        }
    }

    private func trim() {
        guard historyLimit > 0 else { return } // 0 = unlimited
        let unpinned = items.filter { !$0.pinned }
        guard unpinned.count > historyLimit else { return }
        let toRemove = Array(unpinned.suffix(unpinned.count - historyLimit))
        toRemove.forEach(removePayload)
        let removeIDs = Set(toRemove.map { $0.id })
        items.removeAll { removeIDs.contains($0.id) }
        db?.delete(ids: toRemove.map { $0.id })
    }

    // MARK: Migration

    /// One-time import of an old `history.json` into the database, then archive it.
    private func migrateLegacyJSONIfNeeded() {
        let jsonURL = dir.appendingPathComponent("history.json")
        guard (db?.clipCount() ?? 0) == 0,
              let data = try? Data(contentsOf: jsonURL) else { return }
        let decoded: [ClipItem]
        do { decoded = try JSONDecoder().decode([ClipItem].self, from: data) }
        catch {
            NSLog("Ditto: legacy history decode failed: \(error) — keeping history.corrupt.json")
            try? data.write(to: dir.appendingPathComponent("history.corrupt.json"))
            return
        }
        for item in decoded {
            // Fold legacy single-vector fields into the per-model cache.
            if item.embeddings.isEmpty, let v = item.vector {
                item.embeddings[item.vectorModel ?? "hashing-256"] =
                    ModelEmbedding(vector: v, tags: item.tagIDs ?? [])
            }
            item.vector = nil; item.tagIDs = nil; item.vectorModel = nil
        }
        db?.transaction { decoded.forEach { db?.insert($0) } }
        // Archive the JSON so we don't re-import (and as a safety backup).
        try? FileManager.default.moveItem(at: jsonURL,
            to: dir.appendingPathComponent("history.migrated.json"))
        DebugLog.write("migrated \(decoded.count) clips from history.json → sqlite")
    }
}
