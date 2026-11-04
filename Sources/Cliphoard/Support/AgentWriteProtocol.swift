import Foundation
import CryptoKit

/// Shared by the native app and the separately installed MCP writer. Only encrypted
/// requests and authenticated, content-free receipts cross the chosen folder.
/// Possession of the folder is not a sender identity: any same-user writer can
/// request a save. The native per-note approval is the authorization boundary.
enum AgentWriteProtocol {
    static let maximumTextBytes = 32_768
    static let maximumWireBytes = 65_536
    static let sessionDuration: Double = 900
    static let requestDuration: Double = 120

    enum Failure: Error { case invalid, expired, authentication }
    enum Status: String, Codable { case saved, rejected, expired, unavailable }

    struct Session: Codable, Equatable {
        var version: Int
        var sessionID: UUID
        var expiresAt: Double
        var publicKey: Data
        init(sessionID: UUID, expiresAt: Double, publicKey: Data, version: Int = 1) {
            self.version = version; self.sessionID = sessionID
            self.expiresAt = expiresAt; self.publicKey = publicKey
        }
    }
    struct Request: Codable, Equatable {
        var version: Int
        var sessionID: UUID
        var requestID: UUID
        var createdAt: Double
        var text: String
        init(sessionID: UUID, requestID: UUID, createdAt: Double, text: String, version: Int = 1) {
            self.version = version; self.sessionID = sessionID; self.requestID = requestID
            self.createdAt = createdAt; self.text = text
        }
    }
    struct Prepared {
        let data: Data
        let responseKey: SymmetricKey
        let requestDigest: String
        fileprivate let sessionID: UUID
        fileprivate let requestID: UUID
    }
    struct Opened {
        let request: Request
        let responseKey: SymmetricKey
        let requestDigest: String
    }
    struct Receipt: Codable, Equatable {
        let version: Int
        let sessionID: UUID
        let requestID: UUID
        let requestDigest: String
        let status: Status
        let clipID: UUID?
    }
    private struct Envelope: Codable {
        let version: Int
        let sessionID: UUID
        let requestID: UUID
        let requestDigest: String
        let ephemeralPublicKey: Data
        let sealed: Data
    }
    private struct ResponseEnvelope: Codable {
        let version: Int
        let sessionID: UUID
        let requestID: UUID
        let requestDigest: String
        let sealed: Data
    }

    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    /// Own writers produce canonical JSON. Requiring the same bytes rejects unknown
    /// fields, duplicate keys, noncanonical identifiers and ambiguous representations.
    private static func decoded<T: Codable>(_ type: T.Type, from data: Data,
                                             maximum: Int = maximumWireBytes) throws -> T {
        guard !data.isEmpty, data.count <= maximum else { throw Failure.invalid }
        let value = try JSONDecoder().decode(type, from: data)
        guard try encoded(value) == data else { throw Failure.invalid }
        return value
    }
    static func validateSession(_ session: Session, now: Double = Date().timeIntervalSince1970) throws {
        guard session.version == 1, now.isFinite, session.expiresAt.isFinite,
              session.publicKey.count == 32 else { throw Failure.invalid }
        guard now < session.expiresAt, session.expiresAt - now <= sessionDuration + 5 else {
            throw Failure.expired
        }
        _ = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: session.publicKey)
    }
    static func encodeSession(_ session: Session, now: Double = Date().timeIntervalSince1970) throws -> Data {
        try validateSession(session, now: now)
        return try encoded(session)
    }
    static func decodeSession(_ data: Data, now: Double = Date().timeIntervalSince1970) throws -> Session {
        let session = try decoded(Session.self, from: data, maximum: 1_024)
        try validateSession(session, now: now)
        return session
    }
    static func validateRequest(_ request: Request, session: Session,
                                now: Double = Date().timeIntervalSince1970) throws {
        try validateSession(session, now: now)
        guard request.version == 1, request.sessionID == session.sessionID,
              request.createdAt.isFinite, !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.text.utf8.count <= maximumTextBytes,
              !request.text.unicodeScalars.contains(where: { $0.value == 0 }) else { throw Failure.invalid }
        guard request.createdAt <= now + 5, now - request.createdAt < requestDuration,
              request.createdAt < session.expiresAt else { throw Failure.expired }
    }
    private static func context(_ direction: String, session: UUID, request: UUID, digest: String) -> Data {
        Data("Cliphoard.AgentWrite.v1|\(direction)|\(session.uuidString)|\(request.uuidString)|\(digest)".utf8)
    }
    private static func key(_ shared: SharedSecret, direction: String, session: UUID, request: UUID) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(session.uuidString.utf8),
            sharedInfo: Data("Cliphoard.AgentWrite.v1|\(direction)|\(request.uuidString)".utf8), outputByteCount: 32)
    }
    private static func validDigest(_ digest: String) -> Bool {
        digest.count == 64 && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func prepare(_ request: Request, session: Session,
                        now: Double = Date().timeIntervalSince1970) throws -> Prepared {
        try validateRequest(request, session: session, now: now)
        let plaintext = try encoded(request)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with:
            Curve25519.KeyAgreement.PublicKey(rawRepresentation: session.publicKey))
        let requestKey = key(shared, direction: "request", session: request.sessionID, request: request.requestID)
        let aad = context("request", session: request.sessionID, request: request.requestID, digest: "")
        guard let sealed = try AES.GCM.seal(plaintext, using: requestKey, authenticating: aad).combined else {
            throw Failure.authentication
        }
        // Public binding hashes randomized ciphertext, never guessable note text.
        let digest = SHA256.hash(data: sealed).map { String(format: "%02x", $0) }.joined()
        let envelope = Envelope(version: 1, sessionID: request.sessionID, requestID: request.requestID,
            requestDigest: digest, ephemeralPublicKey: ephemeral.publicKey.rawRepresentation, sealed: sealed)
        let data = try encoded(envelope)
        guard data.count <= maximumWireBytes else { throw Failure.invalid }
        return Prepared(data: data,
            responseKey: key(shared, direction: "response", session: request.sessionID, request: request.requestID),
            requestDigest: digest, sessionID: request.sessionID, requestID: request.requestID)
    }
    static func open(_ data: Data, session: Session, privateKey: Curve25519.KeyAgreement.PrivateKey,
                     now: Double = Date().timeIntervalSince1970) throws -> Opened {
        try validateSession(session, now: now)
        guard privateKey.publicKey.rawRepresentation == session.publicKey else { throw Failure.authentication }
        let envelope = try decoded(Envelope.self, from: data)
        guard envelope.version == 1, envelope.sessionID == session.sessionID,
              envelope.ephemeralPublicKey.count == 32, validDigest(envelope.requestDigest) else { throw Failure.invalid }
        let digest = SHA256.hash(data: envelope.sealed).map { String(format: "%02x", $0) }.joined()
        guard digest == envelope.requestDigest else { throw Failure.authentication }
        let shared = try privateKey.sharedSecretFromKeyAgreement(with:
            Curve25519.KeyAgreement.PublicKey(rawRepresentation: envelope.ephemeralPublicKey))
        let requestKey = key(shared, direction: "request", session: envelope.sessionID, request: envelope.requestID)
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealed), using: requestKey,
            authenticating: context("request", session: envelope.sessionID, request: envelope.requestID,
                                   digest: ""))
        let request = try decoded(Request.self, from: plaintext)
        guard request.requestID == envelope.requestID, request.sessionID == envelope.sessionID else { throw Failure.invalid }
        try validateRequest(request, session: session, now: now)
        return Opened(request: request,
            responseKey: key(shared, direction: "response", session: envelope.sessionID, request: envelope.requestID),
            requestDigest: digest)
    }
    static func sealReceipt(status: Status, opened: Opened) throws -> Data {
        let request = opened.request
        let receipt = Receipt(version: 1, sessionID: request.sessionID, requestID: request.requestID,
            requestDigest: opened.requestDigest, status: status, clipID: status == .saved ? request.requestID : nil)
        let aad = context("response", session: request.sessionID, request: request.requestID, digest: opened.requestDigest)
        guard let sealed = try AES.GCM.seal(encoded(receipt), using: opened.responseKey, authenticating: aad).combined else {
            throw Failure.authentication
        }
        return try encoded(ResponseEnvelope(version: 1, sessionID: request.sessionID, requestID: request.requestID,
            requestDigest: opened.requestDigest, sealed: sealed))
    }
    static func openReceipt(_ data: Data, prepared: Prepared, expectedSessionID: UUID,
                            expectedRequestID: UUID) throws -> Receipt {
        guard expectedSessionID == prepared.sessionID, expectedRequestID == prepared.requestID else { throw Failure.invalid }
        let envelope = try decoded(ResponseEnvelope.self, from: data, maximum: 2_048)
        guard envelope.version == 1, envelope.sessionID == expectedSessionID, envelope.requestID == expectedRequestID,
              envelope.requestDigest == prepared.requestDigest else { throw Failure.authentication }
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealed), using: prepared.responseKey,
            authenticating: context("response", session: expectedSessionID, request: expectedRequestID,
                                   digest: prepared.requestDigest))
        let receipt = try decoded(Receipt.self, from: plaintext, maximum: 1_024)
        guard receipt.version == 1, receipt.sessionID == expectedSessionID, receipt.requestID == expectedRequestID,
              receipt.requestDigest == prepared.requestDigest,
              receipt.clipID == (receipt.status == .saved ? expectedRequestID : nil) else { throw Failure.authentication }
        return receipt
    }
}
