import AppKit
import Combine

/// Owns the clipboard history: persistence, dedup, pinning, search and limits.
@MainActor
final class ClipStore: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    /// The id of the clip most recently added or bumped — lets the bar scroll to
    /// reveal it wherever it lands in the (pinned-first) order.
    @Published private(set) var lastAddedID: UUID?

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
        items.insert(item, at: 0)
        trim()
        // Keep the pinned-first / recency order consistent with every other path
        // (togglePin, load, move) so a fresh copy doesn't briefly jump ahead of
        // pinned items only to be reordered on the next mutation.
        sortStable()
        lastAddedID = item.id
        save()
        Feedback.playCapture()
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
            sortStable()
        }
    }
}
