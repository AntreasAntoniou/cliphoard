#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE
import CryptoKit
import Foundation

/// Disabled experiment. No shipping caller, embedded trust key, storage or service adapter.
/// A future provider must schedule storage access asynchronously, away from app startup.
/// The protocol does NOT imply that its implementation is nonexportable or hardware bound.
protocol DeviceLicenceKeyProvider: Sendable {
    func publicKeyX963() async throws -> Data
    func signLicenceProof(_ message: Data) async throws -> Data
}

struct DeviceLicenceReceipt: Equatable, Sendable {
    let issuerKeyID: String
    let entitlementID: String
    let deviceKeyHash: String
    let receiptID: String
    let issuedAt: UInt64

    fileprivate init(issuerKeyID: String, entitlementID: String, deviceKeyHash: String,
                     receiptID: String, issuedAt: UInt64) {
        self.issuerKeyID = issuerKeyID
        self.entitlementID = entitlementID
        self.deviceKeyHash = deviceKeyHash
        self.receiptID = receiptID
        self.issuedAt = issuedAt
    }
}

enum DeviceLicenceFailure: Error, Equatable, Sendable {
    case malformed, unsupportedProtocol, untrustedIssuer, invalidSignature
    case wrongDevice, keyUnavailable, invalidPossessionProof
}

/// The only success API requires a fresh, receipt-bound proof from the local key provider.
/// It never calls a service or checks a clock: an approved receipt has no expiry or lease.
/// Trust is explicitly injected and must be separate from the legacy CLIP1 Ed25519 trust.
/// This type does not convert a result into the shipping app's Entitlement.
enum DeviceLicenceVerifier {
    static let prefix = "CLIPD1."
    static let receiptPurpose = "cliphoard.device-receipt"
    static let localProofPurpose = "cliphoard.device-local-proof"
    static let algorithm = "P256-SHA256"
    static let maximumEnvelopeBytes = 1024
    static let maximumPayloadBytes = 512
    static let maximumEpoch: UInt64 = 253_402_300_799

    static func verify(_ envelope: String, using device: any DeviceLicenceKeyProvider,
                       trustedIssuers: [String: Data]) async -> Result<DeviceLicenceReceipt, DeviceLicenceFailure> {
        let inspected: (receipt: DeviceLicenceReceipt, payload: Data)
        do { inspected = try inspect(envelope, trustedIssuers: trustedIssuers) }
        catch let failure as DeviceLicenceFailure { return .failure(failure) }
        catch { return .failure(.malformed) }

        let rawKey: Data
        do { rawKey = try await device.publicKeyX963() }
        catch { return .failure(.keyUnavailable) }
        guard let publicKey = canonicalPublicKey(rawKey) else { return .failure(.wrongDevice) }
        let keyHash = encode(Data(SHA256.hash(data: rawKey)))
        guard keyHash == inspected.receipt.deviceKeyHash else { return .failure(.wrongDevice) }

        // A caller cannot substitute the receipt's public key and skip possession. The
        // nonce is created here, never accepted from a caller or persisted for reuse.
        let nonce = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let message = Data([localProofPurpose, "1", encode(Data(SHA256.hash(data: inspected.payload))),
                            encode(nonce)].joined(separator: "\n").utf8)
        let rawSignature: Data
        do { rawSignature = try await device.signLicenceProof(message) }
        catch { return .failure(.keyUnavailable) }
        guard rawSignature.count == 64,
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: rawSignature),
              publicKey.isValidSignature(signature, for: message) else {
            return .failure(.invalidPossessionProof)
        }
        return .success(inspected.receipt)
    }

    private static func inspect(_ envelope: String, trustedIssuers: [String: Data]) throws
        -> (receipt: DeviceLicenceReceipt, payload: Data) {
        // Inspect a bounded prefix before allocating splits/decoding attacker input.
        guard envelope.utf8.prefix(maximumEnvelopeBytes + 1).count <= maximumEnvelopeBytes,
              envelope.hasPrefix(prefix) else { throw DeviceLicenceFailure.malformed }
        let pieces = envelope.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              let payload = decode(String(pieces[0]), maximumBytes: maximumPayloadBytes),
              let rawSignature = decode(String(pieces[1]), exactBytes: 64),
              payload.allSatisfy({ $0 == 10 || (32...126).contains($0) }),
              let text = String(data: payload, encoding: .ascii) else { throw DeviceLicenceFailure.malformed }
        let fields = text.components(separatedBy: "\n")
        guard fields.count == 10 else { throw DeviceLicenceFailure.malformed }
        // No algorithm negotiation, future versions, extra fields or alternate purposes.
        guard fields[0] == receiptPurpose, fields[1] == "1", fields[2] == algorithm,
              fields[8] == "pro", fields[9] == "perpetual" else {
            throw DeviceLicenceFailure.unsupportedProtocol
        }
        guard validKeyID(fields[3]), decode(fields[4], exactBytes: 16) != nil,
              decode(fields[5], exactBytes: 32) != nil, decode(fields[6], exactBytes: 16) != nil,
              let issued = UInt64(fields[7]), issued > 0, issued <= maximumEpoch,
              String(issued) == fields[7] else { throw DeviceLicenceFailure.malformed }
        guard let issuerData = trustedIssuers[fields[3]],
              let issuer = canonicalPublicKey(issuerData) else { throw DeviceLicenceFailure.untrustedIssuer }
        guard let signature = try? P256.Signing.ECDSASignature(rawRepresentation: rawSignature),
              issuer.isValidSignature(signature, for: payload) else { throw DeviceLicenceFailure.invalidSignature }
        return (DeviceLicenceReceipt(issuerKeyID: fields[3], entitlementID: fields[4],
                                     deviceKeyHash: fields[5], receiptID: fields[6], issuedAt: issued), payload)
    }

    static func canonicalPublicKey(_ raw: Data) -> P256.Signing.PublicKey? {
        guard raw.count == 65, raw.first == 4,
              let key = try? P256.Signing.PublicKey(x963Representation: raw),
              key.x963Representation == raw else { return nil }
        return key
    }

    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func validKeyID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        func alphanumeric(_ byte: UInt8) -> Bool { (97...122).contains(byte) || (48...57).contains(byte) }
        return (1...32).contains(bytes.count) && bytes.first.map(alphanumeric) == true
            && bytes.allSatisfy { alphanumeric($0) || $0 == 45 || $0 == 95 }
    }

    private static func decode(_ value: String, exactBytes: Int? = nil, maximumBytes: Int = 512) -> Data? {
        guard !value.isEmpty, value.utf8.count <= ((exactBytes ?? maximumBytes) * 8 + 5) / 6,
              value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), data.count <= maximumBytes,
              exactBytes.map({ data.count == $0 }) ?? true, encode(data) == value else { return nil }
        return data
    }
}
#endif
