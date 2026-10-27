#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE && !APP_STORE
import XCTest
import CryptoKit
import Foundation
@testable import Cliphoard

struct BootstrapFixture {
    let signer = P256.Signing.PrivateKey(), issuer = P256.Signing.PrivateKey()
    let entitlement = DeviceLicenceVerifier.encode(Data(repeating: 6, count: 16))
    let handle = DeviceLicenceVerifier.encode(Data(repeating: 7, count: 32))
    var fields: [String] {
        ["cliphoard.device-bootstrap", "1", "P256-SHA256", "bootstrap-test", "personal-test",
         "receipt-test", entitlement, handle, "1767323045", "pro"]
    }
    func profile(id: String = "personal-test", signerID: String = "bootstrap-test",
                 signerKey: Data? = nil, issuers: [String: Data]? = nil) throws -> DeviceLicenceBootstrapTrustProfile {
        try .init(profileID: id, bootstrapKeyID: signerID,
                  bootstrapPublicKey: signerKey ?? signer.publicKey.x963Representation,
                  receiptIssuers: issuers ?? ["receipt-test": issuer.publicKey.x963Representation])
    }
    func envelope(fields: [String]? = nil, payload: Data? = nil, key: P256.Signing.PrivateKey? = nil) throws -> String {
        let bytes = payload ?? Data((fields ?? self.fields).joined(separator: "\n").utf8)
        return "CLIPB1.\(DeviceLicenceVerifier.encode(bytes)).\(DeviceLicenceVerifier.encode(try (key ?? signer).signature(for: bytes).rawRepresentation))"
    }
    func verified() throws -> VerifiedDeviceLicenceBootstrap {
        try DeviceLicenceBootstrapVerifier.verify(envelope(), profile: profile())
    }
}
actor BootstrapNeverDevice: DeviceLicenceKeyProvider {
    private(set) var calls = 0
    func publicKeyX963() throws -> Data { calls += 1; throw DeviceIdentityFailure.missing }
    func signLicenceProof(_ message: Data) throws -> Data { calls += 1; throw DeviceIdentityFailure.missing }
}

