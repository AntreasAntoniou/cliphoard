#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE
import XCTest
import CryptoKit
@testable import Cliphoard

actor DeviceLicenceTestKey: DeviceLicenceKeyProvider {
    enum Mode { case normal, unavailable, wrongSigner, replay }
    let privateKey = P256.Signing.PrivateKey()
    private let otherKey = P256.Signing.PrivateKey()
    var mode: Mode = .normal
    var messages: [Data] = []
    var cachedSignature: Data?
    var publicKeyOverride: Data?

    func setMode(_ value: Mode) { mode = value }
    func setPublicKey(_ value: Data) { publicKeyOverride = value }
    func publicKeyX963() async throws -> Data {
        if mode == .unavailable { throw DeviceLicenceFailure.keyUnavailable }
        return publicKeyOverride ?? privateKey.publicKey.x963Representation
    }
    func signLicenceProof(_ message: Data) async throws -> Data {
        messages.append(message)
        if mode == .unavailable { throw DeviceLicenceFailure.keyUnavailable }
        if mode == .replay, let cachedSignature { return cachedSignature }
        let key = mode == .wrongSigner ? otherKey : privateKey
        let signature = try key.signature(for: message).rawRepresentation
        cachedSignature = signature
        return signature
    }
}

struct DeviceLicenceTestFixture {
    let device = DeviceLicenceTestKey()
    let issuer = P256.Signing.PrivateKey()
    var trust: [String: Data] { ["synthetic-1": issuer.publicKey.x963Representation] }

    func fields() async throws -> [String] {
        let deviceKey = try await device.publicKeyX963()
        return ["cliphoard.device-receipt", "1", "P256-SHA256", "synthetic-1",
                DeviceLicenceVerifier.encode(Data(repeating: 1, count: 16)),
                DeviceLicenceVerifier.encode(Data(SHA256.hash(data: deviceKey))),
                DeviceLicenceVerifier.encode(Data(repeating: 2, count: 16)), "1767323045", "pro", "perpetual"]
    }
    func mint(_ fields: [String], signer: P256.Signing.PrivateKey? = nil) throws -> String {
        let payload = Data(fields.joined(separator: "\n").utf8)
        let signature = try (signer ?? issuer).signature(for: payload).rawRepresentation
        return "CLIPD1.\(DeviceLicenceVerifier.encode(payload)).\(DeviceLicenceVerifier.encode(signature))"
    }
    func envelope() async throws -> String { try await mint(fields()) }
    func approved() async throws -> DeviceLicenceReceipt {
        try await DeviceLicenceVerifier.verify(envelope(), using: device, trustedIssuers: trust).get()
    }
}

