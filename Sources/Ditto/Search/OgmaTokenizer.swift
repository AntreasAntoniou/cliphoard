import Foundation

/// A faithful Swift implementation of ogma's tokenizer (Unigram/SentencePiece),
/// loaded from the bundled `tokenizer.json`. swift-transformers' generic Unigram
/// path doesn't reproduce ogma's pipeline — specifically the per-word `▁`
/// metaspace prefix and the custom `+n_special_tokens` id offset that shifts the
/// tokenizer vocab above the model's task tokens — so we replicate it exactly.
///
/// Pipeline: normalize (NFKD → strip accents → lowercase → collapse spaces) →
/// whitespace split → prepend `▁` → Unigram Viterbi → wrap `[CLS]`…`[SEP]` →
/// add the `+offset`. Validated to match the reference token ids bit-for-bit.
final class OgmaTokenizer {
    private let vocab: [String: (id: Int, score: Float)]
    private let unkId: Int
    private let clsId: Int
    private let sepId: Int
    private let offset: Int
    private let unkScore: Float = -25

    /// - Parameter folder: a directory containing `tokenizer.json` and `config.json`.
    init?(folder: URL) {
        guard
            let tokData = try? Data(contentsOf: folder.appendingPathComponent("tokenizer.json")),
            let tokJSON = try? JSONSerialization.jsonObject(with: tokData) as? [String: Any],
            let model = tokJSON["model"] as? [String: Any],
            let rawVocab = model["vocab"] as? [[Any]]
        else { return nil }

        var dict: [String: (Int, Float)] = [:]
        dict.reserveCapacity(rawVocab.count)
        var cls = 2, sep = 3
        for (idx, entry) in rawVocab.enumerated() {
            guard let piece = entry.first as? String else { continue }
            let score = (entry.count > 1 ? (entry[1] as? Double) : 0) ?? 0
            dict[piece] = (idx, Float(score))
            if piece == "[CLS]" { cls = idx }
            if piece == "[SEP]" { sep = idx }
        }
        self.vocab = dict
        self.clsId = cls
        self.sepId = sep
        self.unkId = (model["unk_id"] as? Int) ?? 1

        // The model reserves `n_special_tokens` ids (pad/unk/bos/eos/qry/doc/sym)
        // below the tokenizer vocab; every tokenizer id is shifted up by that.
        let cfg = (try? Data(contentsOf: folder.appendingPathComponent("config.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        self.offset = (cfg?["n_special_tokens"] as? Int) ?? 7
    }

    /// Encode text to model input ids (already offset, with `[CLS]`/`[SEP]`).
    func encode(_ text: String) -> [Int] {
        var ids = [clsId]
        // Split on ALL whitespace (not just ASCII space) so newlines/tabs in
        // multi-line clips don't get folded into a metaspace "word" that the
        // Unigram vocab can't match and falls through to per-char UNK runs.
        for word in normalize(text).split(whereSeparator: { $0.isWhitespace }) {
            ids.append(contentsOf: unigram("\u{2581}" + word))   // ▁ metaspace prefix
        }
        ids.append(sepId)
        return ids.map { $0 + offset }
    }

    // MARK: Normalizer

    private func normalize(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "``", with: "\"")
                    .replacingOccurrences(of: "''", with: "\"")
        s = s.decomposedStringWithCompatibilityMapping                 // NFKD
        s = String(String.UnicodeScalarView(s.unicodeScalars.filter {  // strip accents
            $0.properties.generalCategory != .nonspacingMark
        }))
        s = s.lowercased()
        // Collapse every whitespace run (spaces, tabs, newlines) to one space.
        s = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Unigram Viterbi (best segmentation by summed log-prob)

    private func unigram<S: StringProtocol>(_ piece: S) -> [Int] {
        let chars = Array(piece)
        let n = chars.count
        guard n > 0 else { return [] }
        let neg = -Float.greatestFiniteMagnitude
        var best = [Float](repeating: neg, count: n + 1)
        var back = [Int](repeating: 0, count: n + 1)
        var tokenAt = [Int](repeating: unkId, count: n + 1)
        best[0] = 0
        for end in 1...n {
            for start in 0..<end where best[start] > neg {
                if let entry = vocab[String(chars[start..<end])] {
                    let sc = best[start] + entry.score
                    if sc > best[end] { best[end] = sc; back[end] = start; tokenAt[end] = entry.id }
                }
            }
            if best[end] == neg {            // nothing matched → 1-char unk
                best[end] = best[end - 1] + unkScore
                back[end] = end - 1
                tokenAt[end] = unkId
            }
        }
        var ids: [Int] = []
        var i = n
        while i > 0 { ids.append(tokenAt[i]); i = back[i] }
        return ids.reversed()
    }
}
