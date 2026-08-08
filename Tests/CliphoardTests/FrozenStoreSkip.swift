import XCTest
@testable import Cliphoard

/// Shared skip for tests that need a store which can actually PERSIST.
///
/// Safe mode is entered when this process cannot read what a previous run wrote — a Mac
/// in dark wake, a locked keychain, a closed laptop lid, an unattended CI runner. The
/// store then deliberately refuses to write, so any test asserting persistence is
/// asserting something the app is correctly declining to do.
///
/// Those tests were FAILING rather than skipping, and that matters more than it sounds: a
/// suite red for an environmental reason carries no information about the code, yet looks
/// identical to a suite red for a real defect. It can gate nothing. One test already
/// skipped on exactly this condition; the pattern simply had not been applied to the rest.
///
/// This is not hiding a failure. The condition is named in the message, and on any machine
/// where the keychain is reachable every one of these runs for real.
extension XCTestCase {
    /// Gates on `keychainAccessDenied` — the signal that means specifically "this process
    /// could not REACH the keychain" — and deliberately NOT on `decryptionHealthy`.
    ///
    /// That was the original gate and it was a serious mistake. `decryptionHealthy` is
    /// false at three sites, and one of them is "the canary was READ successfully and did
    /// not decrypt" — which is the exact signature of the failure that destroyed 210
    /// clips. Gating on it meant a genuine regression in key handling would make fifteen
    /// tests SKIP and the suite report zero failures: green precisely when the catastrophe
    /// had returned. The suite was made structurally incapable of detecting the one thing
    /// it exists to detect.
    ///
    /// With this gate, an unreachable keychain still skips (environmental, no information
    /// available) while a readable-but-undecryptable canary FAILS LOUDLY (a real defect).
    /// The codebase already drew this distinction for the user — the safe-mode banner
    /// picks between two very different messages on exactly this flag — and simply had not
    /// drawn it for the tests.
    func skipIfKeychainUnreachable(file: StaticString = #filePath,
                                   line: UInt = #line) throws {
        Crypto.verifyCanary()   // establish the signals before reading them
        guard Crypto.keychainAccessDenied else { return }
        throw XCTSkip("this process cannot reach the keychain (dark wake / locked / lid "
                      + "closed), so the store is in SAFE MODE and correctly refuses to "
                      + "persist. Nothing about the code under test can be concluded — "
                      + "run with the machine awake.",
                      file: file, line: line)
    }
}
