import Foundation

/// Current model suggestions join the card's factual chips without changing
/// their filter semantics or allowing a suggestion to displace a warning.
enum ClipCardTags {
    enum Entry: Hashable {
        case signal(ClipSignal)
        case model(String)

        var spoken: String {
            switch self {
            case .signal(let signal): return signal.spoken
            case .model(let label): return "Suggested tag: \(label)"
            }
        }
    }

    @MainActor
    static func modelLabels(for item: ClipItem, embedder: TextEmbedder) -> [String] {
        guard !item.isIndexVetoed, let embedding = item.embeddings[embedder.signature],
              ClipIndexer.isUsable(embedding.vector, dimension: embedder.dimension) else { return [] }
        let names = TagSpace.names
        return ClipIndexer.tags(for: embedding.vector, embedder: embedder).compactMap {
            names.indices.contains($0) ? names[$0] : nil
        }
    }

    static func row(for item: ClipItem, modelTags: [String], now: Date = Date())
        -> (shown: [Entry], overflow: Int) {
        let signals = ClipChips.chips(for: item, now: now)
        let warnings = signals.filter { if case .flag = $0 { return true }; return false }
        let facts = signals.filter { if case .flag = $0 { return false }; return true }
        var seen = Set<String>()
        let labels = item.isIndexVetoed ? [] : modelTags.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0).inserted
        }
        let all = warnings.map(Entry.signal) + labels.map(Entry.model) + facts.map(Entry.signal)
        if all.count <= ClipChips.maxChips { return (all, 0) }
        let shown = Array(all.prefix(ClipChips.maxChips - 1))
        return (shown, all.count - shown.count)
    }
}
