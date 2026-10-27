#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE
import Foundation
import CryptoKit

enum DeviceLicenceApprovalClientFailure: Error, Equatable, Sendable {
    case invalidConfiguration, invalidRequest, invalidResponse, activationRejected, unavailable
    case transportUncertain, cancelled, keyUnavailable, invalidProof
}
enum DeviceLicenceApprovalDisposition: String, Equatable, Sendable {
    case issued
    case alreadyIssued = "already_issued"
}
struct DeviceLicenceApprovalResult: Equatable, Sendable {
    let disposition: DeviceLicenceApprovalDisposition
    /// Structurally checked wire data, NOT an authenticated or durably accepted licence.
    let envelope: String
}
struct DeviceLicenceApprovalHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}
protocol DeviceLicenceApprovalTransport: Sendable {
    /// Implementations must cap accumulated response bytes before buffering the full body.
    /// A throw/cancellation after dispatch does not establish that the server did nothing.
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> DeviceLicenceApprovalHTTPResponse
}
protocol DeviceLicenceApprovalServing: Sendable {
    func begin(_ request: DeviceLicenceBeginRequest) async throws -> DeviceLicenceApprovalChallenge
    func prepareApproval(challenge: DeviceLicenceApprovalChallenge, token: String, approvalRequestID: Data,
                         using device: any DeviceLicenceKeyProvider) async throws -> DeviceLicenceApprovalRequest
    func approve(_ request: DeviceLicenceApprovalRequest) async throws -> DeviceLicenceApprovalResult
}

struct DeviceLicenceBeginRequest: Equatable, Sendable {
    let entitlementHandle: String
    let devicePublicKeyX963: Data
    let requestID: Data
    let body: Data
    init(entitlementHandle: String, devicePublicKeyX963: Data, requestID: Data) throws {
        _ = try ApprovalWire.decode(entitlementHandle, count: 32)
        guard DeviceLicenceVerifier.canonicalPublicKey(devicePublicKeyX963) != nil, requestID.count == 16 else {
            throw DeviceLicenceApprovalClientFailure.invalidRequest
        }
        self.entitlementHandle = entitlementHandle; self.devicePublicKeyX963 = devicePublicKeyX963; self.requestID = requestID
        body = Data("{\"devicePublicKey\":\"\(DeviceLicenceVerifier.encode(devicePublicKeyX963))\",\"entitlementHandle\":\"\(entitlementHandle)\",\"requestID\":\"\(DeviceLicenceVerifier.encode(requestID))\"}".utf8)
    }
}
struct DeviceLicenceApprovalChallenge: Equatable, Sendable {
    let purpose = "cliphoard.device-approval"
    let version = 1
    let algorithm = "P256-SHA256"
    let entitlementID: String
    let devicePublicKeyX963: Data
    let deviceKeyHash: String
    let challengeID: String
    let nonce: String
    let expiresAt: UInt64
    init(entitlementID: String, devicePublicKeyX963: Data, challengeID: Data, nonce: Data, expiresAt: UInt64) throws {
        _ = try ApprovalWire.decode(entitlementID, count: 16)
        guard DeviceLicenceVerifier.canonicalPublicKey(devicePublicKeyX963) != nil,
              challengeID.count == 16, nonce.count == 32, expiresAt > 0,
              expiresAt <= DeviceLicenceVerifier.maximumEpoch else { throw DeviceLicenceApprovalClientFailure.invalidRequest }
        self.entitlementID = entitlementID; self.devicePublicKeyX963 = devicePublicKeyX963
        deviceKeyHash = DeviceLicenceVerifier.encode(Data(SHA256.hash(data: devicePublicKeyX963)))
        self.challengeID = DeviceLicenceVerifier.encode(challengeID); self.nonce = DeviceLicenceVerifier.encode(nonce)
        self.expiresAt = expiresAt
    }
}
struct DeviceLicenceApprovalRequest: Equatable, Sendable {
    let challenge: DeviceLicenceApprovalChallenge
    let approvalRequestID: Data
    let signature: Data
    /// Contains the approval token. Keep private; never log or place in a URL.
    let body: Data
    fileprivate let origin: URL
    fileprivate init(challenge: DeviceLicenceApprovalChallenge, approvalRequestID: Data,
                     signature: Data, token: String, origin: URL) {
        self.challenge = challenge; self.approvalRequestID = approvalRequestID; self.signature = signature; self.origin = origin
        body = Data("{\"approvalRequestID\":\"\(DeviceLicenceVerifier.encode(approvalRequestID))\",\"approvalToken\":\"\(token)\",\"challengeID\":\"\(challenge.challengeID)\",\"deviceSignature\":\"\(DeviceLicenceVerifier.encode(signature))\"}".utf8)
    }
}

