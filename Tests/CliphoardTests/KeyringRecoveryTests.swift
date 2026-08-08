import XCTest
import CryptoKit
import Security
@testable import Cliphoard

/// TP-20: the append-only keyring must actually carry keys.
///
/// The keyring exists so a re-minted key can never orphan history. It was added on
/// 2026-08-06, after 202 clips were lost. On 2026-08-08 it was needed — and carried
/// exactly one key, because of two bugs that were each individually silent:
///
///   1. It listed archived keys with `kSecMatchLimitAll` + `kSecReturnData` in one query.
///      On macOS that does not reliably return data for multiple items; the call failed
///      and every archived key vanished. An empty ring is indistinguishable from having
///      nothing to recover.
///   2. It archived under a FIXED label per role. `SecItemAdd` is insert-only, so the
///      second distinct key to claim a label was silently not archived at all.
///
/// Together: a mechanism that looked present, ran on every launch, and retained nothing.
/// Fixing (1) took the live store from 80 unreadable clips to 1.
final class KeyringRecoveryTests: XCTestCase {

    /// Two distinct keys under the same role must BOTH be retained. Under the old fixed
    /// label the second was dropped, which is how a clip becomes unrecoverable.
    func testDistinctKeysUnderOneRoleGetDistinctSlots() {
        let a = SymmetricKey(size: .bits256)
        let b = SymmetricKey(size: .bits256)

        func slot(_ k: SymmetricKey, _ label: String) -> String {
            let raw = k.withUnsafeBytes { Data($0) }
            let fp = SHA256.hash(data: raw).prefix(8).map { String(format: "%02x", $0) }.joined()
            return "db-archived-key-" + label + "-" + fp
        }
        XCTAssertNotEqual(slot(a, "se-v2"), slot(b, "se-v2"),
                          "two different keys collided on one archive slot — the second "
                          + "would be silently dropped and everything it sealed orphaned")
        XCTAssertEqual(slot(a, "se-v2"), slot(a, "se-v2"),
                       "archiving the same key twice must stay idempotent")
    }

    /// The listing query must be able to return data for several items. Run against a
    /// throwaway service so nothing belonging to the app is touched.
    ///
    /// This is the test that would have caught the original bug: it asserts the READ
    /// strategy works for more than one item, which is the only case that matters for a
    /// ring and the only case a single-item test would miss.
    func testMultipleArchivedKeysAreAllReadable() throws {
        let service = "io.antreas.cliphoard.tests.ring.\(UUID().uuidString)"
        addTeardownBlock {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: service] as CFDictionary)
        }
        let expected: [String: Data] = [
            "db-archived-key-a": Data(repeating: 0xA1, count: 32),
            "db-archived-key-b": Data(repeating: 0xB2, count: 32),
            "db-archived-key-c": Data(repeating: 0xC3, count: 32),
        ]
        for (account, data) in expected {
            let status = SecItemAdd([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ] as CFDictionary, nil)
            try XCTSkipUnless(status == errSecSuccess, "cannot write to the keychain here")
        }

        // Step 1: list accounts (attributes only).
        var out: CFTypeRef?
        let listStatus = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ] as CFDictionary, &out)
        XCTAssertEqual(listStatus, errSecSuccess, "listing multiple items must succeed")
        let accounts = ((out as? [[String: Any]]) ?? [])
            .compactMap { $0[kSecAttrAccount as String] as? String }
        XCTAssertEqual(Set(accounts), Set(expected.keys), "all three items must be listed")

        // Step 2: fetch each one's bytes individually — the part the old single query
        // could not do.
        var recovered: [String: Data] = [:]
        for account in accounts {
            var item: CFTypeRef?
            let s = SecItemCopyMatching([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ] as CFDictionary, &item)
            XCTAssertEqual(s, errSecSuccess, "per-account read of \(account) must succeed")
            if let data = item as? Data { recovered[account] = data }
        }
        XCTAssertEqual(recovered, expected,
                       "every archived key must come back with its bytes — a ring that "
                       + "lists keys but cannot read them recovers nothing")
    }

    /// The ring must never be empty in a healthy process: it always contains at least the
    /// key currently in use, or `open` has nothing to try.
    func testRingCanAlwaysOpenWhatItJustSealed() {
        let sealed = Crypto.seal("round trip")
        XCTAssertTrue(Crypto.isSealed(sealed), "precondition: seal must actually seal")
        XCTAssertEqual(Crypto.open(sealed), "round trip",
                       "the key in use is not reachable on the ring, so nothing this "
                       + "process writes could ever be read back")
    }
}
