import Foundation

/// Gemma pictures have a strong shared text/image direction: unrelated public
/// fixtures score 0.6–0.7 in raw cosine. Require a query to explain a picture
/// better than generic image descriptions, rather than returning every vector.
/// This is a conservative retrieval operating point, not an accuracy guarantee.
enum GemmaPictureRelevance {
    static let backgroundQueries = ["an image", "a picture"]
    static let minimumSpecificity: Float = 0.035

    static func margin(similarity: Float, background: Float) -> Float? {
        guard similarity.isFinite, background.isFinite else { return nil }
        let difference = similarity - background
        return difference >= minimumSpecificity ? difference : nil
    }

    static func score(query: [Float], image: [Float], backgrounds: [[Float]]) -> Float? {
        let vectors = [query, image] + backgrounds
        guard !backgrounds.isEmpty,
              vectors.allSatisfy({ $0.count == 768 && $0.allSatisfy(\.isFinite) && $0.contains(where: { $0 != 0 }) }),
              let baseline = backgrounds.map({ SemanticRanker.cosine($0, image) }).max() else { return nil }
        return margin(similarity: SemanticRanker.cosine(query, image), background: baseline)
    }
}
