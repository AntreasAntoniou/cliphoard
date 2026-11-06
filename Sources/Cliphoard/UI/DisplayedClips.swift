import Foundation

/// Keep the model's indices: keyboard shortcuts must still name the same clips
/// after a display-only signal filter hides some rows.
struct DisplayedClip: Identifiable {
    let index: Int
    let item: ClipItem
    var id: UUID { item.id }
}

/// Shares the results array rather than allocating one row object per clip on
/// every selection, hover or inspector update. Rows are made only when asked for.
struct DisplayedClips: RandomAccessCollection {
    typealias Index = Int
    private let items: [ClipItem]
    private let visibleIndices: [Int]?
    init(_ items: [ClipItem], visibleIndices: [Int]? = nil) {
        self.items = items
        self.visibleIndices = visibleIndices
    }
    var startIndex: Int { 0 }
    var endIndex: Int { visibleIndices?.count ?? items.count }
    subscript(position: Int) -> DisplayedClip {
        let index = visibleIndices?[position] ?? position
        return DisplayedClip(index: index, item: items[index])
    }
}