/// Disabled client only. No default endpoint, account lookup, key creation, receipt
/// storage, issuer discovery, automatic retries, logging or shipping entitlement changes.
struct DeviceLicenceApprovalClient: DeviceLicenceApprovalServing {
    static let maximumResponseBytes = 2048
    private let origin: URL
    private let expectedEntitlementID: String
    private let transport: any DeviceLicenceApprovalTransport
    init(origin: URL, expectedEntitlementID: String, transport: any DeviceLicenceApprovalTransport) throws {
        do {
            self.origin = try ApprovalWire.origin(origin)
            _ = try ApprovalWire.decode(expectedEntitlementID, count: 16)
        } catch { throw DeviceLicenceApprovalClientFailure.invalidConfiguration }
        self.expectedEntitlementID = expectedEntitlementID; self.transport = transport
    }

    func begin(_ request: DeviceLicenceBeginRequest) async throws -> DeviceLicenceApprovalChallenge {
        let object = try await exchange(path: "begin", body: request.body)
        do {
            try ApprovalWire.exact(object, ["ok", "challenge"])
            guard try ApprovalWire.boolean(object["ok"]) else { throw DeviceLicenceApprovalClientFailure.invalidResponse }
            let raw = try ApprovalWire.object(object["challenge"])
            try ApprovalWire.exact(raw, ["purpose", "version", "algorithm", "entitlementID", "devicePublicKey", "deviceKeyHash", "challengeID", "nonce", "expiresAt"])
            guard try ApprovalWire.string(raw["purpose"]) == "cliphoard.device-approval",
                  try ApprovalWire.integer(raw["version"]) == 1,
                  try ApprovalWire.string(raw["algorithm"]) == DeviceLicenceVerifier.algorithm else { throw DeviceLicenceApprovalClientFailure.invalidResponse }
            let value = try DeviceLicenceApprovalChallenge(entitlementID: ApprovalWire.string(raw["entitlementID"]),
                devicePublicKeyX963: ApprovalWire.decode(ApprovalWire.string(raw["devicePublicKey"]), count: 65),
                challengeID: ApprovalWire.decode(ApprovalWire.string(raw["challengeID"]), count: 16),
                nonce: ApprovalWire.decode(ApprovalWire.string(raw["nonce"]), count: 32), expiresAt: ApprovalWire.integer(raw["expiresAt"]))
            guard value.entitlementID == expectedEntitlementID, value.devicePublicKeyX963 == request.devicePublicKeyX963,
                  try ApprovalWire.string(raw["deviceKeyHash"]) == value.deviceKeyHash else { throw DeviceLicenceApprovalClientFailure.invalidResponse }
            return value
        } catch { throw DeviceLicenceApprovalClientFailure.invalidResponse }
    }

