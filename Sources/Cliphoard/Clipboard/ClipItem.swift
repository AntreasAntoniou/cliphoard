import AppKit
import UniformTypeIdentifiers

/// The kind of content a clip holds. Mirrors the categories Paste exposes.
enum ClipKind: String, Codable, CaseIterable {
    case text
    case link
    case color
    case image
    case file

    var symbolName: String {
        switch self {
        case .text:  return "text.alignleft"
        case .link:  return "link"
        case .color: return "paintpalette"
        case .image: return "photo"
        case .file:  return "doc"
        }
    }

    var title: String {
        switch self {
        case .text:  return "Text"
        case .link:  return "Links"
        case .color: return "Colors"
        case .image: return "Images"
        case .file:  return "Files"
        }
    }
}

/// A cached embedding for one model: the vector plus the top-K preset tag ids.
struct ModelEmbedding: Codable {
    /// The cached vector for one model. Tag ids are NOT stored — see
    /// `ClipStore.tags(of:)`.
    ///
    /// They used to live here, and that was the defect: an id is a positional index
    /// into `TagBaskets.active.tags`, so a stored id does not go INVALID when the
    /// vocabulary changes, it goes WRONG — it resolves to a different word. Keeping a
    /// second copy of a derived value required a marker to say whether the copy was
    /// current, and that marker stamped itself without writing anything. Deleting the
    /// copy deletes the marker, the migration, the repair pass, and the possibility.
    var vector: [Float]
}

/// A single entry in the clipboard history.
///
/// Heavy payloads (image data) are stored on disk next to the metadata and
/// referenced by `payloadFile` so the in-memory list stays light.
final class ClipItem: Codable, Identifiable {
    let id: UUID
    /// Mutable so the embedding tagger can refine it after ingest (e.g. promote a
    /// model-recognised link out of the text bucket).
    var kind: ClipKind
    /// Human readable text. For images this is a placeholder caption.
    var text: String
    /// Original RTF data when the source provided styled text.
    var rtf: Data?
    /// Relative filename (inside the store directory) for binary payloads.
    var payloadFile: String?
    /// SHA-256 (hex) of the plaintext PNG bytes for `.image` clips. Drives
    /// content-based dedup so byte-identical images collapse to one entry.
    /// `nil` for legacy items captured before content hashing existed.
    var imageHash: String?
    /// Text recognised inside an `.image` clip, sealed at rest like `text`.
    ///
    /// The three states are load-bearing and are carried by NULL-vs-empty, not by a
    /// separate marker column:
    ///   `nil` — never analysed. The background pass selects exactly this.
    ///   `""`  — analysed, nothing to index: no text found, or the payload could not
    ///           be decrypted, or the withhold rule REFUSED to store what was found.
    ///   text  — analysed and cleared by `Detectors.scan`.
    ///
    /// That collapse is deliberate. Because a withheld result is stored as `""`, and
    /// `SemanticRanker.searchText` falls back to the caption when it is empty, a
    /// screenshot whose recognised text was refused is invisible to the embedder, the
    /// tag index and all three substring paths WITHOUT any of them having to know the
    /// rule. The gate is at the write, so every present and future reader is safe by
    /// construction rather than by remembering.
    var ocrText: String?
    /// Absolute file path for `.file` clips.
    var filePath: String?
    /// Hex string for `.color` clips, e.g. "#FF8800".
    var colorHex: String?
    var createdAt: Date
    var lastUsedAt: Date
    var pinned: Bool
    /// Bundle id / name of the app the clip was copied from.
    var sourceApp: String?
    var useCount: Int
    /// User-owned labels. They are independent of model-generated embeddings so
    /// a model or vocabulary switch can never erase them.
    var userTags: [String] = []
    /// Per-model cache: embedder signature → {vector, tags}. Keeping one entry
    /// per model means switching to a model the clip was already embedded by is
    /// free (no recompute) — only genuinely unprocessed (model, clip) pairs run.
    var embeddings: [String: ModelEmbedding] = [:]
    /// The Tier-1 detector verdict (design §5), computed once synchronously at
    /// capture and persisted as a plain INTEGER column so chips render with no
    /// recompute and filtering never needs to re-scan content.
    ///
    /// Empty is the common case and means *nothing fired* — it is emphatically
    /// **not** a claim that the clip is safe (`ClipFlags` has no positive label
    /// by construction). Unknown bits written by a newer build are carried
    /// through untouched: the raw value is never masked down to the bits this
    /// build happens to know.
    var flags: ClipFlags = []
    /// The §3.4 structural shape ("url", "json", "path", …) or `nil` for prose.
    /// Cosmetic and non-content — a short enum-like token, never clip text — so
    /// it is stored in the clear alongside `flags`.
    var shape: String? = nil

