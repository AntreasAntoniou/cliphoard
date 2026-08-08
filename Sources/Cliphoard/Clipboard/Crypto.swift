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
    private static let legacyKey: SymmetricKey? = {
        let read = readBlobStatus(account: randomAccount)
        switch read {
        case .found(let d) where d.count == 32:
            DebugLog.write("crypto: legacy key read OK")
            return SymmetricKey(data: d)
        case .found(let d):
            DebugLog.write("crypto: legacy key wrong size (\(d.count))")
        case .absent:
            DebugLog.write("crypto: legacy key absent (errSecItemNotFound)")
        case .unavailable(let s):
            DebugLog.write("crypto: legacy key DENIED, OSStatus \(s) — it exists but this "
                           + "build cannot read it")
        }
        return nil
    }()

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
        let archived = archivedKeys()
        for a in archived where !ring.contains(where: { sameKey($0, a) }) { ring.append(a) }
        let hadLegacy = legacyKey != nil
        if let lk = legacyKey, !ring.contains(where: { sameKey($0, lk) }) { ring.append(lk) }
        // Reported once, at the moment it is built. A ring that is silently empty is
        // indistinguishable from a store with nothing to recover — which is exactly how
        // two bugs in this mechanism went unnoticed until the day it was needed. Counts
        // and fingerprints only; no key material.
        let prints = ring.map { k in
            SHA256.hash(data: k.withUnsafeBytes { Data($0) }).prefix(4)
                .map { String(format: "%02x", $0) }.joined()
        }
        DebugLog.write("crypto: keyring built — \(ring.count) key(s) "
                       + "[current + \(archived.count) archived + legacy:\(hadLegacy)] "
                       + "fingerprints=\(prints.joined(separator: ","))")
        return ring
    }()

    private static func sameKey(_ a: SymmetricKey, _ b: SymmetricKey) -> Bool {
        a.withUnsafeBytes { ab in b.withUnsafeBytes { bb in ab.elementsEqual(bb) } }
    }

    /// Every previously-archived symmetric key, read from `db-archived-key-*`
    /// entries. An archived key is never deleted, only added to.
    /// Read in TWO steps — list the accounts, then fetch each one's bytes on its own.
    ///
    /// The single-query version of this did not work, and its failure was silent, which
    /// is the worst possible combination for a recovery mechanism. On macOS, asking for
    /// `kSecMatchLimitAll` together with `kSecReturnData` does not reliably return the
    /// data for multiple items; the call fails and every archived key vanishes from the
    /// ring. The keyring was introduced specifically so a re-minted key could never
    /// orphan history again — and because of this one query, it carried nothing, so it
    /// protected nothing on the day it was needed.
    ///
    /// Per-account reads are slightly more work and actually return the bytes. Failures
    /// are logged per account rather than collapsing the whole ring to empty, because a
    /// ring that is quietly empty looks exactly like a ring with nothing to recover.
    static func archivedKeys() -> [SymmetricKey] {
        let listing: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(listing as CFDictionary, &out)
        guard status == errSecSuccess, let rows = out as? [[String: Any]] else {
            DebugLog.write("crypto: archived-key listing failed, OSStatus \(status) "
                           + "(\(status == errSecItemNotFound ? "none exist" : "DENIED — keys may exist"))")
            return []
        }
        let allAccounts = rows.compactMap { $0[kSecAttrAccount as String] as? String }
        let accounts = allAccounts.filter { $0.hasPrefix(archivedPrefix) }
        DebugLog.write("crypto: keychain listing saw \(allAccounts.count) item(s) under this "
                       + "service [\(allAccounts.sorted().joined(separator: ","))], "
                       + "\(accounts.count) archived")
        var keys: [SymmetricKey] = []
        for account in accounts {
            switch readBlobStatus(account: account) {
            case .found(let data) where data.count == 32:
                keys.append(SymmetricKey(data: data))
            case .found(let data):
                NSLog("Cliphoard crypto: archived key \(account) has \(data.count) bytes, "
                      + "expected 32 — skipping")
            case .absent:
                continue   // listed then vanished; nothing to do
            case .unavailable(let s):
                NSLog("Cliphoard crypto: archived key \(account) unreadable (OSStatus \(s)) "
                      + "— rows sealed under it cannot be opened in this session")
            }
        }
        return keys
    }

    /// Archive a symmetric key so it is retained forever and keeps opening old
    /// rows. Idempotent, and NEVER deletes anything.
    /// Archive under a label derived from the KEY, not from its role.
    ///
    /// This used to take a fixed label like "se-v2", and `SecItemAdd` is insert-only, so
    /// the second distinct key to claim that label was silently not archived — the add
    /// returned duplicate-item and was ignored by design. That is how one clip on this
    /// machine became unrecoverable: an intermediate key was minted, sealed a clip, and
    /// was replaced before anything could retain it, because its slot was already taken
    /// by an earlier key. A fixed label makes the archive hold exactly one key per role
    /// forever, which is precisely what an append-only ring must not do.
    ///
    /// Suffixing a short fingerprint of the key material gives every distinct key its own
    /// slot, so re-archiving the same key is still idempotent while a NEW key always
    /// lands somewhere. The fingerprint is a truncated SHA-256 of the key bytes: it
    /// identifies without revealing, and 64 bits is ample when the set is a handful of
    /// keys on one Mac.
    static func archiveKey(_ k: SymmetricKey, label: String) {
        let raw = k.withUnsafeBytes { Data($0) }
        let fingerprint = SHA256.hash(data: raw).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        let account = archivedPrefix + label + "-" + fingerprint
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
        // No Secure Enclave, OR the Enclave key was unreadable and refused to be
        // replaced — which means this path is now the destination of that refusal and
        // must carry the same discipline, or the fix above merely relocates the damage.
        switch readBlobStatus(account: randomAccount) {
        case .found(let data) where data.count == 32:
            return SymmetricKey(data: data)

        case .found:
            // Present but the wrong size. Do not overwrite it — it is somebody's key,
            // and a length we do not recognise is a reason to stop, not to replace.
            NSLog("Cliphoard crypto: legacy key present but malformed — refusing to "
                  + "replace it. Using an EPHEMERAL key for this session; nothing "
                  + "already stored will be re-sealed.")
            return SymmetricKey(size: .bits256)

        case .unavailable(let status):
            // The key almost certainly exists and this process simply cannot read it.
            // Minting here would delete-then-add over it and orphan every sealed row —
            // the exact failure that cost 202 clips. Use a session-only key instead: it
            // seals nothing that matters, because safe mode will refuse to write once it
            // sees the store is unreadable.
            NSLog("Cliphoard crypto: legacy key unreadable (OSStatus \(status)) — NOT "
                  + "first run, so refusing to mint over it. Using an ephemeral session "
                  + "key; no existing data is touched.")
            return SymmetricKey(size: .bits256)

        case .absent:
            // Genuinely first run: nothing to destroy.
            let fresh = SymmetricKey(size: .bits256)
            storeRandomKey(fresh, account: randomAccount)
            archiveKey(fresh, label: "random-v1")
            return fresh
        }
    }

    /// Load-or-create a Secure-Enclave key-agreement private key and derive a
    /// stable 256-bit symmetric key from it. Returns nil if the Enclave rejects
    /// the operation (we then fall back to the random key).
    private static func secureEnclaveKey() -> SymmetricKey? {
        let priv: SecureEnclave.P256.KeyAgreement.PrivateKey

        // Switch on WHICH read outcome occurred. Minting is reachable from exactly one
        // of the three, and that is the entire safety property of this function.
        switch readBlobStatus(account: seAccount) {

        case .found(let blob):
            if let restored = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob) {
                priv = restored
            } else {
                // Present but will not restore. NEVER mint over it: `storeBlob`
                // deletes-then-adds, so a replacement destroys the only key that opens
                // everything already sealed. Degraded encryption is recoverable; a
                // destroyed key is not.
                NSLog("Cliphoard crypto: SE key blob present but unrestorable — refusing "
                      + "to overwrite. Falling back to the legacy key; data stays sealed.")
                return nil
            }

        case .unavailable(let status):
            // The key may well be sitting there, perfectly intact, behind a locked
            // keychain or an ACL this build cannot satisfy. This is the case that
            // previously looked identical to first run, and minting here is exactly how
            // a working store becomes unreadable in one launch. Refuse.
            NSLog("Cliphoard crypto: SE key unreadable (OSStatus \(status)) — this is NOT "
                  + "first run, so refusing to mint a replacement. Falling back to the "
                  + "legacy key. Nothing has been overwritten or re-sealed.")
            return nil

        case .absent:
            // Genuinely no item. Only here is minting safe, because there is nothing to
            // destroy — and `absent` now means precisely errSecItemNotFound, not "any
            // failure whatsoever".
            do {
                let fresh = try SecureEnclave.P256.KeyAgreement.PrivateKey()
                storeBlob(fresh.dataRepresentation, account: seAccount)
                priv = fresh
            } catch {
                NSLog("Cliphoard crypto: SE key create failed: \(error)")
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

    /// What a keychain read actually found. The distinction is load-bearing: only
    /// `.absent` may lead to minting a new key.
    enum BlobRead {
        /// The item exists and we read it.
        case found(Data)
        /// `errSecItemNotFound` — genuinely not there. This, and ONLY this, means
        /// first run.
        case absent
        /// The item may well exist; this process could not read it (keychain locked,
        /// access denied, entitlement or ACL mismatch after a re-sign, daemon
        /// unavailable). Treating this as absence is what destroys a key.
        case unavailable(OSStatus)
    }

    /// Reads a key blob, reporting WHICH failure occurred.
    ///
    /// This used to collapse every non-success status into `nil`, and that single line
    /// is how a key gets destroyed. `errSecItemNotFound` and `errSecInteractionNotAllowed`
    /// became the same value, so a caller asking "is there a key?" could not distinguish
    /// "no, this is first run" from "yes, but I can't see it right now" — and the mint
    /// path runs on the first reading while the second means the existing key is about to
    /// be overwritten. An earlier fix guarded the case where a blob comes back and will
    /// not restore; it could not guard this one, because here nothing comes back at all.
    private static func readBlobStatus(account: String) -> BlobRead {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let data = out as? Data else { return .unavailable(status) }
            return .found(data)
        case errSecItemNotFound:
            return .absent
        default:
            NSLog("Cliphoard crypto: keychain read for \(account) failed with OSStatus "
                  + "\(status) — treating as PRESENT-BUT-UNREADABLE and refusing to "
                  + "replace it. Nothing will be re-sealed.")
            return .unavailable(status)
        }
    }

    /// Convenience for callers that genuinely only care about the bytes — never for the
    /// key-minting decision, which must switch on the status.
    private static func readBlob(account: String) -> Data? {
        if case .found(let data) = readBlobStatus(account: account) { return data }
        return nil
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
