import Foundation
import CoreML
import Tokenizers

/// On-device CoreML embedder for standard HF models (the High/Max tiers:
/// all-MiniLM-L6-v2, EmbeddingGemma). Tokenization comes from
/// swift-transformers' `AutoTokenizer` (WordPiece / SentencePiece read from the
/// bundled tokenizer folder) — unlike the ogma models, these follow stock HF
/// pipelines, which is exactly what that library implements. The converted
/// models bake pooling + L2-normalisation into the graph, so the interface is
/// (input_ids, attention_mask) → "embedding".
///
/// Asymmetric models (EmbeddingGemma) use task PROMPTS, not task tokens: fixed
/// string prefixes prepended before tokenizing. MiniLM is symmetric (both empty).
final class HFEmbedder: TextEmbedder {
    let dimension: Int
    let signature: String
    let relevanceFloor: Float
    private let model: MLModel
    private let tokenizer: Tokenizer
    private let queryPrefix: String
    private let docPrefix: String
    private let maxLen = 256

    init(modelName: String, model: MLModel, tokenizer: Tokenizer, dimension: Int,
         queryPrefix: String = "", docPrefix: String = "", relevanceFloor: Float = 0.20) {
        self.model = model
        self.tokenizer = tokenizer
        self.dimension = dimension
        self.queryPrefix = queryPrefix
        self.docPrefix = docPrefix
        self.relevanceFloor = relevanceFloor
        self.signature = "\(modelName)-\(dimension)-v1"
    }

    func embed(_ text: String) -> [Float] { run(docPrefix + text) }
    func embed(_ text: String, query: Bool) -> [Float] { run((query ? queryPrefix : docPrefix) + text) }

    private func run(_ text: String) -> [Float] {
        var ids = tokenizer.encode(text: text).map { Int32($0) }
        // Truncate keeping the final special token ([SEP]/<eos>) intact.
        if ids.count > maxLen { ids = Array(ids.prefix(maxLen - 1)) + [ids[ids.count - 1]] }
        let len = ids.count
        // [] (not zeros) on failure — a zero vector would be cached as valid and
        // never retried (same contract as OgmaEmbedder).
        guard len >= 2,
              let idArr = try? MLMultiArray(shape: [1, NSNumber(value: len)], dataType: .int32),
              let maskArr = try? MLMultiArray(shape: [1, NSNumber(value: len)], dataType: .int32) else {
            return []
        }
        for i in 0..<len { idArr[i] = NSNumber(value: ids[i]); maskArr[i] = 1 }
        let out: MLFeatureProvider
        do {
            let input = try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": idArr, "attention_mask": maskArr
            ])
            out = try model.prediction(from: input)
        } catch {
            NSLog("Cliphoard HFEmbedder(\(signature)): prediction failed: \(error)")
            return []
        }
        guard let emb = out.featureValue(for: "embedding")?.multiArrayValue else {
            NSLog("Cliphoard HFEmbedder(\(signature)): no 'embedding' output; features=\(out.featureNames)")
            return []
        }
        var v = [Float](repeating: 0, count: emb.count)
        for i in 0..<emb.count { v[i] = emb[i].floatValue }
        return v
    }
}