    /// Whether the detector verdict forbids embedding/indexing this clip.
    ///
    /// `.secret` is a Tier-1 zero-false-positive credential hit and `.quarantined`
    /// is an exact-match sensitive origin; design §5 requires that such a clip
    /// never reaches the model ("never send a secret through the model") and is
    /// "excluded from the CoreML index entirely". It is still stored (sealed) and
    /// still appears in history — it simply has no vector.
    ///
    /// Deliberately does **not** include `.secretEntropy`: that bit is the
    /// low-confidence Tier-2 heuristic, which §3.1 forbids from driving a
    /// destructive action until it clears an FP audit.
    static let indexVetoFlags: ClipFlags = [.secret, .quarantined]

    /// Flags that suppress STORING recognised image text (it becomes `""`), not the
    /// clip. Deliberately wider than `indexVetoFlags`, and that is not a contradiction
    /// of the rule above: §3.1 bars the low-confidence bits from driving a DESTRUCTIVE
    /// action, and withholding destroys nothing. The image is still stored, still
    /// pastable, still in history, still similar-searchable. Only a guess we chose not
    /// to write down is missing.
    ///
    /// Wider because the risk is not symmetric with typed text. For a text clip the
    /// USER chose the bytes; for a screenshot the APP chose them, sweeping up whatever
    /// happened to be on screen — other people's messages, a bank balance, an address.
    /// Parity of policy is not parity of risk.
    ///
    /// `.secretEntropy` is included here precisely because recognition is lossy: OCR
    /// can transpose a character, and a mangled key no longer matches the byte-exact
    /// signature detectors. Entropy is the net that catches what the signatures drop.
    /// Known gap, documented rather than papered over: `.otp` cannot catch an
    /// authenticator screenshot, because `detectOTP` needs a contiguous 4–8 digit run
    /// plus a keyword, and a code rendered "482 913" is two 3-digit groups with neither.
    static let ocrWithholdFlags: ClipFlags =
        indexVetoFlags.union([.secretEntropy, .otp, .financial, .piiSensitive])

    /// Fail-closed gate consulted by every path that would embed this clip —
    /// ingest *and* any later background re-index/reclassify pass, so a
    /// housekeeping loop can never quietly undo the veto.
    var isIndexVetoed: Bool { !flags.isDisjoint(with: Self.indexVetoFlags) }

    // Legacy single-vector fields (pre per-model cache). Decoded only to migrate
    // old data into `embeddings`, then cleared. Not written for new clips.
    var vector: [Float]?
    var vectorModel: String?

    /// Whether this clip already has an embedding for `signature`.
    func isEmbedded(by signature: String) -> Bool { embeddings[signature] != nil }

    init(kind: ClipKind, text: String) {
        self.id = UUID()
        self.kind = kind
        self.text = text
        self.createdAt = Date()
        self.lastUsedAt = Date()
        self.pinned = false
        self.useCount = 0
    }

