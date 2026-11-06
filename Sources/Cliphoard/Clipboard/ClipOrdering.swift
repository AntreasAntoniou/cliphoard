import Foundation

/// History order shared by the main array and its ordered tag buckets.
enum ClipOrdering {
    static func precedes(_ a: ClipItem, _ b: ClipItem) -> Bool {
        if a.pinned != b.pinned { return a.pinned && !b.pinned }
        return a.lastUsedAt > b.lastUsedAt
    }

    /// Only this item's sort fields changed. Move it once instead of sorting
    /// every clip. Preserve the previous relative order for equal timestamps,
    /// exactly as a stable full sort would. Missing items are never inserted.
    static func reposition(_ item: ClipItem, in items: inout [ClipItem]) {
        guard let original = items.firstIndex(where: { $0.id == item.id }) else { return }
        items.remove(at: original)
        var low = 0, high = items.count
        while low < high {
            let mid = low + (high - low) / 2
            let candidate = items[mid]
            let tied = !precedes(candidate, item) && !precedes(item, candidate)
            if precedes(candidate, item) || (tied && mid < original) { low = mid + 1 }
            else { high = mid }
        }
        items.insert(item, at: low)
    }
}
