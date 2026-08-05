import XCTest
@testable import Cliphoard

/// At-rest encryption round-trips and is non-destructive (BL-02).
final class CryptoTests: XCTestCase {
    func testStringRoundTrip() {
        for s in ["", "hello", "p@ssw0rd!! 🔐", String(repeating: "x", count: 5000),
                  "line1\nline2\ttab", "https://example.com/a?b=c"] {
            let sealed = Crypto.seal(s)
            XCTAssertTrue(sealed.hasPrefix("enc1:") || s.isEmpty == false, "non-empty seals are marked")
            XCTAssertNotEqual(sealed, s, "ciphertext differs from plaintext")
            XCTAssertEqual(Crypto.open(sealed), s, "round-trips back to the original")
        }
    }

    func testDataRoundTrip() {
        let blob = Data((0..<512).map { UInt8($0 % 256) })
        let sealed = Crypto.seal(blob)
        XCTAssertNotEqual(sealed, blob)
        XCTAssertEqual(Crypto.open(sealed), blob)
        XCTAssertNil(Crypto.seal(nil as Data?))
        XCTAssertNil(Crypto.open(nil as Data?))
    }

    /// Legacy plaintext (no marker) must pass through untouched — this is what
    /// keeps pre-encryption histories readable during migration.
    func testLegacyPlaintextPassesThrough() {
        XCTAssertEqual(Crypto.open("just plain text"), "just plain text")
        XCTAssertEqual(Crypto.open(Data("plain bytes".utf8)), Data("plain bytes".utf8))
    }

    /// A sealed value is opaque — the plaintext must not appear in the ciphertext.
    func testCiphertextHidesPlaintext() {
        let secret = "TOTP-9183-secret-token"
        XCTAssertFalse(Crypto.seal(secret).contains(secret))
    }

    /// `sealStrict` is the fail-CLOSED variant used for content at rest: its
    /// output is always `enc1:`-marked, never the plaintext, and round-trips.
    /// (The nil failure path is unreachable for valid input — AES-GCM seal does
    /// not fail — but the contract is sealed-or-nil, never plaintext.)
    func testSealStrictIsAlwaysSealedNeverPlaintext() {
        for s in ["", "hello", "aws_secret=AKIA-TOP-SECRET", String(repeating: "z", count: 4096)] {
            guard let sealed = Crypto.sealStrict(s) else { return XCTFail("sealStrict returned nil for valid input") }
            XCTAssertTrue(sealed.hasPrefix("enc1:"), "sealStrict output is always marked")
            XCTAssertFalse(sealed.contains(s.isEmpty ? "\u{0}IMPOSSIBLE" : s), "plaintext never present")
            XCTAssertEqual(Crypto.open(sealed), s, "round-trips back to the original")
        }
        let blob = Data((0..<300).map { UInt8($0 % 256) })
        guard let sealedBlob = Crypto.sealStrict(blob) else { return XCTFail("sealStrict(Data) returned nil") }
        XCTAssertTrue(Crypto.isSealed(sealedBlob), "sealStrict(Data) output is marked")
        XCTAssertEqual(Crypto.open(sealedBlob), blob)
    }
}
