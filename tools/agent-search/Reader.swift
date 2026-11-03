import Foundation

struct SharedClip: Codable {
    let id: UUID
    let kind: String
    let text: String

    init?(_ clip: HistoryArchive.Clip) {
        guard clip.userTags.contains("agent-share"), let id = UUID(uuidString: clip.id),
              let kind = ClipKind(rawValue: clip.kind), [.text, .link, .color].contains(kind),
              clip.flags == 0, clip.rtfB64 == nil, clip.payloadFile == nil, clip.filePath == nil,
              !clip.text.isEmpty, clip.text.utf8.count <= 65_536 else { return nil }
        let fields = [clip.text, clip.sourceApp ?? "", clip.ocrText ?? "", clip.colorHex ?? ""] + clip.userTags
        guard fields.allSatisfy({
            !$0.hasPrefix("enc1:") && $0.utf8.count <= 65_536 &&
            Detectors.scan(text: $0, kind: kind, sourceApp: clip.sourceApp).flags.isEmpty
        }) else { return nil }
        self.id = id
        self.kind = kind.rawValue
        self.text = clip.text
    }
}

enum AgentArchive {
    static func read(_ url: URL, passphrase: String) throws -> [SharedClip] {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let opened = try HistoryArchive.open(source: HistoryArchive.FileByteSource(file), passphrase: passphrase)
        let reader = HistoryArchive.RecordReader(chunks: HistoryArchive.ChunkReader(
            source: opened.source, key: opened.key, header: opened.header))
        let decoder = JSONDecoder()
        let first = try reader.next()
        guard first.type == HistoryArchive.RecordType.manifest.rawValue,
              try decoder.decode(HistoryArchive.Summary.self, from: first.body) == opened.summary else {
            throw HistoryArchive.ArchiveError.malformedRecord("manifest")
        }
        var result = [SharedClip]()
        var ids = Set<UUID>()
        var total = 0
        var count = 0
        while true {
            let done = try autoreleasepool {
                let record = try reader.next()
                switch HistoryArchive.RecordType(rawValue: record.type) {
                case .clip:
                    count += 1
                    let clip = try decoder.decode(HistoryArchive.Clip.self, from: record.body)
                    guard record.name == clip.id, let id = UUID(uuidString: clip.id),
                          ids.insert(id).inserted else { throw HistoryArchive.ArchiveError.malformedRecord("clip identity") }
                    if let shared = SharedClip(clip) {
                        total += shared.text.utf8.count
                        guard total <= 16 * 1024 * 1024, result.count < 4096 else {
                            throw HistoryArchive.ArchiveError.malformedRecord("shared collection too large")
                        }
                        result.append(shared)
                    }
                case .end:
                    guard record.name.isEmpty, record.body.isEmpty, count == opened.summary.clipCount,
                          try reader.atAuthenticatedEnd() else { throw HistoryArchive.ArchiveError.trailingBytes }
                    return true
                case .imageFeature, .dismissal, .payload, .pad: break
                default: throw HistoryArchive.ArchiveError.malformedRecord("unexpected record")
                }
                return false
            }
            if done { return result }
        }
    }
}