    func prepareApproval(challenge: DeviceLicenceApprovalChallenge, token: String, approvalRequestID: Data,
                         using device: any DeviceLicenceKeyProvider) async throws -> DeviceLicenceApprovalRequest {
        try ApprovalWire.checkCancellation()
        guard challenge.entitlementID == expectedEntitlementID, approvalRequestID.count == 16 else {
            throw DeviceLicenceApprovalClientFailure.invalidRequest
        }
        let decodedToken = try ApprovalWire.decode(token, count: 32)
        do {
            let key = try await device.publicKeyX963()
            try ApprovalWire.checkCancellation()
            guard key == challenge.devicePublicKeyX963,
                  let publicKey = DeviceLicenceVerifier.canonicalPublicKey(key) else { throw DeviceLicenceApprovalClientFailure.invalidProof }
            let message = Data([challenge.purpose, "1", challenge.algorithm, challenge.entitlementID,
                DeviceLicenceVerifier.encode(key), challenge.deviceKeyHash, challenge.challengeID, challenge.nonce,
                String(challenge.expiresAt), DeviceLicenceVerifier.encode(Data(SHA256.hash(data: decodedToken))),
                DeviceLicenceVerifier.encode(approvalRequestID)].joined(separator: "\n").utf8)
            let signed = try await device.signLicenceProof(message)
            try ApprovalWire.checkCancellation()
            guard signed.count == 64, let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signed),
                  publicKey.isValidSignature(signature, for: message) else { throw DeviceLicenceApprovalClientFailure.invalidProof }
            return .init(challenge: challenge, approvalRequestID: approvalRequestID, signature: signed, token: token, origin: origin)
        } catch let known as DeviceLicenceApprovalClientFailure { throw known }
        catch { throw Task.isCancelled || error is CancellationError ? DeviceLicenceApprovalClientFailure.cancelled : .keyUnavailable }
    }

    func approve(_ request: DeviceLicenceApprovalRequest) async throws -> DeviceLicenceApprovalResult {
        guard request.origin == origin, request.challenge.entitlementID == expectedEntitlementID else {
            throw DeviceLicenceApprovalClientFailure.invalidRequest
        }
        let object = try await exchange(path: "approve", body: request.body)
        do {
            try ApprovalWire.exact(object, ["ok", "code", "receipt"])
            guard try ApprovalWire.boolean(object["ok"]),
                  let disposition = try DeviceLicenceApprovalDisposition(rawValue: ApprovalWire.string(object["code"])) else {
                throw DeviceLicenceApprovalClientFailure.invalidResponse
            }
            let envelope = try ApprovalWire.string(object["receipt"])
            try ApprovalWire.envelope(envelope, entitlementID: expectedEntitlementID, deviceHash: request.challenge.deviceKeyHash)
            return .init(disposition: disposition, envelope: envelope)
        } catch { throw DeviceLicenceApprovalClientFailure.invalidResponse }
    }

    private func exchange(path: String, body: Data) async throws -> [String: ApprovalWire.Value] {
        try ApprovalWire.checkCancellation()
        guard body.count <= 2048, let url = URL(string: "/device-licensing/v1/" + path, relativeTo: origin)?.absoluteURL else {
            throw DeviceLicenceApprovalClientFailure.invalidRequest
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"; request.httpBody = body; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response: DeviceLicenceApprovalHTTPResponse
        do { response = try await transport.send(request, maximumResponseBytes: Self.maximumResponseBytes) }
        catch {
            if Task.isCancelled || error is CancellationError || error as? DeviceLicenceApprovalClientFailure == .cancelled {
                throw DeviceLicenceApprovalClientFailure.cancelled
            }
            if error as? DeviceLicenceApprovalClientFailure == .invalidResponse { throw DeviceLicenceApprovalClientFailure.invalidResponse }
            throw DeviceLicenceApprovalClientFailure.transportUncertain
        }
        try ApprovalWire.checkCancellation()
        guard response.body.count <= Self.maximumResponseBytes else { throw DeviceLicenceApprovalClientFailure.invalidResponse }
        let types = response.headers.filter { $0.key.caseInsensitiveCompare("content-type") == .orderedSame }.map(\.value)
        guard types.count == 1, ApprovalWire.contentType(types[0]) else { throw DeviceLicenceApprovalClientFailure.invalidResponse }
        let object = try ApprovalWire.parse(response.body)
        guard response.statusCode == 200 else { throw try ApprovalWire.serverFailure(status: response.statusCode, object: object) }
        return object
    }
}

