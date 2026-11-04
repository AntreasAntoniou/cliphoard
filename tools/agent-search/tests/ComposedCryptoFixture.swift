import Foundation
import CryptoKit
// Public synthetic key only. No Security import, Keychain calls, or user history.
enum Crypto {
 static let key = SymmetricKey(data: Data(0..<32))
 static var failSeal = false
 static func simulatingEphemeralKey<T>(_ body: () throws -> T) rethrows -> T { failSeal = true; defer { failSeal = false }; return try body() }
 static func sealStrict(_ value: String) -> String? { guard !failSeal, let box = try? AES.GCM.seal(Data(value.utf8), using: key), let combined = box.combined else { return nil }; return "enc1:" + combined.base64EncodedString() }
 static func sealStrict(_ value: Data) -> Data? { guard !failSeal, let box = try? AES.GCM.seal(value, using: key), let combined = box.combined else { return nil }; return Data("enc1:".utf8) + combined }
 static func open(_ value: String) -> String { guard value.hasPrefix("enc1:"), let data = Data(base64Encoded: String(value.dropFirst(5))), let box = try? AES.GCM.SealedBox(combined: data), let plain = try? AES.GCM.open(box, using: key), let text = String(data: plain, encoding: .utf8) else { return value }; return text }
 static func open(_ value: Data?) -> Data? { guard let value else { return nil }; guard isSealed(value), let box = try? AES.GCM.SealedBox(combined: Data(value.dropFirst(5))), let plain = try? AES.GCM.open(box, using: key) else { return value }; return plain }
 static func isSealed(_ value: String) -> Bool { value.hasPrefix("enc1:") }
 static func isSealed(_ value: Data) -> Bool { value.starts(with: Data("enc1:".utf8)) }
}
enum TagBasket { static let persistedVocabularyKey = "AgentStorageFixture.unusedTagVocabulary" }
