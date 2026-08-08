import XCTest
import CryptoKit
@testable import Cliphoard

/// TP-23: an ephemeral key must never satisfy a fail-closed check.
///
/// This is the root cause of a whole family of data-loss bugs, and it is one missing
/// fact. When the keychain cannot be reached, the code correctly refuses to mint over a
/// live key and falls back to a session key that is never stored. Nothing recorded that.
///
/// Every "fail closed" guard in the codebase verified that ciphertext had been PRODUCED.
/// But sealing always succeeds — it is opening that fails. So a guard reading "the sealed
/// archive was written, therefore deleting the original is safe" was satisfied by a seal
/// guaranteed unreadable after the process exits. Three separate paths destroyed data
/// through that one gap:
///
///   • the legacy-history import sealed everything under the session key, verified the
///     ciphertext existed, then DELETED THE PLAINTEXT ORIGINAL;
///   • the canary established itself under the session key and declared decryption
///     healthy, defeating the freeze that exists to prevent exactly this;
///   • the archive-and-delete tool consulted nothing at all, and in a degraded process
///     every clip looks unreadable.
///
/// One flag, consumed in three places, closes all three — none of them had to learn the
/// rule individually. These tests pin BOTH directions: the refusal, and the fact that a
/// healthy key is still allowed to seal (a fix that refused everything would stop the
/// loss and break the product, while passing any one-sided test).
final class EphemeralKeyTests: XCTestCase {

    /// WHAT THIS DOES AND DOES NOT PROVE — stated because the previous version's comment
    /// was false, and a test whose comment lies is worse than no test.
    ///
    /// It claimed to exercise "the FIRST fail-closed seal in this process". It cannot. A
    /// review established two independent reasons: a dozen suites sort before this one and
    /// every one of them seals or inserts, forcing key resolution long beforehand; and
    /// within this class XCTest orders methods alphabetically, so this is FOURTH and the
    /// canary test has already run. Reverting `ensureKeyResolved` to a bare flag read
    /// leaves every assertion below true. It would pass.
    ///
    /// What it does prove is still worth having: the resolving accessor agrees with the
    /// flag, is idempotent, and the fail-closed seal's behaviour is consistent with both.
    /// Those are real invariants — they are simply weaker than "the ordering bug cannot
    /// return".
    ///
    /// The discriminating test does not exist yet and needs a fresh process with an
    /// injectable keychain outcome, asserting the flag BEFORE any other crypto call.
    /// Recorded as a known gap rather than papered over with a green tick.
    func testResolvingAccessorAgreesWithTheFlagAndIsIdempotent() {
        let resolved = Crypto.ensureKeyResolved()
        XCTAssertEqual(resolved, Crypto.keyIsEphemeral,
                       "the accessor disagrees with the flag it exists to establish")
        XCTAssertEqual(Crypto.ensureKeyResolved(), resolved,
                       "resolution is not idempotent — two guards would see different "
                       + "answers")

        // Consistency between the accessor and the guard that consumes it.
        let sealed = Crypto.sealStrict("consistency probe")
        if Crypto.keyIsEphemeral {
            XCTAssertNil(sealed, "ephemeral key must refuse a fail-closed seal")
        } else {
            XCTAssertNotNil(sealed, "a persisted key must still seal")
        }
    }

    /// The load-bearing property. Under an ephemeral key the fail-closed seal must return
    /// nil, so every caller that treats non-nil as "safe to discard the original" refuses.
    func testFailClosedSealRefusesUnderAnEphemeralKey() {
        Crypto.simulatingEphemeralKey {
        XCTAssertNil(Crypto.sealStrict("clipboard content"),
                     "a fail-closed seal SUCCEEDED under a key that dies with the process. "
                     + "Its callers delete originals on the strength of that result.")
        XCTAssertNil(Crypto.sealStrict(Data("payload bytes".utf8)),
                     "same for blob content — image payloads are written through this")
        }
        // The seam must restore the flag, or it leaks into every later test and quietly
        // turns the whole suite into "everything refuses".
        XCTAssertFalse(Crypto.keyIsEphemeral, "simulatingEphemeralKey did not restore")
    }

    /// The converse. A fix that refused every seal would stop the data loss and make the
    /// app unable to store anything, and would pass the test above perfectly.
    func testFailClosedSealStillWorksWithAPersistedKey() throws {
        try XCTSkipIf(Crypto.keyIsEphemeral,
                      "key is ephemeral in this process (keychain unreachable), so the "
                      + "normal path cannot be exercised here")

        let sealed = try XCTUnwrap(Crypto.sealStrict("clipboard content"),
                                   "a healthy key must still be able to seal, or nothing "
                                   + "can ever be stored")
        XCTAssertTrue(Crypto.isSealed(sealed))
        XCTAssertEqual(Crypto.open(sealed), "clipboard content")
        XCTAssertNotNil(Crypto.sealStrict(Data("payload bytes".utf8)))
    }

    /// The canary must not be able to certify health under a doomed key — that is how the
    /// freeze itself was defeated, on a store too small for the ratio gate to catch.
    func testCanaryCannotReportHealthUnderAnEphemeralKey() {
        Crypto.simulatingEphemeralKey {
        _ = Crypto.verifyCanary()
        XCTAssertFalse(Crypto.decryptionHealthy,
                       "decryption was reported HEALTHY while the key is ephemeral. That "
                       + "sets safe mode's first term false, and on a store below the "
                       + "ratio gate the re-seal migration then runs under a key that "
                       + "dies at exit — total permanent loss.")
        }
    }

    /// A store must never persist a clip while the key is ephemeral, whatever route the
    /// write takes.
    @MainActor
    func testStoreDoesNotPersistUnderAnEphemeralKey() {
        Crypto.simulatingEphemeralKey {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ephemeral-\(UUID().uuidString)")
        let store = ClipStore(directory: dir)
        store.add(ClipItem(kind: .text, text: "must not reach disk"))

        let reloaded = ClipStore(directory: dir)
        XCTAssertTrue(reloaded.items.isEmpty,
                      "a clip was persisted under an ephemeral key — it is unreadable the "
                      + "moment this process exits, so writing it manufactures a row "
                      + "nobody can ever open")
        }
    }
}
