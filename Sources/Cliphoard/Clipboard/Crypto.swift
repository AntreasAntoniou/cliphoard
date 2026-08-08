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

    /// True when the key in use was created for THIS PROCESS ONLY and is not stored
    /// anywhere. Anything sealed with it becomes unreadable the moment the app exits.
    ///
    /// This is the fact the whole codebase was missing, and its absence is what made three
    /// separate paths destroy data. Every "fail closed" check verifies that ciphertext was
    /// PRODUCED — and sealing always succeeds; it is opening that fails. So a guard reading
    /// "the sealed archive was written, therefore deleting the original is safe" is
    /// satisfied by a seal guaranteed to be unreadable tomorrow.
    ///
    /// Consumed in exactly three places, which is why one flag closes three holes:
    ///   • `decryptionHealthy` is forced false, so the freeze cannot be certified away;
    ///   • `sealStrict` REFUSES, so no fail-closed writer can persist doomed ciphertext;
    ///   • the diagnostic archive-and-delete tool refuses to run.
    /// None of those three had to learn the rule individually.
    private(set) static var keyIsEphemeral = false

    /// Force key resolution, so `keyIsEphemeral` is AUTHORITATIVE rather than eventually
    /// correct.
    ///
    /// The flag is set as a side effect of resolving the key, and the key resolves lazily
    /// on first use. Every guard that read the flag therefore ran BEFORE the thing that
    /// set it: the fail-closed seal checked the flag, then called the seal that forced
    /// resolution — so the FIRST such call in a process sailed through and returned
    /// ciphertext under a key that would not survive. The app's very first crypto touch
    /// is the canary, which is exactly the hole this was meant to close.
    ///
    /// Every guard calls this first. Cheap: resolution happens once per process.
    @discardableResult
    static func ensureKeyResolved() -> Bool {
        _ = key
        return keyIsEphemeral
    }

    /// Run `body` as though the active key were ephemeral, then restore.
    ///
    /// A test seam, and a necessary one: the ephemeral state only arises when the
    /// keychain is unreachable, which is not a condition a test can arrange. Without
    /// this, every test of the most consequential guard in the product SKIPS — four
    /// tests providing zero coverage, which is how the original defect survived review.
    ///
    /// It changes no production behaviour: nothing outside tests calls it, and it always
    /// restores the previous value. The alternative — asserting against a local copy of
    /// the logic — is what let a reintroduced bug pass a full green suite earlier today.
    static func simulatingEphemeralKey<T>(_ body: () throws -> T) rethrows -> T {
        // Resolve FIRST, then set the flag. Otherwise the guards inside `body` call
        // `ensureKeyResolved`, that triggers resolution for the first time, and resolution
        // ASSIGNS the flag — clearing the simulation before it is ever read. A real test
        // failure caught this: the fail-closed seal returned ciphertext inside a block
        // that had explicitly asked for the ephemeral state.
        //
        // Production is unaffected: there, resolution happens once and is the only thing
        // that sets the flag. This ordering hazard exists solely because the seam writes a
        // value the resolver also owns — which is worth knowing about any test hook that
        // mutates state the code under test also mutates.
        ensureKeyResolved()
        let previous = keyIsEphemeral
        keyIsEphemeral = true
        defer { keyIsEphemeral = previous }
        return try body()
    }

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
        // REFUSE under an ephemeral key. Every caller of this function treats a non-nil
        // result as "safely stored, the original may now be discarded" — the legacy
        // import literally deletes the plaintext history on the strength of it. But
        // sealing ALWAYS succeeds; it is opening that fails. Producing ciphertext under a
        // key that dies with the process satisfies the old check and guarantees the data
        // is unreadable tomorrow. Fail-closed has to mean "readable later", not
        // "encrypted now".
        guard !ensureKeyResolved() else {
            NSLog("Cliphoard crypto: refusing a fail-closed seal — the key is EPHEMERAL "
                  + "and anything sealed with it is unreadable after this process exits.")
            return nil
        }
        let out = seal(plain)
        return out.hasPrefix(marker) ? out : nil
    }

    /// Fail-CLOSED seal for blob content (RTF / vectors). `nil` on seal failure;
    /// never returns the plaintext bytes. See `sealStrict(_:String)`.
    static func sealStrict(_ plain: Data) -> Data? {
        guard !ensureKeyResolved() else { return nil }   // see sealStrict(_:String)
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

    /// True when a key EXISTS and this process could not read it — most often because
    /// the Mac was in dark wake and no prompt could be shown to anyone.
    ///
    /// Distinct from corruption and from absence, and worth distinguishing in the
    /// interface: the history is intact and the condition is usually transient, which is
    /// a very different message from "something is broken". It is also the condition
    /// that must never be mistaken for first run.
    private(set) static var keychainAccessDenied = false

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
        // Switch on WHY the read failed. Reading through the collapse-to-nil helper made
        // this check defeat itself: under a keychain denial the read returned nothing, the
        // code took the first-run branch, OVERWROTE the canary under whatever key it had,
        // and declared decryption healthy — in the one situation the canary exists to
        // detect. A health check that reports health precisely when it cannot see is
        // worse than no health check, because everything downstream trusts it.
        let read = readBlobStatus(account: canaryAccount)

        if case .unavailable(let status) = read {
            decryptionHealthy = false
            NSLog("Cliphoard crypto: CANARY UNREADABLE (OSStatus \(status)) — this process "
                  + "cannot reach its own keychain. Entering safe mode; nothing will be "
                  + "migrated, re-sealed or deleted, and the canary is NOT overwritten.")
            DebugLog.write("crypto: canary unreadable, OSStatus \(status) — safe mode")
            return false
        }

        guard case .found(let stored) = read,
              let sealedText = String(data: stored, encoding: .utf8) else {
            // Genuinely absent: first run, or the canary was lost. Establishing one now
            // destroys nothing, because there is nothing there.
            //
            // UNLESS the key is ephemeral — and this branch is how the freeze used to be
            // defeated. On an upgrade from a pre-canary build, with the real keys
            // unreadable, this would seal a NEW canary under the session key, find that
            // it round-trips (it does, within one process), and declare decryption
            // healthy. Safe mode's first term then went false, and on a store too small
            // for the ratio gate the migration that re-seals every row ran under a key
            // that dies at exit. The mechanism designed to prevent total loss caused it.
            //
            // `sealStrict` now refuses under an ephemeral key, so the store below fails —
            // but the health verdict must be set explicitly, not left to fall through.
            guard !ensureKeyResolved() else {
                decryptionHealthy = false
                NSLog("Cliphoard crypto: canary absent AND the key is ephemeral — refusing "
                      + "to establish one, because it would certify a health this process "
                      + "cannot deliver. Entering safe mode.")
                DebugLog.write("crypto: canary absent + ephemeral key — safe mode")
                return false
            }
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
        // Clear a STICKY ephemeral mark before trying the fallback.
        //
        // If the enclave branch minted a key, could not persist it (so marked ephemeral),
        // and then key agreement failed, control arrives here — and the fallback may yield
        // a perfectly durable key while the flag stays true forever. The result is a
        // permanent refusal to write under a good key: an availability failure caused by a
        // safety flag that outlived the situation it described. Newly reachable because
        // the enclave branch only started setting the flag last commit.
        keyIsEphemeral = false

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
            keyIsEphemeral = true
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
            keyIsEphemeral = true
            return SymmetricKey(size: .bits256)

        case .absent:
            // Genuinely first run: nothing to destroy.
            let fresh = SymmetricKey(size: .bits256)
            // A minted key that could not be SAVED is ephemeral in fact, whatever the
            // branch it came from. The store helper can fail in both keychains — it says
            // so in its own log — and the old code treated the key as durable regardless,
            // so a first run that could read but not write sealed everything under a key
            // that died at exit, then minted another next launch.
            if !storeRandomKey(fresh, account: randomAccount) {
                keyIsEphemeral = true
                NSLog("Cliphoard crypto: minted a key but could not persist it — treating "
                      + "it as EPHEMERAL. Nothing fail-closed will be written with it.")
            }
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
                // Same rule as the random-key branch: a key that could not be SAVED is
                // ephemeral in fact. The store helper can fail in both keychains and
                // says so in its own log; treating the key as durable regardless is how
                // a first run that can read but not write seals everything under a key
                // that dies at exit, then mints another next launch.
                if !storeBlob(fresh.dataRepresentation, account: seAccount) {
                    keyIsEphemeral = true
                    NSLog("Cliphoard crypto: minted a Secure Enclave key but could not "
                          + "persist its blob — treating it as EPHEMERAL.")
                }
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

    // `readRandomKey` was deleted here. It had no callers, and it carried the exact
    // collapse-every-failure-to-nil pattern that cost 210 clips — one call site away from
    // reintroducing the bug, sitting in the file that exists to prevent it. Dead code
    // that encodes a retired mistake is a loaded gun, not clutter.

    @discardableResult
    private static func storeRandomKey(_ key: SymmetricKey, account: String) -> Bool {
        storeBlob(key.withUnsafeBytes { Data($0) }, account: account)
    }

    /// Classify a raw keychain status. Extracted from `readBlobStatus` and made
    /// `internal` for ONE reason: so a test can assert the real mapping instead of a copy
    /// of it.
    ///
    /// Before this existed, every test on this logic re-declared the switch locally and
    /// asserted about its own copy — which meant that changing the production `default:`
    /// branch to report "absent", restoring the exact bug that cost 210 clips, would have
    /// left the whole file passing. A test that mirrors the code cannot detect the code
    /// changing.
    static func classify(_ status: OSStatus, data: Data?) -> BlobRead {
        switch status {
        case errSecSuccess:
            guard let data else { return .unavailable(status) }
            return .found(data)
        case errSecItemNotFound:
            return .absent
        default:
            return .unavailable(status)
        }
    }

    /// Whether a classification may lead to CREATING and PERSISTING a new key.
    ///
    /// The single most consequential predicate in the product, and now callable. Only a
    /// genuine absence qualifies: an unreadable key is somebody's live key, and minting
    /// over it is unrecoverable.
    static func mayMintNewKey(after read: BlobRead) -> Bool {
        if case .absent = read { return true }
        return false
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
        // The data-protection keychain FIRST: no ACLs, so no prompt, so this path works
        // when the app is relaunched by a script, when the Mac is in dark wake, and when
        // the lid is shut. Every key written from now on lives here.
        var dpOut: CFTypeRef?
        let dpStatus = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true,
        ] as CFDictionary, &dpOut)
        if dpStatus == errSecSuccess, let data = dpOut as? Data { return .found(data) }

        // The modern read's status must NOT be discarded, and discarding it was a real
        // hole. Accepting only outright success meant the mint decision was made by the
        // legacy read alone, whatever the modern side had said. For a signed release —
        // whose keys live in the modern keychain by design — a later re-sign or identity
        // change makes that read fail for an item that EXISTS; the legacy side has
        // nothing; the result classifies as "genuinely absent" and a fresh key is minted
        // over a live one. The same failure that cost 210 clips, relocated.
        //
        // Anything other than success or a genuine not-found means "there may be a key
        // over there that I cannot see", and that must never reach the mint path.
        if dpStatus != errSecItemNotFound {
            keychainAccessDenied = true
            DebugLog.write("crypto: \(account) — data-protection read failed with OSStatus "
                           + "\(dpStatus); a key may exist there. Refusing to treat this "
                           + "as first run whatever the legacy keychain says.")
            return .unavailable(dpStatus)
        }

        // Fall back to the legacy file-based keychain, where every key written before
        // this change lives. If it opens, MIGRATE it forward so the prompt is needed at
        // most once more, ever.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &out)

        // NEEDS-A-PROMPT RECOVERY. These items carry an ACL, so any read that would
        // require asking the user fails when no prompt can be shown.
        //
        // Two distinct statuses arrive here and only ONE is worth retrying:
        //   errSecInteractionNotAllowed (-25308) — UI was disallowed for this process.
        //       Permitting it and retrying once can genuinely succeed.
        //   errSecInDarkWake (-25320) — the Mac is in dark wake, screen off, and NO UI is
        //       possible at all. Retrying cannot help; there is nobody to ask. This is
        //       what happens when the app is launched by a script or relaunched while the
        //       machine is unattended, and it is the condition that was FIRST MISREAD
        //       here as a permissions problem caused by the app's rename.
        //
        // Neither may EVER be treated as absence — that is what mints a key over a live
        // one. Dark wake especially: it is transient, the identical read succeeds once
        // somebody is at the machine, so destroying a key over it does permanent damage
        // in response to a condition that resolves itself.
        if status == errSecInteractionNotAllowed {
            DebugLog.write("crypto: \(account) needs confirmation — permitting interaction "
                           + "and retrying once")
            // Deprecated since 10.10 with the whole SecKeychain family, used knowingly:
            // these items live in the legacy file-based keychain, which is the only thing
            // that HAS ACLs and therefore the only thing that produces this status. The
            // modern data-protection keychain has no ACLs and also cannot see these
            // items, so it is not a migration path for an existing store.
            SecKeychainSetUserInteractionAllowed(true)
            out = nil
            status = SecItemCopyMatching(query as CFDictionary, &out)
            DebugLog.write("crypto: \(account) retry returned OSStatus \(status)")
        } else if status == errSecInDarkWake {
            DebugLog.write("crypto: \(account) unreadable — Mac is in DARK WAKE, no UI is "
                           + "possible, so the keychain cannot ask anyone. TRANSIENT: the "
                           + "identical read succeeds once the machine is awake. Refusing "
                           + "to mint a replacement.")
        }

        // Classification lives in `classify` so a test can assert the REAL mapping.
        let read = Crypto.classify(status, data: out as? Data)
        switch read {
        case .found(let data):
            // MIGRATE FORWARD, but only while it can actually succeed. We read the key
            // this time, so copying it into the modern keychain means no future launch
            // depends on being able to ask anyone.
            //
            // Skipped entirely once the modern keychain has refused for want of an
            // entitlement: that is a property of the build and will not change mid-run, so
            // continuing to attempt it would write to the production keychain once per
            // account per launch, forever, for nothing.
            if !dataProtectionUnavailable { storeBlob(data, account: account) }
            return read
        case .absent:
            // Absent from BOTH keychains. Only now is this genuinely first run.
            return read
        case .unavailable:
            if status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecInDarkWake {
                // The key is there and we were not permitted to reach it. Record it so
                // the interface can say something true and actionable instead of leaving
                // a user staring at a frozen, empty window.
                keychainAccessDenied = true
            }
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
    /// Write into the DATA-PROTECTION keychain.
    ///
    /// The legacy file-based keychain guards items with an ACL, and any read by a binary
    /// not on that ACL needs a confirmation prompt. When no prompt can be shown — an
    /// app relaunched by a script, a Mac in dark wake, a closed lid — the read fails.
    /// That is not a hypothetical: on this machine the app could list all its keys and
    /// read none of them, because the lid was shut and the keychain had nobody to ask.
    ///
    /// The data-protection keychain has NO ACLs. Access is decided by code identity, so a
    /// correctly-signed app reads its own items with no UI, ever. That removes the entire
    /// failure mode rather than working around it: unattended launches, headless
    /// relaunches and clamshell mode all just work.
    @discardableResult
    private static func storeBlob(_ data: Data, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // ThisDeviceOnly: the at-rest key must never leave this Mac. Non-migratable
            // items are excluded from keychain backups / Migration Assistant, so the raw
            // AES-256 key cannot travel alongside the encrypted DB on non-Secure-Enclave Macs.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecUseDataProtectionKeychain as String: true,
        ]
        // UPDATE-OR-ADD, never delete-then-add.
        //
        // The previous shape deleted first and added second, and that is exactly how a
        // key is lost: if the add fails after the delete succeeded — a denial, a killed
        // process, any change in keychain state between the two calls — there is now no
        // key at all, and everything sealed under it is orphaned. That is the mechanism
        // behind both losses this week, and it was reintroduced here by the migration
        // meant to prevent them.
        //
        // Updating an existing item, or adding when there is none, never passes through a
        // state where the key is absent.
        let attributes: [String: Any] = [kSecValueData as String: data]
        var lookup = query
        lookup.removeValue(forKey: kSecValueData as String)
        var status = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query as CFDictionary, nil)
        }
        if status == errSecSuccess { return true }

        // errSecMissingEntitlement (-34018): the data-protection keychain needs a
        // keychain-access-groups entitlement, which a self-signed local build with no
        // team identity cannot carry. A notarized release can; a developer build cannot.
        //
        // Falling back to the legacy keychain is ESSENTIAL, not a nicety: without it,
        // first run on any self-signed build would fail to store a key at all and the app
        // would be unable to encrypt anything. The prompt-free path is an improvement
        // where it is available, never a prerequisite.
        // Remember, for the whole process, that the modern keychain is unavailable. This
        // is what stops the migrate-forward retrying on every account on every launch —
        // which is how a per-launch write against the production keychain crept in.
        if status == errSecMissingEntitlement { dataProtectionUnavailable = true }
        DebugLog.write("crypto: data-protection keychain unavailable for \(account) "
                       + "(OSStatus \(status)) — storing in the legacy keychain instead")

        var legacy = query
        legacy.removeValue(forKey: kSecUseDataProtectionKeychain as String)
        var legacyLookup = legacy
        legacyLookup.removeValue(forKey: kSecValueData as String)
        var legacyStatus = SecItemUpdate(legacyLookup as CFDictionary, attributes as CFDictionary)
        if legacyStatus == errSecItemNotFound {
            legacyStatus = SecItemAdd(legacy as CFDictionary, nil)
        }
        if legacyStatus != errSecSuccess {
            DebugLog.write("crypto: storeBlob(\(account)) FAILED in both keychains, "
                           + "OSStatus \(legacyStatus) — this process cannot persist a key. "
                           + "Nothing was deleted; any existing key is still there.")
            return false
        }
        return true
    }

    /// Set once the modern keychain has refused for want of an entitlement — which is a
    /// property of the BUILD, not of the moment, so retrying per account per launch only
    /// generates writes against the production keychain for no benefit.
    private static var dataProtectionUnavailable = false
}
