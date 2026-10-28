#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE && !APP_STORE
import CryptoKit
import Foundation

enum DeviceLicenceBootstrapFailure: Error, Equatable, Sendable {
    case invalidTrustProfile, malformed, unsupportedProtocol, untrustedProfile
    case untrustedSigner, untrustedReceiptIssuer, invalidSignature, cancelled
}

/// Local trust configuration only. No value is discovered from a descriptor or
/// receipt. A profile pins one bootstrap signer and a closed set of receipt issuers.
struct DeviceLicenceBootstrapTrustProfile: Sendable {
    let profileID: String
    let bootstrapKeyID: String
    fileprivate let bootstrapPublicKey: Data
    fileprivate let receiptIssuers: [String: Data]

    init(profileID: String, bootstrapKeyID: String, bootstrapPublicKey: Data,
         receiptIssuers: [String: Data]) throws {
        guard BootstrapWire.validID(profileID), BootstrapWire.validID(bootstrapKeyID),
              DeviceLicenceVerifier.canonicalPublicKey(bootstrapPublicKey) != nil,
              !receiptIssuers.isEmpty,
              receiptIssuers.allSatisfy({ BootstrapWire.validID($0.key)
                  && DeviceLicenceVerifier.canonicalPublicKey($0.value) != nil }) else {
            throw DeviceLicenceBootstrapFailure.invalidTrustProfile
        }
        self.profileID = profileID; self.bootstrapKeyID = bootstrapKeyID
        // Detach even a caller-supplied NSMutableData-backed value. Neither later
        // dictionary mutation nor a mutable bridge can change already captured pins.
        self.bootstrapPublicKey = Data(Array(bootstrapPublicKey))
        self.receiptIssuers = receiptIssuers.mapValues { Data(Array($0)) }
    }
}

/// This is authenticated onboarding data, never an approval or a Pro entitlement.
/// Its only constructor is in this file and is used after full pin verification.
struct VerifiedDeviceLicenceBootstrap: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let admissionEnvelope: String
    let profileID: String
    let bootstrapKeyID: String
    let receiptIssuerKeyID: String
    let receiptIssuerPublicKey: Data
    let entitlementID: String
    let activationHandle: String
    let issuedAt: UInt64
    var description: String { "VerifiedDeviceLicenceBootstrap" }
    var debugDescription: String { description }
    /// Internal transport capability. Descriptions and UI never expose this
    /// exact signed credential, and transport never reconstructs it from fields.
    func setupAdmissionEnvelope() -> String { admissionEnvelope }

    fileprivate init(profileID: String, bootstrapKeyID: String, receiptIssuerKeyID: String,
                     receiptIssuerPublicKey: Data, entitlementID: String,
                     activationHandle: String, issuedAt: UInt64, admissionEnvelope: String) {
        self.profileID = profileID; self.bootstrapKeyID = bootstrapKeyID
        self.receiptIssuerKeyID = receiptIssuerKeyID
        self.receiptIssuerPublicKey = Data(Array(receiptIssuerPublicKey))
        self.entitlementID = entitlementID; self.activationHandle = activationHandle; self.issuedAt = issuedAt
        self.admissionEnvelope = admissionEnvelope
    }
}

/// Pure bounded verification. No network, identity, receipt repository, clock,
/// account selection or application session is accessed or constructed here.
enum DeviceLicenceBootstrapVerifier {
    static let prefix = "CLIPB1."
    static let purpose = "cliphoard.device-bootstrap"
    static let maximumEnvelopeBytes = 1024
    static let maximumPayloadBytes = 512

    static func verify(_ envelope: String, profile: DeviceLicenceBootstrapTrustProfile) throws
        -> VerifiedDeviceLicenceBootstrap {
        if Task.isCancelled { throw DeviceLicenceBootstrapFailure.cancelled }
        guard envelope.utf8.prefix(maximumEnvelopeBytes + 1).count <= maximumEnvelopeBytes,
              envelope.hasPrefix(prefix) else { throw DeviceLicenceBootstrapFailure.malformed }
        let parts = envelope.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let payload = BootstrapWire.decode(String(parts[0]), maximum: maximumPayloadBytes),
              let signatureBytes = BootstrapWire.decode(String(parts[1]), exact: 64),
              payload.allSatisfy({ $0 == 10 || (32...126).contains($0) }),
              let text = String(data: payload, encoding: .ascii) else { throw DeviceLicenceBootstrapFailure.malformed }
        let fields = text.components(separatedBy: "\n")
        guard fields.count == 10 else { throw DeviceLicenceBootstrapFailure.malformed }
        guard fields[0] == purpose, fields[1] == "1", fields[2] == "P256-SHA256", fields[9] == "pro" else {
            throw DeviceLicenceBootstrapFailure.unsupportedProtocol
        }
        guard BootstrapWire.validID(fields[3]), BootstrapWire.validID(fields[4]), BootstrapWire.validID(fields[5]),
              BootstrapWire.decode(fields[6], exact: 16) != nil,
              BootstrapWire.decode(fields[7], exact: 32) != nil,
              let issuedAt = UInt64(fields[8]), issuedAt > 0,
              issuedAt <= DeviceLicenceVerifier.maximumEpoch, String(issuedAt) == fields[8] else {
            throw DeviceLicenceBootstrapFailure.malformed
        }
        guard fields[4] == profile.profileID else { throw DeviceLicenceBootstrapFailure.untrustedProfile }
        guard fields[3] == profile.bootstrapKeyID else { throw DeviceLicenceBootstrapFailure.untrustedSigner }
        guard let receiptIssuer = profile.receiptIssuers[fields[5]] else {
            throw DeviceLicenceBootstrapFailure.untrustedReceiptIssuer
        }
        guard let signer = DeviceLicenceVerifier.canonicalPublicKey(profile.bootstrapPublicKey),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureBytes),
              signer.isValidSignature(signature, for: payload) else { throw DeviceLicenceBootstrapFailure.invalidSignature }
        if Task.isCancelled { throw DeviceLicenceBootstrapFailure.cancelled }
        return .init(profileID: profile.profileID, bootstrapKeyID: profile.bootstrapKeyID,
                     receiptIssuerKeyID: fields[5], receiptIssuerPublicKey: receiptIssuer,
                     entitlementID: fields[6], activationHandle: fields[7], issuedAt: issuedAt, admissionEnvelope: envelope)
    }
}

private enum BootstrapWire {
    static func validID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        func alphanumeric(_ byte: UInt8) -> Bool { (97...122).contains(byte) || (48...57).contains(byte) }
        return (1...32).contains(bytes.count) && bytes.first.map(alphanumeric) == true
            && bytes.allSatisfy { alphanumeric($0) || $0 == 45 || $0 == 95 }
    }
    static func decode(_ text: String, exact: Int? = nil, maximum: Int = 512) -> Data? {
        let limit = exact ?? maximum
        guard !text.isEmpty, text.utf8.count <= (limit * 8 + 5) / 6,
              text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
        guard let bytes = Data(base64Encoded: base64), bytes.count <= limit,
              exact.map({ bytes.count == $0 }) ?? true,
              DeviceLicenceVerifier.encode(bytes) == text else { return nil }
        return bytes
    }
}
#endif
