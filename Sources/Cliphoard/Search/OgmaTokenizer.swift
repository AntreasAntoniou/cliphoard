import Foundation

/// A faithful Swift implementation of ogma's tokenizer (Unigram/SentencePiece),
/// loaded from the bundled `tokenizer.json`. swift-transformers' generic Unigram
/// path doesn't reproduce ogma's pipeline — specifically the per-word `▁`
/// metaspace prefix and the custom `+n_special_tokens` id offset that shifts the
/// tokenizer vocab above the model's task tokens — so we replicate it exactly.
///
/// Two schemes, auto-detected from the vocab:
///
/// - **Legacy** (vocab contains `[CLS]`) — the original CC-BY-NC ogma models'
///   BERT-style Unigram: NFKD → strip accents → lowercase → per-word `▁` →
///   Viterbi → wrap `[CLS]`…`[SEP]` → offset EVERY id by `n_special_tokens`.
/// - **Libre** (no `[CLS]` piece) — the open-ogma (ogma-libre) raw SentencePiece
///   scheme: NFKC (case is KEPT) → per-word `▁` → Viterbi with BYTE FALLBACK
///   (`<0xXX>` pieces for chars the vocab can't cover) → offset only the sp ids
///   by `n_special_tokens`; wrap with the model's raw bos=2 / eos=3.
///
/// Both validated to match their reference token ids bit-for-bit
/// (Tests/CliphoardTests: OgmaTokenizerTests + OgmaLibreTokenizerParityTests).
final class OgmaTokenizer {
    private let vocab: [String: (id: Int, score: Float)]
    private let unkId: Int
    private let clsId: Int
    private let sepId: Int
    private let offset: Int
    /// Libre scheme: raw sp vocab, byte fallback, un-offset bos/eos.
    private let libre: Bool
    private let unkScore: Float = -25
    /// Length (in Characters) of the longest vocab piece. Bounds the Viterbi
    /// inner loop: no valid segmentation can start further back than this, so a
    /// whitespace-free clip of length n costs O(n * maxPieceChars) instead of O(n^2).
    private let maxPieceChars: Int
    /// Hard cap (in Characters) on normalized text length. Pathological
    /// megabyte-scale blobs (minified JSON, base64) are truncated to a
    /// representative prefix so total tokenization work stays bounded.
    private let maxEncodeChars = 4096

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
        var cls: Int? = nil, sep: Int? = nil
        for (idx, entry) in rawVocab.enumerated() {
            guard let piece = entry.first as? String else { continue }
            let score = (entry.count > 1 ? (entry[1] as? Double) : 0) ?? 0
            dict[piece] = (idx, Float(score))
            if piece == "[CLS]" { cls = idx }
            if piece == "[SEP]" { sep = idx }
        }
        self.vocab = dict
        // No [CLS] piece → an ogma-libre (raw SentencePiece) vocab. Its frame
        // tokens are the MODEL's bos=2/eos=3, emitted un-offset.
        self.libre = (cls == nil)
        self.clsId = cls ?? 2
        self.sepId = sep ?? 3
        self.unkId = (model["unk_id"] as? Int) ?? (cls == nil ? 0 : 1)
        // Longest key in Characters; at least 1 so the window is always valid.
        self.maxPieceChars = max(1, dict.keys.map { $0.count }.max() ?? 1)

        // The model reserves `n_special_tokens` ids (pad/unk/bos/eos/qry/doc/sym)
        // below the tokenizer vocab; every tokenizer id is shifted up by that.
        let cfg = (try? Data(contentsOf: folder.appendingPathComponent("config.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        self.offset = (cfg?["n_special_tokens"] as? Int) ?? 7
    }

    /// Encode text to model input ids (already offset, framed with bos…eos).
    func encode(_ text: String) -> [Int] {
        // Cap the normalized text to a representative prefix so a pathological
        // whitespace-free megabyte blob (minified JSON, base64, a long token)
        // can't drive unbounded tokenization work on the main actor.
        var normalized = normalize(text)
        if normalized.count > maxEncodeChars {
            normalized = String(normalized.prefix(maxEncodeChars))
        }
        var body: [Int] = []
        // Split on ALL whitespace (not just ASCII space) so newlines/tabs in
        // multi-line clips don't get folded into a metaspace "word" that the
        // Unigram vocab can't match and falls through to per-char UNK runs.
        for word in normalized.split(whereSeparator: { $0.isWhitespace }) {
            body.append(contentsOf: unigram("\u{2581}" + word))   // ▁ metaspace prefix
        }
        if libre {
            // sp ids get the +offset; the frame tokens are the model's raw ids.
            return [clsId] + body.map { $0 + offset } + [sepId]
        }
        return ([clsId] + body + [sepId]).map { $0 + offset }
    }

    // MARK: Normalizer

    private func normalize(_ text: String) -> String {
        if libre {
            // sp's nmt_nfkc: NFKC, case preserved, whitespace runs collapsed
            // (the per-word split above supplies the collapse + metaspace).
            let s = text.precomposedStringWithCompatibilityMapping
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
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
        // Ids emitted when the best path ends a step at this position. Usually a
        // single vocab id; the libre byte fallback expands one unmatched char
        // into several `<0xXX>` byte-piece ids.
        var tokenAt = [[Int]](repeating: [unkId], count: n + 1)
        best[0] = 0
        for end in 1...n {
            // Only starts within maxPieceChars of `end` can match a vocab piece,
            // so bounding the window is exact (loses no valid segmentation) and
            // turns the Viterbi cost from O(n^2) into O(n * maxPieceChars).
            for start in max(0, end - maxPieceChars)..<end where best[start] > neg {
                if let entry = vocab[String(chars[start..<end])] {
                    let sc = best[start] + entry.score
                    if sc > best[end] { best[end] = sc; back[end] = start; tokenAt[end] = [entry.id] }
                }
            }
            if best[end] == neg {            // nothing matched → 1-char fallback
                best[end] = best[end - 1] + unkScore
                back[end] = end - 1
                tokenAt[end] = fallback(chars[end - 1])
            }
        }
        var ids: [Int] = []
        var i = n
        while i > 0 { ids.append(contentsOf: tokenAt[i].reversed()); i = back[i] }
        return ids.reversed()
    }

    /// Ids for a character no vocab piece covers. Libre vocabs carry the 256
    /// SentencePiece byte pieces, so the char decomposes into its UTF-8 bytes
    /// (`<0xE1>` …) exactly as sp's byte fallback does; the legacy vocab has no
    /// byte pieces and keeps emitting `unk`.
    private func fallback(_ ch: Character) -> [Int] {
        guard libre else { return [unkId] }
        let ids = String(ch).utf8.compactMap { byte in
            vocab[String(format: "<0x%02X>", byte)]?.id
        }
        return ids.isEmpty ? [unkId] : ids
    }
}
