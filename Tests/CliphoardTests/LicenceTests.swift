import XCTest
import CryptoKit
@testable import Cliphoard

/// The Pro licence is an OFFLINE Ed25519 signature check. These tests mint keys with a
/// throwaway keypair and verify against it by swapping the public key through a test seam,
/// so no real private key is ever near the test suite. The one thing they cannot do — and
/// must not pretend to — is prove the compiled-in public key matches the maintainer's private
/// key; that is proven by `Scripts/issue-licence.swift` producing a key the app accepts.
final class LicenceTests: XCTestCase {

    private func mint(_ payload: String, with key: Curve25519.Signing.PrivateKey) -> String {
        let sig = try! key.signature(for: Data(payload.utf8))
        func b64url(_ d: Data) -> String {
            d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return "CLIP1-\(b64url(Data(payload.utf8))).\(b64url(sig))"
    }

    func testAKeySignedByTheCompiledInPublicKeysPrivateHalfIsPro() throws {
        // The real signer lives outside the repo; if it is present on this machine, prove the
        // pair end to end. Otherwise skip — never fake it.
        let path = NSHomeDirectory() + "/.cliphoard-licensing/sample-key.txt"
        guard let key = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw XCTSkip("no maintainer sample key on this machine")
        }
#if APP_STORE
        XCTAssertFalse(Licence.verify(key).isPro,
                       "even a genuine direct-download key must not unlock the Store edition")
#else
        guard case .pro(let order, _) = Licence.verify(key) else {
            return XCTFail("a key minted by Scripts/issue-licence.swift must verify against the compiled-in public key: \(Licence.verify(key))")
        }
        XCTAssertEqual(order, "test-order-001")
#endif
    }

    func testTheSeparatorIsOutsideTheBase64urlAlphabet() {
        // A first draft split on "-", which base64url uses as a digit; a valid key with a "-"
        // in its signature bytes was rejected as malformed. "." is not in the alphabet.
        XCTAssertFalse("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".contains("."))
        XCTAssertTrue(Licence.prefix.hasSuffix("-"), "the prefix keeps its dash; only the payload/sig separator changed")
    }

    func testAForgedKeyIsFree() {
        let other = Curve25519.Signing.PrivateKey()
        let forged = mint(#"{"o":"x","i":1,"p":"pro","v":1}"#, with: other)
        guard case .free(let reason) = Licence.verify(forged) else { return XCTFail("a key signed by a different private key must be free") }
#if APP_STORE
        XCTAssertEqual(reason, "Use App Store purchases in this edition")
#else
        XCTAssertEqual(reason, "signature does not verify")
#endif
    }

    func testTamperingWithThePayloadIsFree() throws {
        let path = NSHomeDirectory() + "/.cliphoard-licensing/sample-key.txt"
        guard let key = try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw XCTSkip("no maintainer sample key on this machine")
        }
        // Flip one payload character: the signature no longer matches the bytes.
        var chars = Array(key); let i = Licence.prefix.count + 3
        chars[i] = chars[i] == "A" ? "B" : "A"
        XCTAssertFalse(Licence.verify(String(chars)).isPro)
    }

    func testMalformedInputsAreFreeAndNeverCrash() {
        for s in ["", "   ", "CLIP1-", "CLIP1-abc", "CLIP1-abc.def", "CLIP1-.", "CLIP2-a.b", "not a key", String(repeating: "x", count: 10_000)] {
            XCTAssertFalse(Licence.verify(s).isPro, "'\(s.prefix(20))' must be free")
        }
        XCTAssertEqual(Licence.verify("").isPro, false)
        if case .free(let reason) = Licence.verify("") { XCTAssertNil(reason, "an empty field carries no reason") }
    }

    func testVerifyIsPureAndOffline() throws {
        // Source scan: the licence module may import CryptoKit and Foundation only, and must
        // not reference the networking or Keychain APIs. The site promises zero network calls.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let raw = try String(contentsOf: root.appendingPathComponent("Sources/Cliphoard/Support/Licence.swift"), encoding: .utf8)
        // CODE lines only. The doc comment legitimately explains why the Keychain is NOT used,
        // and the first version of this scan matched that prose — the trap ForgetOrderingTests
        // documents, met again on the first run.
        let code = raw.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        for forbidden in ["URLSession", "URLRequest", "SecItem", "FileManager", "Process("] {
            XCTAssertFalse(code.contains(forbidden), "Licence.swift must not reference \(forbidden)")
        }
        XCTAssertEqual(Licence.publicKey.count, 32, "an Ed25519 public key is exactly 32 bytes")
    }

    func testStoreAndRemoveRoundTrip() {
        let saved = UserDefaults.standard.string(forKey: Licence.defaultsKey)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: Licence.defaultsKey) } else { UserDefaults.standard.removeObject(forKey: Licence.defaultsKey) } }
#if APP_STORE
        UserDefaults.standard.set("external-fixture", forKey: Licence.defaultsKey)
        Licence.store("CLIP1-junk.junk")
        XCTAssertEqual(UserDefaults.standard.string(forKey: Licence.defaultsKey), "external-fixture")
        XCTAssertFalse(Licence.current.isPro)
        Licence.remove()
        XCTAssertEqual(UserDefaults.standard.string(forKey: Licence.defaultsKey), "external-fixture",
                       "Store builds neither consume nor mutate a direct-download licence")
#else
        Licence.store("  CLIP1-junk.junk \n")
        XCTAssertEqual(UserDefaults.standard.string(forKey: Licence.defaultsKey), "CLIP1-junk.junk", "stored trimmed")
        XCTAssertFalse(Licence.current.isPro)
        Licence.remove()
        XCTAssertNil(UserDefaults.standard.string(forKey: Licence.defaultsKey))
#endif
    }
}