    /// Full initializer used to reconstruct a clip from a database row.
    init(id: UUID, kind: ClipKind, text: String, rtf: Data?, payloadFile: String?,
         filePath: String?, colorHex: String?, createdAt: Date, lastUsedAt: Date,
         pinned: Bool, sourceApp: String?, useCount: Int, userTags: [String] = [],
         flags: ClipFlags = [], shape: String? = nil, ocrText: String? = nil) {
        self.id = id; self.kind = kind; self.text = text; self.rtf = rtf
        self.payloadFile = payloadFile; self.filePath = filePath; self.colorHex = colorHex
        self.createdAt = createdAt; self.lastUsedAt = lastUsedAt; self.pinned = pinned
        self.sourceApp = sourceApp; self.useCount = useCount
        self.userTags = Self.normalizedUserTags(userTags)
        self.flags = flags; self.shape = shape; self.ocrText = ocrText
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case id, kind, text, rtf, payloadFile, imageHash, ocrText, filePath, colorHex
        case createdAt, lastUsedAt, pinned, sourceApp, useCount
        case userTags
        case flags, shape
        case embeddings, vector, vectorModel
    }

    /// Resilient decoding: every field is optional-with-default, so adding or
    /// removing fields never makes an existing `history.json` fail to load (which
    /// previously wiped history when a new non-optional field like `embeddings`
    /// was introduced). Forward- and backward-compatible.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(ClipKind.self, forKey: .kind) ?? .text
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        rtf = try c.decodeIfPresent(Data.self, forKey: .rtf)
        payloadFile = try c.decodeIfPresent(String.self, forKey: .payloadFile)
        imageHash = try c.decodeIfPresent(String.self, forKey: .imageHash)
        // Absent in legacy JSON → nil → "never analysed", so the background pass picks
        // it up. It must NOT decode to "" here: that would mean "analysed, nothing to
        // index" and would silently exclude every imported image from recognition.
        ocrText = try c.decodeIfPresent(String.self, forKey: .ocrText)
        filePath = try c.decodeIfPresent(String.self, forKey: .filePath)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt) ?? createdAt
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        sourceApp = try c.decodeIfPresent(String.self, forKey: .sourceApp)
        useCount = try c.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
        userTags = Self.normalizedUserTags(
            try c.decodeIfPresent([String].self, forKey: .userTags) ?? [])
        // `decodeIfPresent` with an empty default, so a `history.json` written
        // before the detector existed still loads — and loads as "nothing fired",
        // never as "safe".
        flags = try c.decodeIfPresent(ClipFlags.self, forKey: .flags) ?? []
        shape = try c.decodeIfPresent(String.self, forKey: .shape)
        embeddings = try c.decodeIfPresent([String: ModelEmbedding].self, forKey: .embeddings) ?? [:]
        vector = try c.decodeIfPresent([Float].self, forKey: .vector)
        vectorModel = try c.decodeIfPresent(String.self, forKey: .vectorModel)
    }

    // MARK: Derived

    static func normalizedUserTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        return tags.compactMap { raw in
            let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !tag.isEmpty, seen.insert(tag).inserted else { return nil }
            return tag
        }
    }

    /// A short preview string used in the card header / accessibility.
    var preview: String {
        switch kind {
        case .image: return "Image"
        case .color: return colorHex ?? text
        default:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "(empty)" : trimmed
        }
    }

    var characterCountLabel: String {
        switch kind {
        case .image: return "Image"
        case .file:  return (filePath as NSString?)?.lastPathComponent ?? "File"
        case .color: return colorHex ?? "Color"
        default:
            let n = text.count
            return n == 1 ? "1 character" : "\(n) characters"
        }
    }

    /// A stable signature used to deduplicate consecutive identical copies.
    var signature: String {
        switch kind {
        case .image: return "img:" + (imageHash ?? payloadFile ?? text)
        case .file:  return "file:" + (filePath ?? text)
        case .color: return "color:" + (colorHex ?? text)
        default:     return "text:" + text
        }
    }
}
