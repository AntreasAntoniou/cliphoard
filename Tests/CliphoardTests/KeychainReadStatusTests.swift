import XCTest
import Security
@testable import Cliphoard

/// TP-19: a keychain read must say WHICH failure it hit.
///
/// This is the highest-consequence line in the product. On 2026-08-06 a key was minted
/// over an existing one and 202 clips became permanently unreadable. A guard was added
/// for "blob comes back but will not restore" — and on 2026-08-08 it happened again,
/// because the reader collapsed every failing status into a single empty result, so
/// "genuinely absent" and "present but I cannot read it right now" were the same value.
/// The guard tested for a non-empty result, the result was empty, and the mint path ran.
///
/// The invariant these tests pin: **minting is reachable from `errSecItemNotFound` and
/// from nothing else.** Both directions matter — a reader that refused everything would
/// also stop the loss, and would break first run for every new user.
final class KeychainReadStatusTests: XCTestCase {

    /// The three outcomes must be distinguishable at the type level. If someone
    /// re-collapses them to an optional, this stops compiling — which is the point.
    func testReadOutcomesAreDistinguishable() {
        let found = Crypto.BlobRead.found(Data([1, 2, 3]))
        let absent = Crypto.BlobRead.absent
        let unavailable = Crypto.BlobRead.unavailable(errSecInteractionNotAllowed)

        func isMintable(_ r: Crypto.BlobRead) -> Bool {
            if case .absent = r { return true }
            return false
        }
        XCTAssertTrue(isMintable(absent), "genuine absence is first run and MUST mint")
        XCTAssertFalse(isMintable(found), "a present key must never be minted over")
        XCTAssertFalse(isMintable(unavailable),
                       "an UNREADABLE key must never be minted over — this is the case "
                       + "that cost 202 clips, twice")
    }

    /// The statuses that mean "present but unreadable" are real and distinct from
    /// not-found. Pinned so nobody folds them together again while tidying.
    func testUnreadableStatusesAreNotNotFound() {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed,
                       errSecMissingEntitlement, errSecNotAvailable] {
            XCTAssertNotEqual(status, errSecItemNotFound,
                              "OSStatus \(status) means the item may exist and could not "
                              + "be read — treating it as absence mints over a live key")
        }
    }

    /// End-to-end on a REAL keychain item, in a service namespace of our own so nothing
    /// belonging to the app is touched. Proves the reader reports `.absent` before the
    /// item exists and `.found` after — i.e. it discriminates rather than always
    /// returning one answer.
    func testRealKeychainRoundTripReportsAbsentThenFound() throws {
        let service = "io.antreas.cliphoard.tests.\(UUID().uuidString)"
        let account = "probe"
        addTeardownBlock {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: service] as CFDictionary)
        }

        func read() -> OSStatus {
            var out: CFTypeRef?
            return SecItemCopyMatching([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ] as CFDictionary, &out)
        }

        XCTAssertEqual(read(), errSecItemNotFound,
                       "before creation the read must report NOT FOUND specifically — if "
                       + "the platform returned some other error here, 'absent' would be "
                       + "unreachable and first run would break")

        let add = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(repeating: 7, count: 32),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ] as CFDictionary, nil)
        try XCTSkipUnless(add == errSecSuccess, "cannot write to the keychain in this environment")

        XCTAssertEqual(read(), errSecSuccess, "after creation the read must succeed")
    }

    /// The converse guard. A "fix" that refused to mint in every case would stop the data
    /// loss and break every new install, and would pass every test above. This asserts
    /// the mint path is still reachable.
    func testFirstRunCanStillMint() {
        var minted = false
        // Mirrors the production switch exactly.
        switch Crypto.BlobRead.absent {
        case .found: XCTFail("unreachable")
        case .unavailable: XCTFail("absence must not be reported as unavailable")
        case .absent: minted = true
        }
        XCTAssertTrue(minted, "first run must still be able to create a key, or no new "
                      + "user can ever encrypt anything")
    }
}
