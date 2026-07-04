import Foundation
import CryptoKit
import Security

/// At-rest encryption for clipboard content. Sensitive text/blobs are encrypted
/// with AES-GCM before they reach SQLite.
///
/// The AES key is protected by the **Secure Enclave** where available: a P-256
/// key-agreement private key is generated *inside* the Enclave (its material can
/// never be extracted from the chip), and the symmetric key is deterministically
/// derived from it via key agreement + HKDF. Copying the on-disk keychain blob to
/// another machine is therefore useless — only this Mac's Enclave can re-derive
/// the key, and no Touch-ID prompt is required. On Macs without a Secure Enclave
/// (old Intel without a T2) it falls back to a random key in the login Keychain.
///
/// Failure is always non-destructive: a seal/open error returns the original value
/// rather than risking history loss, and `open` falls back to the previous key so
/// data sealed before a re-key still decrypts.
enum Crypto {
    private static let marker = "enc1:"
    private static let markerData = Data("enc1:".utf8)
    private static let service = "ai.axiotic.ditto"
    private static let randomAccount = "db-key-v1"        // legacy/random key
    private static let seAccount = "db-se-key-v2"         // Secure-Enclave key blob

    /// The active key used for all NEW seals.
    private static let key: SymmetricKey = resolveKey()
    /// The previous random key, kept only to decrypt rows sealed before a re-key.
    private static let legacyKey: SymmetricKey? = readRandomKey(account: randomAccount)

    /// True when the active key is bound to this Mac's Secure Enclave.
    private(set) static var usesSecureEnclave = false

    // MARK: Strings

    static func seal(_ plain: String) -> String {
        guard let data = plain.data(using: .utf8),
              let box = try? AES.GCM.seal(data, using: key),
              let combined = box.combined else { return plain }
        return marker + combined.base64EncodedString()
    }

    static func open(_ stored: String) -> String {
        guard stored.hasPrefix(marker) else { return stored }
        guard let data = Data(base64Encoded: String(stored.dropFirst(marker.count))) else { return stored }
        if let s = decryptString(data, with: key) { return s }
        if let lk = legacyKey, let s = decryptString(data, with: lk) { return s }   // pre-rekey rows
        return stored
    }

    private static func decryptString(_ data: Data, with k: SymmetricKey) -> String? {
        guard let box = try? AES.GCM.SealedBox(combined: data),
              let opened = try? AES.GCM.open(box, using: k) else { return nil }
        return String(data: opened, encoding: .utf8)
    }

    // MARK: Data (e.g. RTF / image blobs)

    static func seal(_ plain: Data?) -> Data? {
        guard let plain, let box = try? AES.GCM.seal(plain, using: key),
              let combined = box.combined else { return plain }
        return markerData + combined
    }

    static func open(_ stored: Data?) -> Data? {
        guard let stored else { return nil }
        guard stored.starts(with: markerData) else { return stored }
        let body = stored.dropFirst(markerData.count)
        if let d = decryptData(body, with: key) { return d }
        if let lk = legacyKey, let d = decryptData(body, with: lk) { return d }
        return stored
    }

    private static func decryptData(_ body: Data.SubSequence, with k: SymmetricKey) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: body),
              let opened = try? AES.GCM.open(box, using: k) else { return nil }
        return opened
    }

    /// True when `data` already begins with the `enc1:` seal marker, i.e. it was
    /// produced by `seal(_:Data?)` and must be `open`-ed before use. Read-only:
    /// lets callers (the image-encryption migration) skip already-sealed payloads
    /// without round-tripping through `open`. Does not affect seal/open semantics.
    static func isSealed(_ data: Data?) -> Bool {
        guard let data else { return false }
        return data.starts(with: markerData)
    }

    // MARK: Key resolution

    private static func resolveKey() -> SymmetricKey {
        if SecureEnclave.isAvailable, let k = secureEnclaveKey() {
            usesSecureEnclave = true
            return k
        }
        // No Secure Enclave: keep using the random Keychain key (unchanged).
        if let existing = readRandomKey(account: randomAccount) { return existing }
        let fresh = SymmetricKey(size: .bits256)
        storeRandomKey(fresh, account: randomAccount)
        return fresh
    }

    /// Load-or-create a Secure-Enclave key-agreement private key and derive a
    /// stable 256-bit symmetric key from it. Returns nil if the Enclave rejects
    /// the operation (we then fall back to the random key).
    private static func secureEnclaveKey() -> SymmetricKey? {
        let priv: SecureEnclave.P256.KeyAgreement.PrivateKey
        if let blob = readBlob(account: seAccount),
           let restored = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob) {
            priv = restored
        } else {
            do {
                let fresh = try SecureEnclave.P256.KeyAgreement.PrivateKey()
                storeBlob(fresh.dataRepresentation, account: seAccount)
                priv = fresh
            } catch {
                NSLog("Cliphoard Crypto: SE key create failed: \(error)")
                return nil
            }
        }
        // Deterministic key agreement with our own public key → HKDF → AES key.
        guard let shared = try? priv.sharedSecretFromKeyAgreement(with: priv.publicKey) else { return nil }
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data("yank.db.v2".utf8), sharedInfo: Data(), outputByteCount: 32)
    }

    // MARK: Keychain helpers

    private static func readRandomKey(account: String) -> SymmetricKey? {
        guard let data = readBlob(account: account), data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }
    private static func storeRandomKey(_ key: SymmetricKey, account: String) {
        storeBlob(key.withUnsafeBytes { Data($0) }, account: account)
    }

    private static func readBlob(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }
    private static func storeBlob(_ data: Data, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // ThisDeviceOnly: the at-rest key must never leave this Mac. Non-migratable
            // items are excluded from keychain backups / Migration Assistant, so the raw
            // AES-256 key cannot travel alongside the encrypted DB on non-Secure-Enclave Macs.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
}