final class DeviceLicenceTests: XCTestCase {
    func testReceiptRequiresFreshLocalPossessionAndHasNoExpiry() async throws {
        let fixture = DeviceLicenceTestFixture()
        let envelope = try await fixture.envelope()
        let first = await DeviceLicenceVerifier.verify(envelope, using: fixture.device, trustedIssuers: fixture.trust)
        let second = await DeviceLicenceVerifier.verify(envelope, using: fixture.device, trustedIssuers: fixture.trust)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try first.get().issuedAt, 1767323045)
        let messages = await fixture.device.messages
        XCTAssertEqual(messages.count, 2)
        XCTAssertNotEqual(messages[0], messages[1], "each verification needs a new local nonce")
        XCTAssertTrue(String(decoding: messages[0], as: UTF8.self).hasPrefix("cliphoard.device-local-proof\n1\n"))
        // There is intentionally no now/expiry/network parameter to the offline verifier.
    }

    func testCopiedReceiptAndSpoofedPublicKeyCannotProvePossession() async throws {
        let fixture = DeviceLicenceTestFixture()
        let envelope = try await fixture.envelope()
        let other = DeviceLicenceTestKey()
        let result = await DeviceLicenceVerifier.verify(envelope, using: other, trustedIssuers: fixture.trust)
        XCTAssertEqual(result, .failure(.wrongDevice))
        let claimedKey = try await fixture.device.publicKeyX963()
        await other.setPublicKey(claimedKey)
        let spoofed = await DeviceLicenceVerifier.verify(envelope, using: other, trustedIssuers: fixture.trust)
        XCTAssertEqual(spoofed, .failure(.invalidPossessionProof))
    }

    func testPossessionSignatureCannotBeReplayed() async throws {
        let fixture = DeviceLicenceTestFixture()
        let envelope = try await fixture.envelope()
        _ = try await DeviceLicenceVerifier.verify(envelope, using: fixture.device, trustedIssuers: fixture.trust).get()
        await fixture.device.setMode(.replay)
        let result = await DeviceLicenceVerifier.verify(envelope, using: fixture.device, trustedIssuers: fixture.trust)
        XCTAssertEqual(result, .failure(.invalidPossessionProof))
    }

    func testUnavailableProviderAndInvalidCurveKeyFailClosed() async throws {
        let fixture = DeviceLicenceTestFixture()
        let envelope = try await fixture.envelope()
        await fixture.device.setMode(.unavailable)
        let unavailable = await DeviceLicenceVerifier.verify(envelope, using: fixture.device, trustedIssuers: fixture.trust)
        XCTAssertEqual(unavailable, .failure(.keyUnavailable))
        await fixture.device.setMode(.normal)
        await fixture.device.setPublicKey(Data([4] + Array(repeating: UInt8(0), count: 64)))
        let invalid = await DeviceLicenceVerifier.verify(envelope, using: fixture.device, trustedIssuers: fixture.trust)
        XCTAssertEqual(invalid, .failure(.wrongDevice))
    }

    func testDistinctTrustAndInvalidIssuerSignatureFailBeforeDeviceAccess() async throws {
        let fixture = DeviceLicenceTestFixture()
        let envelope = try await fixture.envelope()
        let untrusted = await DeviceLicenceVerifier.verify(envelope, using: fixture.device, trustedIssuers: [:])
        XCTAssertEqual(untrusted, .failure(.untrustedIssuer))
        let wrongTrust = ["synthetic-1": P256.Signing.PrivateKey().publicKey.x963Representation]
        let invalid = await DeviceLicenceVerifier.verify(envelope, using: fixture.device, trustedIssuers: wrongTrust)
        XCTAssertEqual(invalid, .failure(.invalidSignature))
        let messages = await fixture.device.messages
        XCTAssertTrue(messages.isEmpty)
    }

    func testEvenAuthenticallySignedWrongVersionPurposeProductAlgorithmAndPolicyAreRejected() async throws {
        let fixture = DeviceLicenceTestFixture()
        let original = try await fixture.fields()
        for (index, value) in [(0, "cliphoard.device-approval"), (1, "2"), (1, "01"),
                               (2, "Ed25519"), (8, "free"), (9, "expires")] {
            var fields = original; fields[index] = value
            let result = await DeviceLicenceVerifier.verify(try fixture.mint(fields), using: fixture.device, trustedIssuers: fixture.trust)
            XCTAssertEqual(result, .failure(.unsupportedProtocol), "field \(index)")
        }
    }

    func testCanonicalBoundedPayloadRejectsMalformedSignedFields() async throws {
        let fixture = DeviceLicenceTestFixture()
        let original = try await fixture.fields()
        for (index, value) in [(3, "SYNTHETIC"), (3, String(repeating: "a", count: 33)),
                               (4, "short"), (5, "not-a-key-hash"), (6, "bad"),
                               (7, "01767323045"), (7, "1e9"), (7, "-1"), (7, "0"),
                               (7, "253402300800"), (7, "NaN")] {
            var fields = original; fields[index] = value
            let result = await DeviceLicenceVerifier.verify(try fixture.mint(fields), using: fixture.device, trustedIssuers: fixture.trust)
            XCTAssertEqual(result, .failure(.malformed), "field \(index)")
        }
        for fields in [original + ["extra"], Array(original.dropLast()), original + [""]] {
            let result = await DeviceLicenceVerifier.verify(try fixture.mint(fields), using: fixture.device, trustedIssuers: fixture.trust)
            XCTAssertEqual(result, .failure(.malformed))
        }
    }

    func testMalformedOversizedAndTamperedEnvelopesFail() async throws {
        let fixture = DeviceLicenceTestFixture()
        let envelope = try await fixture.envelope()
        let parts = envelope.split(separator: ".").map(String.init)
        let flippedSignature = (parts[2].first == "A" ? "B" : "A") + parts[2].dropFirst()
        var inputs = ["", "CLIPD1.", "CLIPD1..", "CLIPD2." + envelope.dropFirst(7),
                      " " + envelope, envelope + "\n", envelope + ".extra", envelope + "=",
                      "CLIPD1.💥.💥", "CLIPD1." + String(repeating: "A", count: 2000) + ".AA",
                      parts[0] + "." + parts[1] + "=." + parts[2],
                      parts[0] + "." + parts[1] + "." + flippedSignature]
        // A 64-byte signature has four unused low bits in its last base64url digit.
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let finalIndex = alphabet.firstIndex(of: parts[2].last!)!
        let aliased = String(parts[2].dropLast()) + String(alphabet[finalIndex | 1])
        inputs.append(parts[0] + "." + parts[1] + "." + aliased)
        for input in inputs {
            let result = await DeviceLicenceVerifier.verify(input, using: fixture.device, trustedIssuers: fixture.trust)
            if case .success = result { XCTFail("untrusted envelope accepted") }
        }
    }

    func testRelabellingNewEnvelopeCannotEnterActualLegacyVerifier() async throws {
        let fixture = DeviceLicenceTestFixture()
        let envelope = try await fixture.envelope()
        XCTAssertFalse(Licence.verify(envelope).isPro)
        XCTAssertFalse(Licence.verify("CLIP1-" + envelope.dropFirst("CLIPD1.".count)).isPro)
        let result = await DeviceLicenceVerifier.verify("CLIP1-" + envelope.dropFirst("CLIPD1.".count),
                                                         using: fixture.device, trustedIssuers: fixture.trust)
        XCTAssertEqual(result, .failure(.malformed))
    }

    func testVerifierHasNoNetworkStorageOrShippingEntitlementCapabilities() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["DeviceLicence.swift", "DeviceLicenceActivation.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent("Sources/Cliphoard/Support/" + name), encoding: .utf8)
            XCTAssertTrue(source.hasPrefix("#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE\n"))
            let code = source.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for banned in ["URLSession", "URLRequest", "NWConnection", "SecItem", "FileManager", "UserDefaults", "Process(", "Entitlement.pro"] {
                XCTAssertFalse(code.contains(banned), "prototype references \(banned)")
            }
        }
    }
}
#endif
