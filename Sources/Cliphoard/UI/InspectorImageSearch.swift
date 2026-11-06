import Foundation

/// Value snapshots cross the worker boundary; mutable ClipItems never do.
enum InspectorImageSearch {
    struct Feature: Sendable {
        let id: UUID
        let revision: Int
        let vector: [Float]
    }

    static func rank(query: Feature, candidates: [Feature], limit: Int) throws -> [UUID] {
        guard limit > 0, !query.vector.isEmpty else { return [] }
        var best: [(id: UUID, score: Float)] = []
        for (index, candidate) in candidates.enumerated() {
            if index % 128 == 0 { try Task.checkCancellation() }
            guard candidate.id != query.id, candidate.revision == query.revision,
                  candidate.vector.count == query.vector.count else { continue }
            let score = ImageUnderstanding.similarity(query.vector, candidate.vector)
            // A small top-k list avoids sorting/materializing all scored rows.
            let position = best.firstIndex { score > $0.score } ?? best.count
            if position < limit {
                best.insert((candidate.id, score), at: position)
                if best.count > limit { best.removeLast() }
            }
        }
        return best.map(\.id)
    }

    static func search(query: Feature, candidates: [Feature], limit: Int) async throws -> [UUID] {
        let worker = Task.detached(priority: .userInitiated) {
            try rank(query: query, candidates: candidates, limit: limit)
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: { worker.cancel() }
    }
}
