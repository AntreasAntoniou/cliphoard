#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE
import XCTest
import CryptoKit
@testable import Cliphoard

final class DeviceLicenceApprovalClientTests: XCTestCase {
    private let origin = URL(string: "https://licensing.example.invalid")!
    private let scope = DeviceLicenceVerifier.encode(Data(repeating: 1, count: 16))
    private let foreign = DeviceLicenceVerifier.encode(Data(repeating: 2, count: 16))
    private let handle = DeviceLicenceVerifier.encode(Data(repeating: 3, count: 32))
    private let token = DeviceLicenceVerifier.encode(Data(repeating: 4, count: 32))
    private let beginID = Data(repeating: 5, count: 16), approvalID = Data(repeating: 6, count: 16)

    private actor Device: DeviceLicenceKeyProvider {
        let key = P256.Signing.PrivateKey()
        var messages: [Data] = []
        var reads = 0
        var badSignature = false
        func publicKeyX963() -> Data { reads += 1; return key.publicKey.x963Representation }
        func signLicenceProof(_ message: Data) throws -> Data {
            messages.append(message)
            return badSignature ? Data(repeating: 0, count: 64) : try key.signature(for: message).rawRepresentation
        }
        func setBadSignature() { badSignature = true }
        func counts() -> (Int, Int) { (reads, messages.count) }
        func lastMessage() -> Data? { messages.last }
    }
    private actor Transport: DeviceLicenceApprovalTransport {
        var response: DeviceLicenceApprovalHTTPResponse
        var requests: [URLRequest] = []
        var limits: [Int] = []
        var error: Error?
        init(body: Data, status: Int = 200, headers: [String: String] = ["Content-Type": "application/json; charset=utf-8"]) {
            response = .init(statusCode: status, headers: headers, body: body)
        }
        func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> DeviceLicenceApprovalHTTPResponse {
            requests.append(request); limits.append(maximumResponseBytes)
            if let error { throw error }; return response
        }
        func setError(_ error: Error) { self.error = error }
        func setResponse(_ response: DeviceLicenceApprovalHTTPResponse) { self.response = response }
        func captured() -> ([URLRequest], [Int]) { (requests, limits) }
    }
    private actor Pause {
        private var continuation: CheckedContinuation<Void, Never>?
        func wait(_ entered: XCTestExpectation) async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation; entered.fulfill()
            }
        }
        func resume() { continuation?.resume(); continuation = nil }
    }
    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private func challenge(_ key: Data, entitlement: String? = nil) throws -> DeviceLicenceApprovalChallenge {
        try .init(entitlementID: entitlement ?? scope, devicePublicKeyX963: key,
                  challengeID: Data(repeating: 7, count: 16), nonce: Data(repeating: 8, count: 32), expiresAt: 1_767_323_645)
    }
    private func challengeBody(_ value: DeviceLicenceApprovalChallenge) throws -> Data {
        try json(["ok": true, "challenge": ["purpose": value.purpose, "version": value.version, "algorithm": value.algorithm,
            "entitlementID": value.entitlementID, "devicePublicKey": DeviceLicenceVerifier.encode(value.devicePublicKeyX963),
            "deviceKeyHash": value.deviceKeyHash, "challengeID": value.challengeID, "nonce": value.nonce, "expiresAt": value.expiresAt]])
    }
    private func client(_ transport: Transport, expected: String? = nil, endpoint: URL? = nil) throws -> DeviceLicenceApprovalClient {
        try .init(origin: endpoint ?? origin, expectedEntitlementID: expected ?? scope, transport: transport)
    }
    private func begin(_ key: Data) throws -> DeviceLicenceBeginRequest {
        try .init(entitlementHandle: handle, devicePublicKeyX963: key, requestID: beginID)
    }
    private func expectFailure<T>(_ failure: DeviceLicenceApprovalClientFailure,
                                  _ action: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await action(); XCTFail("expected typed failure", file: file, line: line) }
        catch { XCTAssertEqual(error as? DeviceLicenceApprovalClientFailure, failure, file: file, line: line) }
    }
    private func envelope(_ value: DeviceLicenceApprovalChallenge, issuer: P256.Signing.PrivateKey = .init()) throws -> String {
        let payload = Data(["cliphoard.device-receipt", "1", "P256-SHA256", "synthetic-client", value.entitlementID,
            value.deviceKeyHash, DeviceLicenceVerifier.encode(Data(repeating: 9, count: 16)), "1767323045", "pro", "perpetual"].joined(separator: "\n").utf8)
        return "CLIPD1." + DeviceLicenceVerifier.encode(payload) + "." + DeviceLicenceVerifier.encode(try issuer.signature(for: payload).rawRepresentation)
    }

    func testConfigurationAndBeginInputsFailBeforeTransport() async throws {
        let transport = Transport(body: Data()), key = P256.Signing.PrivateKey().publicKey.x963Representation
        for url in ["http://licensing.example.invalid", "https://user:secret@licensing.example.invalid", "https://licensing.example.invalid/path",
                    "https://licensing.example.invalid?token=synthetic", "https://licensing.example.invalid#fragment"] {
            XCTAssertThrowsError(try client(transport, endpoint: URL(string: url)!))
        }
        XCTAssertThrowsError(try client(transport, expected: handle))
        XCTAssertThrowsError(try DeviceLicenceBeginRequest(entitlementHandle: handle + "=", devicePublicKeyX963: key, requestID: beginID))
        XCTAssertThrowsError(try DeviceLicenceBeginRequest(entitlementHandle: handle, devicePublicKeyX963: Data(), requestID: beginID))
        XCTAssertThrowsError(try DeviceLicenceBeginRequest(entitlementHandle: handle, devicePublicKeyX963: key, requestID: Data()))
        let captured = await transport.captured(); XCTAssertTrue(captured.0.isEmpty)
    }
    func testExactBeginRequestAndResponse() async throws {
        let device = Device(), key = await device.publicKeyX963(), expected = try challenge(key)
        let transport = Transport(body: try challengeBody(expected)), api = try client(transport), request = try begin(key)
        let received = try await api.begin(request); XCTAssertEqual(received, expected)
        let captured = await transport.captured(), sent = try XCTUnwrap(captured.0.first)
        XCTAssertEqual(sent.url?.absoluteString, origin.absoluteString + "/device-licensing/v1/begin")
        XCTAssertEqual(sent.httpMethod, "POST"); XCTAssertEqual(sent.httpBody, request.body)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(sent.value(forHTTPHeaderField: "Authorization")); XCTAssertNil(sent.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(captured.1, [2048]); XCTAssertLessThanOrEqual(request.body.count, 2048)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.body) as? [String: String])
        XCTAssertEqual(Set(body.keys), ["entitlementHandle", "devicePublicKey", "requestID"])
        XCTAssertEqual(body["requestID"], DeviceLicenceVerifier.encode(beginID))
    }
    func testChallengeScopeAndDeviceMismatchAreRejected() async throws {
        let key = P256.Signing.PrivateKey().publicKey.x963Representation, another = P256.Signing.PrivateKey().publicKey.x963Representation
        for value in [try challenge(key, entitlement: foreign), try challenge(another)] {
            let transport = Transport(body: try challengeBody(value)), api = try client(transport)
            await expectFailure(.invalidResponse) { try await api.begin(try self.begin(key)) }
        }
    }
    func testApprovalMessageMatchesExactJavaScriptElevenLineContract() async throws {
        let device = Device(), key = await device.publicKeyX963(), value = try challenge(key)
        let transport = Transport(body: Data()), api = try client(transport)
        let prepared = try await api.prepareApproval(challenge: value, token: token, approvalRequestID: approvalID, using: device)
        let expected = Data(["cliphoard.device-approval", "1", "P256-SHA256", scope, DeviceLicenceVerifier.encode(key), value.deviceKeyHash,
            value.challengeID, value.nonce, "1767323645", DeviceLicenceVerifier.encode(Data(SHA256.hash(data: Data(repeating: 4, count: 32)))),
            DeviceLicenceVerifier.encode(approvalID)].joined(separator: "\n").utf8)
        let signed = await device.lastMessage(); XCTAssertEqual(signed, expected); XCTAssertNotEqual(expected.last, 10)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: prepared.signature)
        XCTAssertTrue(try P256.Signing.PublicKey(x963Representation: key).isValidSignature(signature, for: expected))
        XCTAssertEqual(prepared.approvalRequestID, approvalID); XCTAssertEqual(prepared.challenge, value)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: prepared.body) as? [String: String])
        XCTAssertEqual(Set(body.keys), ["challengeID", "approvalToken", "approvalRequestID", "deviceSignature"])
        XCTAssertEqual(body["approvalToken"], token); XCTAssertEqual(body["deviceSignature"], DeviceLicenceVerifier.encode(prepared.signature))
        let calls = await transport.captured(); XCTAssertTrue(calls.0.isEmpty)
    }
    func testWrongScopeAndMalformedTokenAreRejectedBeforeSigningOrIdentityRead() async throws {
        let key = P256.Signing.PrivateKey().publicKey.x963Representation, device = Device(), transport = Transport(body: Data()), api = try client(transport)
        await expectFailure(.invalidRequest) { try await api.prepareApproval(challenge: self.challenge(key, entitlement: self.foreign), token: self.token, approvalRequestID: self.approvalID, using: device) }
        await expectFailure(.invalidRequest) { try await api.prepareApproval(challenge: self.challenge(key), token: "123456", approvalRequestID: self.approvalID, using: device) }
        let counts = await device.counts(); XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0)
    }
    func testDifferentIdentityAndInvalidReturnedProofFailClosed() async throws {
        let device = Device(), key = await device.publicKeyX963(), transport = Transport(body: Data()), api = try client(transport)
        let wrong = try challenge(P256.Signing.PrivateKey().publicKey.x963Representation)
        await expectFailure(.invalidProof) { try await api.prepareApproval(challenge: wrong, token: self.token, approvalRequestID: self.approvalID, using: device) }
        await device.setBadSignature()
        await expectFailure(.invalidProof) { try await api.prepareApproval(challenge: self.challenge(key), token: self.token, approvalRequestID: self.approvalID, using: device) }
    }
    func testExplicitApprovalRetryReusesExactBytesAndNeverSignsAgain() async throws {
        let device = Device(), key = await device.publicKeyX963(), value = try challenge(key), raw = try envelope(value)
        let transport = Transport(body: try json(["ok": true, "code": "issued", "receipt": raw])), api = try client(transport)
        let prepared = try await api.prepareApproval(challenge: value, token: token, approvalRequestID: approvalID, using: device)
        let first = try await api.approve(prepared); XCTAssertEqual(first.disposition, .issued); XCTAssertEqual(first.envelope, raw)
        await transport.setResponse(.init(statusCode: 200, headers: ["content-type": "application/json"], body: try json(["ok": true, "code": "already_issued", "receipt": raw])))
        let second = try await api.approve(prepared); XCTAssertEqual(second.disposition, .alreadyIssued); XCTAssertEqual(second.envelope, raw)
        let captured = await transport.captured(); XCTAssertEqual(captured.0.map(\.httpBody), [prepared.body, prepared.body])
        let counts = await device.counts(); XCTAssertEqual(counts.1, 1)
    }
    func testPreparedRequestCannotMoveToAnotherOriginOrEntitlement() async throws {
        let device = Device(), key = await device.publicKeyX963(), transport = Transport(body: Data()), api = try client(transport)
        let prepared = try await api.prepareApproval(challenge: challenge(key), token: token, approvalRequestID: approvalID, using: device)
        await expectFailure(.invalidRequest) { try await self.client(transport, expected: self.foreign).approve(prepared) }
        await expectFailure(.invalidRequest) { try await self.client(transport, endpoint: URL(string: "https://other.example.invalid")!).approve(prepared) }
        let captured = await transport.captured(); XCTAssertTrue(captured.0.isEmpty)
    }
    func testGenericDenialDoesNotInventHoldReason() async throws {
        let key = P256.Signing.PrivateKey().publicKey.x963Representation
        let transport = Transport(body: try json(["ok": false, "code": "activation_rejected"]), status: 403), api = try client(transport)
        await expectFailure(.activationRejected) { try await api.begin(try self.begin(key)) }
    }
    func testDependencyErrorsAreTypedAndHaveNoAutomaticRetry() async throws {
        let key = P256.Signing.PrivateKey().publicKey.x963Representation, transport = Transport(body: Data()), api = try client(transport)
        await transport.setError(NSError(domain: "synthetic-secret", code: 42, userInfo: [NSLocalizedDescriptionKey: token]))
        await expectFailure(.transportUncertain) { try await api.begin(try self.begin(key)) }
        let captured = await transport.captured(); XCTAssertEqual(captured.0.count, 1)
    }
    func testResponseLimitsContentTypeDuplicatesAndUnknownFields() async throws {
        let key = P256.Signing.PrivateKey().publicKey.x963Representation, valid = try challengeBody(challenge(key))
        let text = String(data: valid, encoding: .utf8)!
        let bodies = [Data(repeating: 65, count: 2049), Data("{\"ok\":false,\"ok\":true}".utf8),
            Data(text.replacingOccurrences(of: "{", with: "{\"private\":\"synthetic\",", range: text.startIndex..<text.index(after: text.startIndex)).utf8),
            Data(text.replacingOccurrences(of: "\"ok\":true", with: "\"o\\u006b\":true,\"ok\":true").utf8),
            Data([0xef, 0xbb, 0xbf]) + valid, Data([0xc3, 0x28]), valid + Data("garbage".utf8)]
        for body in bodies {
            let transport = Transport(body: body), api = try client(transport)
            await expectFailure(.invalidResponse) { try await api.begin(try self.begin(key)) }
        }
        for headers in [[:], ["content-type": "text/html"], ["content-type": "application/json", "Content-Type": "application/json"]] {
            let transport = Transport(body: valid, headers: headers), api = try client(transport)
            await expectFailure(.invalidResponse) { try await api.begin(try self.begin(key)) }
        }
    }
    func testWrongReceiptScopeExtraOutputAndMalformedReceiptAreRejected() async throws {
        let device = Device(), key = await device.publicKeyX963(), value = try challenge(key), transport = Transport(body: Data()), api = try client(transport)
        let prepared = try await api.prepareApproval(challenge: value, token: token, approvalRequestID: approvalID, using: device)
        for body in [try json(["ok": true, "code": "issued", "receipt": envelope(challenge(key, entitlement: foreign))]),
                     try json(["ok": true, "code": "issued", "receipt": "CLIPD1.invalid"]),
                     try json(["ok": true, "code": "issued", "receipt": envelope(value), "token": token]),
                     try json(["ok": true, "code": "ready", "receipt": envelope(value)])] {
            await transport.setResponse(.init(statusCode: 200, headers: ["content-type": "application/json"], body: body))
            await expectFailure(.invalidResponse) { try await api.approve(prepared) }
        }
    }
    func testCancelledBeforeDispatchHasNoTransportCall() async throws {
        let key = P256.Signing.PrivateKey().publicKey.x963Representation, transport = Transport(body: Data()), api = try client(transport), command = try begin(key)
        let pause = Pause(), entered = expectation(description: "before client entry")
        let task = Task { await pause.wait(entered); return try await api.begin(command) }
        await fulfillment(of: [entered], timeout: 1); task.cancel(); await pause.resume()
        await expectFailure(.cancelled) { try await task.value }
        let captured = await transport.captured(); XCTAssertTrue(captured.0.isEmpty)
    }
}
#endif
