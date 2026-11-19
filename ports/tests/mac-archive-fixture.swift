import Foundation
import CryptoKit

// Compiled alongside the shipping Mac byte-format implementation. Generated data only.
@main struct ArchiveFixture {
    static let passphrase = "synthetic café 2026"
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3 else { fatalError("write|verify and path required") }
        let url = URL(fileURLWithPath: args[2])
        if args[1] == "write" {
            let clip = HistoryArchive.Clip(id: "635196A2-87CD-4531-927D-C58813637647", kind: "text",
                text: "[CLIPHOARD_SYNTHETIC_V1] Café\nSecond line 中文", rtfB64: nil,
                payloadFile: nil, filePath: nil, colorHex: nil, createdAt: 815000000.125,
                lastUsedAt: 815000100.5, pinned: true, sourceApp: "Synthetic Mac fixture",
                useCount: 7, userTags: ["synthetic", "café"], flags: 8, shape: "note", ocrText: nil)
            let summary = HistoryArchive.Summary(appVersion: "fixture", exportedAt: "2026-11-16T00:00:00Z",
                machineName: "Synthetic", clipCount: 1, byKind: ["text": 1], pinnedCount: 1,
                oldestCreatedAt: clip.createdAt, newestCreatedAt: clip.createdAt,
                payloadCount: 0, payloadBytes: 0, imageFeatureCount: 0, dismissalCount: 1,
                embeddingsIncluded: false, imageFeaturesIncluded: true,
                skippedUnreadableClips: 0, skippedUnreadablePayloads: 0)
            let header = HistoryArchive.Header(kdfIterations: 600000,
                kdfSalt: Data(0..<16), noncePrefix: Data([16, 17, 18, 19]), chunkSize: 65536)
            let key = HistoryArchive.deriveKey(passphrase: passphrase, salt: header.kdfSalt, iterations: header.kdfIterations)!
            var output = header.encoded
            let sealed = try AES.GCM.seal(summary.paddedPlaintext(), using: key,
                nonce: AES.GCM.Nonce(data: header.noncePrefix + HistoryArchive.be64(0)), authenticating: header.encoded)
            output.append(sealed.ciphertext); output.append(sealed.tag)
            let chunks = HistoryArchive.ChunkWriter(key: key, noncePrefix: header.noncePrefix,
                header: header.encoded, chunkSize: 65536, sink: { output.append($0) })
            let records = HistoryArchive.RecordWriter(chunks: chunks)
            try records.write(.manifest, name: "manifest.json", body: summary.json)
            try records.write(.clip, name: clip.id, body: HistoryArchive.Summary.encoder().encode(clip))
            try records.write(.dismissal, name: clip.id, body: HistoryArchive.Summary.encoder().encode(HistoryArchive.DismissalRecord(tag: "synthetic-dismissal")))
            try records.finishWithPadAndEnd()
            try output.write(to: url)
            print("Generated Mac archive \(output.count) bytes SHA256 \(HistoryArchive.sha256Hex(output))")
        } else if args[1] == "verify-live-ui" {
            let opened = try HistoryArchive.open(source: HistoryArchive.DataByteSource(Data(contentsOf: url)), passphrase: "synthetic fixture share key")
            let reader = HistoryArchive.RecordReader(chunks: HistoryArchive.ChunkReader(source: opened.source, key: opened.key, header: opened.header))
            var clips = 0, payloads = 0, bytes = 0, ended = false
            while !ended {
                let record = try reader.next()
                switch HistoryArchive.RecordType(rawValue: record.type) {
                case .manifest:
                    guard try JSONDecoder().decode(HistoryArchive.Summary.self, from: record.body) == opened.summary else { fatalError("Summary mismatch") }
                case .clip:
                    _ = try JSONDecoder().decode(HistoryArchive.Clip.self, from: record.body)
                    clips += 1
                case .payload:
                    guard record.name == HistoryArchive.sha256Hex(record.body) + ".png" else { fatalError("Payload identity mismatch") }
                    payloads += 1
                    bytes += record.body.count
                case .end: ended = true
                case .pad, .dismissal, .imageFeature: break
                default: fatalError("Unexpected record")
                }
            }
            guard try reader.atAuthenticatedEnd(), clips > 0, clips == opened.summary.clipCount,
                payloads == opened.summary.payloadCount, bytes == opened.summary.payloadBytes else { fatalError("Incomplete UI archive") }
            print("Shipping Mac reader verified live Windows UI archive: \(clips) clips, \(payloads) PNG payloads")
        } else if args[1] == "verify-ui" {
            let opened = try HistoryArchive.open(source: HistoryArchive.DataByteSource(Data(contentsOf: url)), passphrase: "syntheticarchive2026")
            let reader = HistoryArchive.RecordReader(chunks: HistoryArchive.ChunkReader(source: opened.source, key: opened.key, header: opened.header))
            var clips = 0, payloads = 0, bytes = 0, pinned = 0, ocr = false, tagged = false, ended = false
            while !ended {
                let record = try reader.next()
                switch HistoryArchive.RecordType(rawValue: record.type) {
                case .manifest:
                    guard try JSONDecoder().decode(HistoryArchive.Summary.self, from: record.body) == opened.summary else { fatalError("Summary mismatch") }
                case .clip:
                    let clip = try JSONDecoder().decode(HistoryArchive.Clip.self, from: record.body)
                    clips += 1
                    if clip.pinned { pinned += 1 }
                    if clip.ocrText?.contains("SYNTHETIC CLIPBOARD 2026") == true { ocr = true }
                    if clip.userTags.contains("syntheticreview") { tagged = true }
                case .payload:
                    guard record.name == HistoryArchive.sha256Hex(record.body) + ".png" else { fatalError("Payload identity mismatch") }
                    payloads += 1; bytes += record.body.count
                case .end: ended = true
                case .pad: break
                default: fatalError("Unexpected record")
                }
            }
            guard try reader.atAuthenticatedEnd(), clips == 6, payloads == 2, pinned == 1, ocr, tagged,
                clips == opened.summary.clipCount, payloads == opened.summary.payloadCount,
                bytes == opened.summary.payloadBytes else { fatalError("UI archive fields changed") }
            print("Shipping Mac reader verified six UI-exported clips, two PNG payloads, OCR, pin and user tag")
        } else {
            let opened = try HistoryArchive.open(source: HistoryArchive.DataByteSource(Data(contentsOf: url)), passphrase: passphrase)
            let reader = HistoryArchive.RecordReader(chunks: HistoryArchive.ChunkReader(source: opened.source, key: opened.key, header: opened.header))
            var clips = 0, dismissals = 0, ended = false
            while !ended {
                let record = try reader.next()
                switch HistoryArchive.RecordType(rawValue: record.type) {
                case .manifest:
                    guard try JSONDecoder().decode(HistoryArchive.Summary.self, from: record.body) == opened.summary else { fatalError("Summary mismatch") }
                case .clip:
                    let clip = try JSONDecoder().decode(HistoryArchive.Clip.self, from: record.body)
                    guard clip.text == "[CLIPHOARD_SYNTHETIC_V1] Café\nSecond line 中文",
                        clip.createdAt == 815000000.125, clip.lastUsedAt == 815000100.5,
                        clip.useCount == 7, clip.flags == 8, clip.userTags == ["synthetic", "café"], clip.shape == "note", clip.pinned else { fatalError("Fields changed") }
                    clips += 1
                case .dismissal:
                    guard try JSONDecoder().decode(HistoryArchive.DismissalRecord.self, from: record.body).tag == "synthetic-dismissal" else { fatalError("Dismissal changed") }; dismissals += 1
                case .end: ended = true
                case .pad: break
                default: fatalError("Unexpected record")
                }
            }
            guard try reader.atAuthenticatedEnd(), clips == 1, dismissals == 1 else { fatalError("Incomplete archive") }
            print("Shipping Mac reader verified Windows archive and preserved fields")
        }
    }
}
