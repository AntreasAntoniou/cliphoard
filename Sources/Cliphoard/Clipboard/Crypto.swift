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

    /// Fail-CLOSED seal: returns the `enc1:`-marked ciphertext, or `nil` if
    /// encryption did not actually produce sealed output. Unlike `seal(_:)`
    /// (which returns the plaintext unchanged on failure, to avoid history loss),
    /// this NEVER returns plaintext — callers persisting content at rest use it so
    /// a seal failure aborts the write instead of leaking cleartext to disk.
    /// AES-GCM seal effectively never fails on valid input; this is a safety
    /// backstop, not an expected path.
    static func sealStrict(_ plain: String) -> String? {
        let out = seal(plain)
        return out.hasPrefix(marker) ? out : nil
    }

    /// Fail-CLOSED seal for blob content (RTF / vectors). `nil` on seal failure;
    /// never returns the plaintext bytes. See `sealStrict(_:String)`.
    static func sealStrict(_ plain: Data) -> Data? {
        guard let out = seal(plain), out.starts(with: markerData) else { return nil }
        return out
    }

    /// Unseal, tolerating rows that were sealed MORE THAN ONCE.
    ///
    /// A one-time migration (`encryptExistingRowsIfNeeded` / `reKeyToSecureEnclave`)
    /// re-`insert`s every row, and `insert` seals whatever it is handed. If such a
    /// pass ever ran while a row's text was still sealed in memory, the row was
    /// sealed a second time — and a single unwrap then returns a string that still
    /// begins with `enc1:`, which is exactly what the UI was rendering.
    ///
    /// Unwrapping repeatedly is safe because a layer is only peeled when it
    /// genuinely DECRYPTS: text that merely looks like a marker (a user really did
    /// copy "enc1:…") fails to decrypt and is returned untouched. The round cap
    /// bounds the work on adversarial input.
    static func open(_ stored: String) -> String {
        var current = stored
        for _ in 0..<maxUnsealRounds {
            guard current.hasPrefix(marker),
                  let data = Data(base64Encoded: String(current.dropFirst(marker.count)))
            else { return current }
            // Try EVERY key on the ring, not just the current one — see `keyring`.
            guard let s = keyring.lazy.compactMap({ decryptString(data, with: $0) }).first
            else { return current }
            current = s
        }
        return current
    }

    /// Enough to undo an accidental double- or triple-seal without letting a
    /// crafted payload spin here.
    private static let maxUnsealRounds = 4

    // MARK: Diagnostics (read-only; used by --crypto-diagnostics)

    /// Whether the pre-Secure-Enclave random key is readable in this process.
    /// If it is NOT, rows sealed under it cannot be opened here even though the
    /// data is intact — which distinguishes "wrong key" from "corrupt data".
    static var legacyKeyAvailable: Bool { legacyKey != nil }

    /// Explains, in words, what happens when unsealing `stored` — which layer
    /// opens with which key, and where it stops.
    static func unsealProbe(_ stored: String) -> String {
        var current = stored
        var steps: [String] = []
        for round in 1...maxUnsealRounds {
            guard current.hasPrefix(marker) else { return (steps + ["plaintext after \(round - 1) round(s)"]).joined(separator: " -> ") }
            guard let data = Data(base64Encoded: String(current.dropFirst(marker.count))) else {
                return (steps + ["round \(round): not valid base64"]).joined(separator: " -> ")
            }
            var opened: String?
            for (i, k) in keyring.enumerated() where opened == nil {
                if let s = decryptString(data, with: k) { opened = s; steps.append("round \(round): opened with keyring[\(i)]") }
            }
            guard let s = opened else {
                return (steps + ["round \(round): FAILED with all \(keyring.count) keyring key(s)"]).joined(separator: " -> ")
            }
            current = s
        }
        return steps.joined(separator: " -> ")
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

    /// Data counterpart of `open(_: String)` — same multi-round unwrap, same
    /// reasoning (RTF and image payloads went through the same migrations).
    static func open(_ stored: Data?) -> Data? {
        guard var current = stored else { return nil }
        for _ in 0..<maxUnsealRounds {
            guard current.starts(with: markerData) else { return current }
            let body = current.dropFirst(markerData.count)
            guard let d = keyring.lazy.compactMap({ decryptData(body, with: $0) }).first
            else { return current }
            current = d
        }
        return current
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
    /// True when `text` STILL carries the seal marker after `open` — i.e. it could
    /// not be decrypted by any key on the ring. This is the "unreadable row"
    /// predicate the safe-mode gate counts.
    static func isSealed(_ text: String) -> Bool { text.hasPrefix(marker) }

    static func isSealed(_ data: Data?) -> Bool {
        guard let data else { return false }
        return data.starts(with: markerData)
    }

    // MARK: - The keyring (append-only)

    /// EVERY key this Mac has ever sealed with, newest first.
    ///
    /// The rule that makes catastrophic loss structurally impossible: keys are
    /// **append-only**. `open` tries all of them, so rotating, re-keying, or
    /// failing to restore a key can never orphan data — it only ever adds a
    /// candidate. This exists because the opposite (a key path that could
    /// delete-then-add) silently destroyed 202 clips: the key that sealed them
    /// was replaced, and with one key there was nothing else to try.
    ///
    /// Order matters only for speed, never for correctness — the newest key opens
    /// the newest rows, so it is tried first.
    private static let keyring: [SymmetricKey] = {
        var ring: [SymmetricKey] = [key]
        for archived in archivedKeys() where !ring.contains(where: { sameKey($0, archived) }) {
            ring.append(archived)
        }
        if let lk = legacyKey, !ring.contains(where: { sameKey($0, lk) }) { ring.append(lk) }
        return ring
    }()

    private static func sameKey(_ a: SymmetricKey, _ b: SymmetricKey) -> Bool {
        a.withUnsafeBytes { ab in b.withUnsafeBytes { bb in ab.elementsEqual(bb) } }
    }

    /// Every previously-archived symmetric key, read from `db-archived-key-*`
    /// entries. An archived key is never deleted, only added to.
    private static func archivedKeys() -> [SymmetricKey] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let rows = out as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let account = row[kSecAttrAccount as String] as? String,
                  account.hasPrefix(archivedPrefix),
                  let data = row[kSecValueData as String] as? Data, data.count == 32
            else { return nil }
            return SymmetricKey(data: data)
        }
    }

    /// Archive a symmetric key so it is retained forever and keeps opening old
    /// rows. Idempotent, and NEVER deletes anything.
    static func archiveKey(_ k: SymmetricKey, label: String) {
        let raw = k.withUnsafeBytes { Data($0) }
        let account = archivedPrefix + label
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: raw,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)   // errSecDuplicateItem is fine: already archived
    }

    private static let archivedPrefix = "db-archived-key-"

    // MARK: - Canary (can we still read our own data?)

    private static let canaryAccount = "db-canary-v1"
    private static let canaryPlaintext = "cliphoard-canary-v1"

    /// False when a canary sealed by a PREVIOUS run no longer opens — i.e. this
    /// process cannot read data it previously wrote. The app must then enter safe
    /// mode: no migrations, no re-sealing, nothing that could compound the damage.
    ///
    /// The canary is what turns silent, total loss into a loud, contained fault.
    /// Without it the app cheerfully ran re-sealing migrations while 87% of rows
    /// were failing to decrypt.
    private(set) static var decryptionHealthy = true

    /// Verify (or, on first run, establish) the canary. Call once at startup,
    /// BEFORE any migration.
    @discardableResult
    static func verifyCanary() -> Bool {
        guard let stored = readBlob(account: canaryAccount),
              let sealedText = String(data: stored, encoding: .utf8) else {
            // First run (or canary lost): establish one under the current key.
            if let sealed = sealStrict(canaryPlaintext),
               let data = sealed.data(using: .utf8) {
                storeBlob(data, account: canaryAccount)
            }
            decryptionHealthy = true
            return true
        }
        decryptionHealthy = (open(sealedText) == canaryPlaintext)
        if !decryptionHealthy {
            NSLog("Cliphoard Crypto: CANARY FAILED — this process cannot decrypt data it previously "
                  + "wrote. Entering safe mode; no migration or re-seal will run.")
        }
        return decryptionHealthy
    }

    // MARK: Key resolution

    private static func resolveKey() -> SymmetricKey {
        if SecureEnclave.isAvailable, let k = secureEnclaveKey() {
            usesSecureEnclave = true
            // Archive every derived key the moment it is used, so it stays on the
            // ring forever and can always reopen whatever it sealed.
            archiveKey(k, label: "se-v2")
            return k
        }
        // No Secure Enclave: keep using the random Keychain key (unchanged).
        if let existing = readRandomKey(account: randomAccount) { return existing }
        let fresh = SymmetricKey(size: .bits256)
        storeRandomKey(fresh, account: randomAccount)
        archiveKey(fresh, label: "random-v1")
        return fresh
    }

    /// Load-or-create a Secure-Enclave key-agreement private key and derive a
    /// stable 256-bit symmetric key from it. Returns nil if the Enclave rejects
    /// the operation (we then fall back to the random key).
    private static func secureEnclaveKey() -> SymmetricKey? {
        let priv: SecureEnclave.P256.KeyAgreement.PrivateKey
        let existingBlob = readBlob(account: seAccount)

        if let blob = existingBlob,
           let restored = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob) {
            priv = restored
        } else if existingBlob != nil {
            // A key blob EXISTS but will not restore. NEVER mint a replacement
            // here: `storeBlob` deletes-then-adds, so overwriting would destroy
            // the only key that can open everything already sealed under it —
            // silent, total, unrecoverable loss of history (this happened once;
            // 202 clips were orphaned). Fail closed instead and let the caller
            // fall back to the legacy random key. Degraded encryption is
            // recoverable; a destroyed key is not.
            NSLog("Cliphoard Crypto: SE key blob present but unrestorable — refusing to overwrite it. "
                  + "Falling back to the legacy key; existing data stays readable.")
            return nil
        } else {
            // No blob at all: first run on this Mac, so minting one destroys nothing.
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
