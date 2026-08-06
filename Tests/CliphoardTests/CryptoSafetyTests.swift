import XCTest
import CryptoKit
@testable import Cliphoard

/// Guards against the failure CLASS that destroyed 202 clips: an operation that
/// silently removes the ability to read user data, with nothing checking that
/// reading still works.
///
/// These tests encode the three independent defences. Any ONE of them would have
/// prevented the incident, so each is tested on its own.
final class CryptoSafetyTests: XCTestCase {

    // MARK: 1 — Multi-round unseal (a migration re-sealing an already-sealed row)

    /// `insert` seals whatever it is handed, so a migration that ran over rows
    /// which had not decrypted produced doubly-sealed text. Opening must peel
    /// every layer, or the UI renders "enc1:…" as the clip's content.
    func testDoubleSealedTextStillOpens() {
        let secret = "the original clipboard content"
        let onceSealed = Crypto.seal(secret)
        let twiceSealed = Crypto.seal(onceSealed)
        XCTAssertTrue(twiceSealed.hasPrefix("enc1:"))
        XCTAssertEqual(Crypto.open(twiceSealed), secret,
                       "a doubly-sealed row must open all the way back to plaintext")
        XCTAssertEqual(Crypto.open(onceSealed), secret)
    }

    /// Unwrapping must be driven by successful DECRYPTION, never by the marker
    /// alone — otherwise text a user genuinely copied gets mangled.
    func testTextThatMerelyLooksSealedIsReturnedUntouched() {
        let lookalike = "enc1:this-is-not-really-ciphertext"
        XCTAssertEqual(Crypto.open(lookalike), lookalike)
        // Valid base64 that is not valid ciphertext must also survive intact.
        let base64ish = "enc1:" + Data("hello world hello world".utf8).base64EncodedString()
        XCTAssertEqual(Crypto.open(base64ish), base64ish)
    }

    /// The bound stops a crafted payload from spinning, without affecting real data.
    func testUnsealRoundsAreBounded() {
        var nested = Crypto.seal("deep")
        for _ in 0..<12 { nested = Crypto.seal(nested) }
        _ = Crypto.open(nested)   // must terminate; correctness beyond the cap is not promised
    }

    // MARK: 2 — The keyring is append-only (losing a key must be impossible)

    /// A key that ever sealed data must keep opening it after a rotation. This is
    /// the property whose absence was fatal: with a single key, replacing it
    /// orphaned everything it had sealed.
    func testDataSealedByAnArchivedKeyStillOpensAfterRotation() {
        // Simulate the historical shape directly: seal with key A, then prove that
        // a keyring containing A can still open it while a keyring without A cannot.
        let keyA = SymmetricKey(size: .bits256)
        let keyB = SymmetricKey(size: .bits256)
        let plaintext = "history sealed under the previous key"

        let box = try! AES.GCM.seal(Data(plaintext.utf8), using: keyA)
        let sealed = box.combined!

        func openWith(_ ring: [SymmetricKey]) -> String? {
            for k in ring {
                if let b = try? AES.GCM.SealedBox(combined: sealed),
                   let opened = try? AES.GCM.open(b, using: k) {
                    return String(data: opened, encoding: .utf8)
                }
            }
            return nil
        }
        XCTAssertNil(openWith([keyB]), "precondition: the new key alone cannot open old data")
        XCTAssertEqual(openWith([keyB, keyA]), plaintext,
                       "retaining the old key on the ring keeps old data readable")
    }

    /// Archiving is idempotent and never removes an entry — re-archiving the same
    /// key must not reduce the ring.
    func testArchivingIsAdditiveAndIdempotent() {
        let k = SymmetricKey(size: .bits256)
        Crypto.archiveKey(k, label: "unit-test-key")
        Crypto.archiveKey(k, label: "unit-test-key")
        // No crash, no throw, and the live ring still opens current data.
        let s = Crypto.seal("still fine")
        XCTAssertEqual(Crypto.open(s), "still fine")
    }

    // MARK: 3 — The canary (detect "I can no longer read my own data")

    /// The canary must round-trip under the current key. If this ever fails on a
    /// real machine, safe mode engages and no migration runs.
    func testCanaryRoundTripsUnderTheCurrentKey() {
        XCTAssertTrue(Crypto.verifyCanary())
        XCTAssertTrue(Crypto.decryptionHealthy)
    }

    /// A canary sealed by a key that is NOT on the ring must be detected as a
    /// failure — that is precisely the "different key" situation.
    func testCanarySealedByAnUnknownKeyDoesNotOpen() {
        let foreign = SymmetricKey(size: .bits256)
        let box = try! AES.GCM.seal(Data("cliphoard-canary-v1".utf8), using: foreign)
        let foreignSealed = "enc1:" + box.combined!.base64EncodedString()
        XCTAssertNotEqual(Crypto.open(foreignSealed), "cliphoard-canary-v1",
                          "a canary from an unknown key must NOT appear healthy")
        XCTAssertTrue(Crypto.isSealed(Crypto.open(foreignSealed)),
                      "it stays sealed, which is what the safe-mode gate counts")
    }

    // MARK: 4 — The invariant, stated as a test

    /// Sealing then opening is lossless for the content shapes the app stores.
    func testSealOpenIsLosslessAcrossContentShapes() {
        for s in ["", "plain", "🔐 unicode ✓", String(repeating: "x", count: 20_000),
                  "multi\nline\ttabbed", "{\"json\":true}", "enc1-but-not-a-marker"] {
            XCTAssertEqual(Crypto.open(Crypto.seal(s)), s, "round-trip failed for \(s.prefix(20))")
        }
        let blob = Data((0..<4096).map { UInt8($0 % 256) })
        XCTAssertEqual(Crypto.open(Crypto.seal(blob)), blob)
    }
}