final class DeviceLicenceBootstrapTests: XCTestCase {
    func testAuthenticDescriptorReturnsOnlyPinnedPurchaserValues() throws {
        let f = BootstrapFixture(), result = try f.verified()
        XCTAssertEqual(result.profileID, "personal-test"); XCTAssertEqual(result.bootstrapKeyID, "bootstrap-test")
        XCTAssertEqual(result.receiptIssuerKeyID, "receipt-test"); XCTAssertEqual(result.receiptIssuerPublicKey, f.issuer.publicKey.x963Representation)
        XCTAssertEqual(result.entitlementID, f.entitlement); XCTAssertEqual(result.activationHandle, f.handle)
        XCTAssertEqual(result.issuedAt, 1767323045)
        XCTAssertEqual(String(describing: result), "VerifiedDeviceLicenceBootstrap")
        XCTAssertEqual(String(reflecting: result), "VerifiedDeviceLicenceBootstrap")
    }
    func testProfileAndKeySelectionAreClosedLocalPins() throws {
        let f = BootstrapFixture(), envelope = try f.envelope()
        XCTAssertThrowsError(try DeviceLicenceBootstrapVerifier.verify(envelope, profile: f.profile(id: "other-profile"))) {
            XCTAssertEqual($0 as? DeviceLicenceBootstrapFailure, .untrustedProfile)
        }
        XCTAssertThrowsError(try DeviceLicenceBootstrapVerifier.verify(envelope, profile: f.profile(signerID: "other-key"))) {
            XCTAssertEqual($0 as? DeviceLicenceBootstrapFailure, .untrustedSigner)
        }
        XCTAssertThrowsError(try DeviceLicenceBootstrapVerifier.verify(envelope, profile: f.profile(issuers: ["other-issuer": f.issuer.publicKey.x963Representation]))) {
            XCTAssertEqual($0 as? DeviceLicenceBootstrapFailure, .untrustedReceiptIssuer)
        }
        XCTAssertThrowsError(try DeviceLicenceBootstrapVerifier.verify(envelope, profile: f.profile(signerKey: f.issuer.publicKey.x963Representation))) {
            XCTAssertEqual($0 as? DeviceLicenceBootstrapFailure, .invalidSignature)
        }
    }
    func testPinConfigurationRejectsMalformedIdentifiersAndKeys() throws {
        let f = BootstrapFixture()
        for id in ["", "UPPER", "-first", "a.b", String(repeating: "a", count: 33), "é"] {
            XCTAssertThrowsError(try f.profile(id: id)); XCTAssertThrowsError(try f.profile(signerID: id))
            XCTAssertThrowsError(try f.profile(issuers: [id: f.issuer.publicKey.x963Representation]))
        }
        XCTAssertThrowsError(try f.profile(issuers: [:]))
        for key in [Data(), Data(repeating: 0, count: 65), f.signer.publicKey.compressedRepresentation] {
            XCTAssertThrowsError(try f.profile(signerKey: key))
            XCTAssertThrowsError(try f.profile(issuers: ["receipt-test": key]))
        }
    }
    func testCapturedPinsAndVerifiedValuesCannotBeReboundByCallerMutation() throws {
        let f = BootstrapFixture()
        let mutable = NSMutableData(data: f.signer.publicKey.x963Representation)
        var signData = Data(referencing: mutable)
        var issuerData = f.issuer.publicKey.x963Representation
        var dictionary = ["receipt-test": issuerData]
        let profile = try f.profile(signerKey: signData, issuers: dictionary)
        mutable.resetBytes(in: NSRange(location: 0, length: mutable.length))
        signData.resetBytes(in: 0..<signData.count); issuerData.resetBytes(in: 0..<issuerData.count)
        dictionary["receipt-test"] = Data()
        let result = try DeviceLicenceBootstrapVerifier.verify(f.envelope(), profile: profile)
        var derivedKey = result.receiptIssuerPublicKey
        derivedKey.resetBytes(in: 0..<derivedKey.count)
        XCTAssertEqual(result.receiptIssuerPublicKey, f.issuer.publicKey.x963Representation)
        XCTAssertEqual(result.entitlementID, f.entitlement)
    }
    func testSignedWrongPurposeVersionAlgorithmOrTierIsRejected() throws {
        let f = BootstrapFixture()
        for (index, wrong) in [(0, "cliphoard.device-receipt"), (0, "cliphoard.device-approval"), (1, "2"), (2, "Ed25519"), (9, "free")] {
            var fields = f.fields; fields[index] = wrong
            XCTAssertThrowsError(try DeviceLicenceBootstrapVerifier.verify(f.envelope(fields: fields), profile: f.profile())) {
                XCTAssertEqual($0 as? DeviceLicenceBootstrapFailure, .unsupportedProtocol)
            }
        }
    }
    func testBootstrapAndReceiptDomainsAreMutuallyExclusiveBeforeDeviceUse() async throws {
        let f = BootstrapFixture(), descriptor = try f.envelope(), device = BootstrapNeverDevice()
        let result = await DeviceLicenceVerifier.verify(descriptor, using: device, trustedIssuers: ["receipt-test": f.issuer.publicKey.x963Representation])
        XCTAssertEqual(result, .failure(.malformed))
        let count = await device.calls; XCTAssertEqual(count, 0)
        XCTAssertThrowsError(try DeviceLicenceBootstrapVerifier.verify(descriptor.replacingOccurrences(of: "CLIPB1.", with: "CLIPD1."), profile: f.profile()))
        XCTAssertThrowsError(try DeviceLicenceBootstrapVerifier.verify("CLIP1.invalid.invalid", profile: f.profile()))
    }
    func testEveryAuthenticatedFieldAndSignatureAreCovered() throws {
        let f = BootstrapFixture(), envelope = try f.envelope()
        let original = envelope.components(separatedBy: ".")
        for index in [6, 7, 8] {
            var changed = f.fields
            changed[index] = index == 8 ? "1767323046" : DeviceLicenceVerifier.encode(Data(repeating: 10, count: index == 6 ? 16 : 32))
            let tampered = "CLIPB1.\(DeviceLicenceVerifier.encode(Data(changed.joined(separator: "\n").utf8))).\(original[2])"
            XCTAssertThrowsError(try DeviceLicenceBootstrapVerifier.verify(tampered, profile: f.profile())) {
                XCTAssertEqual($0 as? DeviceLicenceBootstrapFailure, .invalidSignature)
            }
        }
        XCTAssertThrowsError(try DeviceLicenceBootstrapVerifier.verify(f.envelope(key: f.issuer), profile: f.profile()))
        XCTAssertThrowsError(try DeviceLicenceBootstrapVerifier.verify("CLIPB1.\(original[1]).\(DeviceLicenceVerifier.encode(Data(repeating: 0, count: 64)))", profile: f.profile()))
    }
    func testCanonicalIdentifiersEpochAndFieldCountAreRequiredEvenWhenSigned() throws {
        let f = BootstrapFixture()
        let invalid: [(Int, String)] = [(3, "Bootstrap"), (4, "profile space"), (5, "../issuer"),
            (6, f.entitlement + "="), (6, DeviceLicenceVerifier.encode(Data(repeating: 1, count: 15))),
            (7, DeviceLicenceVerifier.encode(Data(repeating: 2, count: 33))),
            (8, "0"), (8, "01"), (8, "+1"), (8, "1.0"), (8, " 1"), (8, "253402300800"),
            (8, "18446744073709551616")]
        for (index, wrong) in invalid {
            var fields = f.fields; fields[index] = wrong
            XCTAssertThrowsError(try DeviceLicenceBootstrapVerifier.verify(f.envelope(fields: fields), profile: f.profile()))
        }
        for fields in [Array(f.fields.dropLast()), f.fields + [""], f.fields + ["extra"]] {
            XCTAssertThrowsError(try DeviceLicenceBootstrapVerifier.verify(f.envelope(fields: fields), profile: f.profile()))
        }
        for epoch in ["1", "253402300799"] {
            var fields = f.fields; fields[8] = epoch
            XCTAssertEqual(try DeviceLicenceBootstrapVerifier.verify(f.envelope(fields: fields), profile: f.profile()).issuedAt, UInt64(epoch))
        }
    }
    func testCanonicalBase64AndStrictASCIIRejectAlternateEncodings() throws {
        let f = BootstrapFixture(), envelope = try f.envelope(), pieces = envelope.components(separatedBy: ".")
        for value in [envelope + "\n", " " + envelope, envelope + ".", "CLIPB1..\(pieces[2])",
                      "CLIPB1.\(pieces[1])=.\(pieces[2])", "CLIPB1.\(pieces[1]).\(pieces[2])=",
                      "CLIPB1.\(pieces[1]).\(DeviceLicenceVerifier.encode(Data(repeating: 1, count: 63)))"] {
            XCTAssertThrowsError(try DeviceLicenceBootstrapVerifier.verify(value, profile: f.profile()))
        }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var signatureAlias = Array(pieces[2])
        let last = alphabet.firstIndex(of: signatureAlias.last!)!
        signatureAlias[signatureAlias.count - 1] = alphabet[last + 1]
        XCTAssertThrowsError(try DeviceLicenceBootstrapVerifier.verify("CLIPB1.\(pieces[1]).\(String(signatureAlias))", profile: f.profile()))
        for payload in [Data(f.fields.joined(separator: "\r\n").utf8), Data(f.fields.joined(separator: "\n").utf8) + Data([0]), Data("é".utf8)] {
            XCTAssertThrowsError(try DeviceLicenceBootstrapVerifier.verify(f.envelope(payload: payload), profile: f.profile()))
        }
    }
    func testEnvelopeAndPayloadBoundsFailBeforeUnboundedParsing() throws {
        let f = BootstrapFixture()
        XCTAssertThrowsError(try DeviceLicenceBootstrapVerifier.verify(String(repeating: "A", count: 100_000), profile: f.profile()))
        XCTAssertThrowsError(try DeviceLicenceBootstrapVerifier.verify(f.envelope(payload: Data(repeating: 65, count: 513)), profile: f.profile()))
    }
    func testCancelledVerificationProducesNoVerifiedValue() async throws {
        let f = BootstrapFixture(), profile = try f.profile(), envelope = try f.envelope()
        let gate = BootstrapTestGate()
        let task = Task { await gate.pause(); return try DeviceLicenceBootstrapVerifier.verify(envelope, profile: profile) }
        await gate.wait(); task.cancel(); await gate.release()
        do { _ = try await task.value; XCTFail("cancelled verification succeeded") }
        catch { XCTAssertEqual(error as? DeviceLicenceBootstrapFailure, .cancelled) }
    }
}

actor BootstrapTestGate {
    private var entered = false, released = false
    private var entry: CheckedContinuation<Void, Never>?, exit: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true; entry?.resume(); entry = nil
        if !released { await withCheckedContinuation { exit = $0 } }
    }
    func wait() async { if !entered { await withCheckedContinuation { entry = $0 } } }
    func release() { released = true; exit?.resume(); exit = nil }
}
#endif
