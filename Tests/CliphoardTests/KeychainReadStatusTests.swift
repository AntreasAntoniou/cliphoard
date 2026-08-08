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

        // Calls the PRODUCTION predicate, not a copy of it. A review found that the
        // earlier version re-declared this switch locally, which meant restoring the
        // original bug in the real code would have left this file passing.
        XCTAssertTrue(Crypto.mayMintNewKey(after: absent),
                      "genuine absence is first run and MUST still mint, or no new user "
                      + "can ever encrypt anything")
        XCTAssertFalse(Crypto.mayMintNewKey(after: found),
                       "a present key must never be minted over")
        XCTAssertFalse(Crypto.mayMintNewKey(after: unavailable),
                       "an UNREADABLE key must never be minted over — this is the case "
                       + "that cost 202 clips, and then 8 more")
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
        XCTAssertTrue(Crypto.mayMintNewKey(after: Crypto.classify(errSecItemNotFound, data: nil)),
                      "first run must still be able to create a key, or no new user can "
                      + "ever encrypt anything — a fix that refused everything would stop "
                      + "the data loss and break every new install")
    }

    /// The renamed-app case must be treated as RECOVERABLE, not as absence and not as
    /// corruption. `errSecInteractionNotAllowed` means the framework was never permitted
    /// to ask the user — nobody refused anything. Conflating it with absence is what
    /// mints a key over a live one; conflating it with corruption is what tells a user
    /// their history is broken when it is one dialog away.
    func testInteractionNotAllowedIsRecoverableNotAbsentNotCorrupt() {
        XCTAssertNotEqual(errSecInteractionNotAllowed, errSecItemNotFound,
                          "if these are ever treated alike, a key gets minted over a live one")

        // The PRODUCTION classifier. Every status that is not literally not-found must
        // classify as unavailable, and unavailable must never be mintable.
        let bytes = Data(repeating: 9, count: 32)
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecInDarkWake,
                       errSecMissingEntitlement, errSecNotAvailable, errSecReadOnly] {
            let read = Crypto.classify(status, data: nil)
            guard case .unavailable = read else {
                return XCTFail("OSStatus \(status) classified as \(read) — anything other "
                               + "than unavailable puts it on the mint path")
            }
            XCTAssertFalse(Crypto.mayMintNewKey(after: read),
                           "OSStatus \(status) became mintable — this is the exact defect")
        }
        guard case .absent = Crypto.classify(errSecItemNotFound, data: nil) else {
            return XCTFail("not-found must classify as absent, or first run breaks")
        }
        guard case .found = Crypto.classify(errSecSuccess, data: bytes) else {
            return XCTFail("a successful read with data must classify as found")
        }
        // Success WITHOUT data is not a find — it is a malformed result, and treating it
        // as absence would mint.
        XCTAssertFalse(Crypto.mayMintNewKey(after: Crypto.classify(errSecSuccess, data: nil)),
                       "a success with no data must not be mintable")
    }

    /// The user-facing distinction must exist at all. A frozen, empty window with no
    /// explanation is the worst outcome of this whole failure, and it is the default
    /// unless something records WHY.
    func testDeniedAccessIsRecordedForTheInterface() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let crypto = try String(contentsOf: root.appendingPathComponent(
            "Sources/Cliphoard/Clipboard/Crypto.swift"), encoding: .utf8)
        XCTAssertTrue(crypto.contains("keychainAccessDenied"),
                      "nothing records that access was denied, so the UI cannot tell a "
                      + "recoverable permission problem from real corruption")
        XCTAssertTrue(crypto.contains("SecKeychainSetUserInteractionAllowed"),
                      "the retry that permits the prompt is gone — a renamed app can then "
                      + "never regain access to its own keys without manual intervention")

        let ui = try String(contentsOf: root.appendingPathComponent(
            "Sources/Cliphoard/UI/ContentView.swift"), encoding: .utf8)
        XCTAssertTrue(ui.contains("Crypto.keychainAccessDenied"),
                      "the safe-mode banner no longer distinguishes the recoverable case")
    }
}
