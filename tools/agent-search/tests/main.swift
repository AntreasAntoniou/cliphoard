// Test-only reader. Produces a real encrypted archive with invented contents,
// verifies it through the production reader, then exercises damage handling.
import Foundation
import CryptoKit

typealias A = HistoryArchive
func clip(_ text: String, _ tags: [String] = ["agent-share"]) -> A.Clip {
    A.Clip(id: UUID().uuidString, kind: "text", text: text, createdAt: 1, lastUsedAt: 1,
           pinned: false, useCount: 0, userTags: tags, flags: 0)
}
var allowed = clip("The red bicycle. " + String(repeating: "pedal ", count: 800))
allowed.id = "00000000-0000-4000-8000-000000000001"
var hidden = clip("The red bicycle hidden note", [])
hidden.id = "00000000-0000-4000-8000-000000000002"
var flagged = clip("red bicycle private")
flagged.flags = 1 << 20
var rich = clip("red bicycle formatted")
rich.rtfB64 = "YQ=="
var legacy = clip("red bicycle with an old unflagged sign-in")
legacy.sourceApp = "com.1password.1password"
var secret = clip("-----BEGIN PRIVATE KEY-----")
let entries = [allowed, hidden, flagged, rich, legacy, secret]
let summary = A.Summary(appVersion: "fixture", exportedAt: "", machineName: "Test Mac",
    clipCount: entries.count, byKind: ["text": entries.count], pinnedCount: 0, oldestCreatedAt: 1,
    newestCreatedAt: 1, payloadCount: 0, payloadBytes: 0, imageFeatureCount: 0,
    dismissalCount: 0, embeddingsIncluded: false, imageFeaturesIncluded: false,
    skippedUnreadableClips: 0, skippedUnreadablePayloads: 0)
let passphrase = "synthetic archive fixture"
let salt = A.randomBytes(A.kdfSaltLength)!
let prefix = A.randomBytes(4)!
let key = A.deriveKey(passphrase: passphrase, salt: salt, iterations: A.kdfRoundsFloor)!
let header = A.Header(kdfIterations: A.kdfRoundsFloor, kdfSalt: salt, noncePrefix: prefix,
                      chunkSize: A.minChunkSize)
var bytes = header.encoded
let box = try AES.GCM.seal(try summary.paddedPlaintext(), using: key,
    nonce: AES.GCM.Nonce(data: prefix + A.be64(0)), authenticating: bytes)
bytes += box.ciphertext + box.tag
let writer = A.RecordWriter(chunks: A.ChunkWriter(key: key, noncePrefix: prefix,
    header: header.encoded, chunkSize: Int(A.minChunkSize), sink: { bytes.append($0) }))
try writer.write(.manifest, name: "manifest.json", body: summary.json)
for item in entries {
    try writer.write(.clip, name: item.id, body: JSONEncoder().encode(item))
}
try writer.finishWithPadAndEnd()
let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: url) }
try bytes.write(to: url, options: .withoutOverwriting)
let result = try AgentArchive.read(url, passphrase: passphrase)
precondition(result.map(\.id.uuidString) == [allowed.id])
precondition((try? AgentArchive.read(url, passphrase: "wrong fixture passphrase")) == nil)
try (bytes + Data([1])).write(to: url)
precondition((try? AgentArchive.read(url, passphrase: passphrase)) == nil)
FileHandle.standardOutput.write(try JSONEncoder().encode(result))
