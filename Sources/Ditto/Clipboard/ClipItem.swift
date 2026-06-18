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
    var vector: [Float]
    var tags: [Int]
}

/// A single entry in the clipboard history.
///
/// Heavy payloads (image data) are stored on disk next to the metadata and
/// referenced by `payloadFile` so the in-memory list stays light.
final class ClipItem: Codable, Identifiable {
    let id: UUID
    let kind: ClipKind
    /// Human readable text. For images this is a placeholder caption.
    var text: String
    /// Original RTF data when the source provided styled text.
    var rtf: Data?
    /// Relative filename (inside the store directory) for binary payloads.
    var payloadFile: String?
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
    /// Per-model cache: embedder signature → {vector, tags}. Keeping one entry
    /// per model means switching to a model the clip was already embedded by is
    /// free (no recompute) — only genuinely unprocessed (model, clip) pairs run.
    var embeddings: [String: ModelEmbedding] = [:]

    // Legacy single-vector fields (pre per-model cache). Decoded only to migrate
    // old data into `embeddings`, then cleared. Not written for new clips.
    var vector: [Float]?
    var tagIDs: [Int]?
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

    // MARK: Derived

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
        case .image: return "img:" + (payloadFile ?? text)
        case .file:  return "file:" + (filePath ?? text)
        case .color: return "color:" + (colorHex ?? text)
        default:     return "text:" + text
        }
    }
}
