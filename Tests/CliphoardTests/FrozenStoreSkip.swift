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
    func skipIfKeychainUnreachable(file: StaticString = #filePath,
                                   line: UInt = #line) throws {
        guard !Crypto.decryptionHealthy else { return }
        throw XCTSkip("this process cannot reach the keychain (dark wake / locked / lid "
                      + "closed), so the store is in SAFE MODE and correctly refuses to "
                      + "persist. Nothing about the code under test can be concluded — "
                      + "run with the machine awake.",
                      file: file, line: line)
    }
}