private enum ApprovalWire {
    indirect enum Value { case object([String: Value]), string(String), integer(UInt64), boolean(Bool) }
    static func checkCancellation() throws { if Task.isCancelled { throw DeviceLicenceApprovalClientFailure.cancelled } }
    static func origin(_ url: URL) throws -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.path.isEmpty || parts.path == "/", parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { throw DeviceLicenceApprovalClientFailure.invalidConfiguration }
        parts.host = host.lowercased(); parts.path = ""
        guard let normalized = parts.url else { throw DeviceLicenceApprovalClientFailure.invalidConfiguration }
        return normalized
    }
    static func decode(_ value: String, count: Int) throws -> Data {
        guard value.utf8.count == (count * 8 + 5) / 6,
              value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw DeviceLicenceApprovalClientFailure.invalidRequest
        }
        var encoded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.utf8.count % 4) % 4)
        guard let bytes = Data(base64Encoded: encoded), bytes.count == count, DeviceLicenceVerifier.encode(bytes) == value else {
            throw DeviceLicenceApprovalClientFailure.invalidRequest
        }
        return bytes
    }
    static func contentType(_ value: String) -> Bool {
        let parts = value.lowercased().split(separator: ";", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        return parts == ["application/json"] || parts == ["application/json", "charset=utf-8"]
    }
    static func exact(_ object: [String: Value], _ fields: [String]) throws {
        guard Set(object.keys) == Set(fields) else { throw DeviceLicenceApprovalClientFailure.invalidResponse }
    }
    static func object(_ value: Value?) throws -> [String: Value] {
        guard case .object(let result) = value else { throw DeviceLicenceApprovalClientFailure.invalidResponse }; return result
    }
    static func string(_ value: Value?) throws -> String {
        guard case .string(let result) = value else { throw DeviceLicenceApprovalClientFailure.invalidResponse }; return result
    }
    static func integer(_ value: Value?) throws -> UInt64 {
        guard case .integer(let result) = value else { throw DeviceLicenceApprovalClientFailure.invalidResponse }; return result
    }
    static func boolean(_ value: Value?) throws -> Bool {
        guard case .boolean(let result) = value else { throw DeviceLicenceApprovalClientFailure.invalidResponse }; return result
    }
    static func serverFailure(status: Int, object: [String: Value]) throws -> DeviceLicenceApprovalClientFailure {
        try exact(object, ["ok", "code"])
        guard try !boolean(object["ok"]) else { throw DeviceLicenceApprovalClientFailure.invalidResponse }
        let code = try string(object["code"])
        switch (status, code) {
        case (403, "activation_rejected"): return .activationRejected
        case (404, "unavailable"), (404, "not_found"), (403, "forbidden"), (503, "temporarily_unavailable"): return .unavailable
        case (408, "request_timeout"), (400, "request_aborted"): return .transportUncertain
        case (400, "invalid_request"), (405, "method_not_allowed"), (413, "body_too_large"), (415, "unsupported_media_type"): return .invalidRequest
        default: return .invalidResponse
        }
    }
    static func envelope(_ value: String, entitlementID: String, deviceHash: String) throws {
        guard value.utf8.prefix(1025).count <= 1024, value.hasPrefix("CLIPD1.") else { throw DeviceLicenceApprovalClientFailure.invalidResponse }
        let parts = value.dropFirst(7).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw DeviceLicenceApprovalClientFailure.invalidResponse }
        // Payload length is inferred only after bounding the encoded envelope.
        let payloadText = String(parts[0]), count = payloadText.utf8.count * 6 / 8
        guard count > 0, count <= 512 else { throw DeviceLicenceApprovalClientFailure.invalidResponse }
        let payload = try decode(payloadText, count: count); _ = try decode(String(parts[1]), count: 64)
        guard payload.allSatisfy({ $0 == 10 || (32...126).contains($0) }), let text = String(data: payload, encoding: .ascii) else {
            throw DeviceLicenceApprovalClientFailure.invalidResponse
        }
        let fields = text.components(separatedBy: "\n")
        guard fields.count == 10, fields[0] == "cliphoard.device-receipt", fields[1] == "1", fields[2] == "P256-SHA256",
              fields[4] == entitlementID, fields[5] == deviceHash, fields[8] == "pro", fields[9] == "perpetual",
              let epoch = UInt64(fields[7]), epoch > 0, epoch <= DeviceLicenceVerifier.maximumEpoch, String(epoch) == fields[7] else {
            throw DeviceLicenceApprovalClientFailure.invalidResponse
        }
        let key = Array(fields[3].utf8)
        func alphaNumeric(_ byte: UInt8) -> Bool { (97...122).contains(byte) || (48...57).contains(byte) }
        guard (1...32).contains(key.count), key.first.map(alphaNumeric) == true,
              key.allSatisfy({ alphaNumeric($0) || $0 == 45 || $0 == 95 }) else { throw DeviceLicenceApprovalClientFailure.invalidResponse }
        _ = try decode(fields[6], count: 16)
    }

    /// Bounded ASCII JSON subset used by this exact server: objects, strings,
    /// unsigned integers and booleans. Rejects duplicate decoded keys before loss.
    static func parse(_ data: Data) throws -> [String: Value] {
        guard !data.isEmpty, data.count <= 2048 else { throw DeviceLicenceApprovalClientFailure.invalidResponse }
        var parser = Parser(bytes: Array(data)); let value = try parser.value(depth: 0)
        parser.space(); guard parser.index == parser.bytes.count else { throw DeviceLicenceApprovalClientFailure.invalidResponse }
        return try object(value)
    }
    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var current: UInt8? { index < bytes.count ? bytes[index] : nil }
        mutating func space() { while let c = current, [9, 10, 13, 32].contains(c) { index += 1 } }
        mutating func take(_ c: UInt8) throws { space(); guard current == c else { throw DeviceLicenceApprovalClientFailure.invalidResponse }; index += 1 }
        mutating func text() throws -> String {
            try take(34); var output: [UInt8] = []
            while let c = current {
                index += 1
                if c == 34 { return String(bytes: output, encoding: .ascii)! }
                guard c >= 32, c <= 126 else { throw DeviceLicenceApprovalClientFailure.invalidResponse }
                if c != 92 { output.append(c); continue }
                guard let escape = current else { throw DeviceLicenceApprovalClientFailure.invalidResponse }; index += 1
                let escapes: [UInt8: UInt8] = [34: 34, 92: 92, 47: 47, 98: 8, 102: 12, 110: 10, 114: 13, 116: 9]
                if let decoded = escapes[escape] { output.append(decoded); continue }
                guard escape == 117, index + 4 <= bytes.count,
                      let hex = String(bytes: bytes[index..<(index + 4)], encoding: .ascii),
                      hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                      let decoded = UInt8(hex, radix: 16), decoded <= 127 else { throw DeviceLicenceApprovalClientFailure.invalidResponse }
                index += 4; output.append(decoded)
            }
            throw DeviceLicenceApprovalClientFailure.invalidResponse
        }
        mutating func value(depth: Int) throws -> Value {
            space()
            if current == 123 {
                guard depth < 2 else { throw DeviceLicenceApprovalClientFailure.invalidResponse }
                index += 1; space(); var object: [String: Value] = [:]
                if current != 125 { while true {
                    let key = try text(); guard object[key] == nil else { throw DeviceLicenceApprovalClientFailure.invalidResponse }
                    try take(58); object[key] = try value(depth: depth + 1); space()
                    if current != 44 { break }; index += 1
                } }
                try take(125); return .object(object)
            }
            if current == 34 { return .string(try text()) }
            for (word, result) in [(Array("true".utf8), true), (Array("false".utf8), false)] {
                if bytes[index...].starts(with: word) { index += word.count; return .boolean(result) }
            }
            let start = index
            while let c = current, (48...57).contains(c) { index += 1 }
            guard index > start, index - start == 1 || bytes[start] != 48,
                  let text = String(bytes: bytes[start..<index], encoding: .ascii), let number = UInt64(text) else {
                throw DeviceLicenceApprovalClientFailure.invalidResponse
            }
            return .integer(number)
        }
    }
}
#endif
