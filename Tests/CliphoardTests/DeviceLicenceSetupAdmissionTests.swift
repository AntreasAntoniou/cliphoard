#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE && !APP_STORE
import XCTest
import CryptoKit
import Foundation
@testable import Cliphoard

private actor SetupCapture: DeviceLicenceApprovalTransport {
    var requests: [URLRequest] = []
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> DeviceLicenceApprovalHTTPResponse {
        requests.append(request)
        throw DeviceLicenceApprovalClientFailure.unavailable
    }
}
final class DeviceLicenceSetupAdmissionTests: XCTestCase {
    private func fixture() throws -> (VerifiedDeviceLicenceBootstrap, String, P256.Signing.PrivateKey, Data) {
        // Deliberately public synthetic scalar 41. Never a production signer.
        let key = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([41]))
        let entitlement = DeviceLicenceVerifier.encode(Data(repeating: 15, count: 16))
        let payload = Data(["cliphoard.device-bootstrap", "1", "P256-SHA256", "synthetic-admission", "synthetic-profile",
            "synthetic-receipt", entitlement, DeviceLicenceVerifier.encode(Data(repeating: 16, count: 32)), "1800000000", "pro"].joined(separator: "\n").utf8)
        let envelope = "CLIPB1.\(DeviceLicenceVerifier.encode(payload)).\(DeviceLicenceVerifier.encode(try key.signature(for: payload).rawRepresentation))"
        let profile = try DeviceLicenceBootstrapTrustProfile(profileID: "synthetic-profile", bootstrapKeyID: "synthetic-admission",
            bootstrapPublicKey: key.publicKey.x963Representation, receiptIssuers: ["synthetic-receipt": key.publicKey.x963Representation])
        return (try DeviceLicenceBootstrapVerifier.verify(envelope, profile: profile), envelope, key, Data("{\"proof\":\"unchanged-synthetic\"}".utf8))
    }
    private func request(_ path: String = "begin", body: Data) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://admission.synthetic.invalid/device-licensing/v1/\(path)")!)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
    func testExactVerifiedHeaderBodyAndSyntheticBridgeExport() async throws {
        let (verified, envelope, key, body) = try fixture(), capture = SetupCapture()
        let router = try DeviceLicenceBootstrapRoutingTransport(bootstrap: verified, origin: URL(string: "https://admission.synthetic.invalid")!, transport: capture)
        for path in ["begin", "approve"] { _ = try? await router.send(request(path, body: body), maximumResponseBytes: 1024) }
        let requests = await capture.requests; XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Cliphoard-Setup"), envelope)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Cliphoard-Entitlement"), verified.entitlementID)
            XCTAssertEqual(request.httpBody, body)
        }
        XCTAssertEqual(String(describing: verified), "VerifiedDeviceLicenceBootstrap")
        XCTAssertEqual(String(reflecting: verified), "VerifiedDeviceLicenceBootstrap")
        // Optional explicit fixture export, containing only public synthetic inputs.
        // Production transport never logs or persists these headers.
        if let output = ProcessInfo.processInfo.environment["CLIPHOARD_SYNTHETIC_ADMISSION_BRIDGE"] {
            let value: [String: Any] = ["syntheticOnly": true, "origin": "https://admission.synthetic.invalid", "realm": "synthetic-admission",
                "trust": ["expectedProfileID": "synthetic-profile", "bootstrapKeyID": "synthetic-admission",
                    "bootstrapPublicKey": DeviceLicenceVerifier.encode(key.publicKey.x963Representation), "receiptIssuerKeyIDs": ["synthetic-receipt"]],
                "requests": requests.map { ["url": $0.url!.absoluteString, "method": $0.httpMethod!, "headers": $0.allHTTPHeaderFields!,
                    "bodyBase64": $0.httpBody!.base64EncodedString()] }]
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
        }
    }
    func testCallerSetupHeaderAndWrongOriginPathRejectWithoutDispatch() async throws {
        let (verified, _, _, body) = try fixture(), capture = SetupCapture()
        let router = try DeviceLicenceBootstrapRoutingTransport(bootstrap: verified, origin: URL(string: "https://admission.synthetic.invalid")!, transport: capture)
        for name in ["X-Cliphoard-Setup", "x-cliphoard-setup", "X-CLIPHOARD-SETUP"] {
            var value = request(body: body); value.setValue("caller-override", forHTTPHeaderField: name)
            do { _ = try await router.send(value, maximumResponseBytes: 1024); XCTFail("override dispatched") } catch {}
        }
        for url in ["https://other.invalid/device-licensing/v1/begin", "https://admission.synthetic.invalid/device-licensing/v1/begin?query=1", "https://admission.synthetic.invalid/other"] {
            var value = request(body: body); value.url = URL(string: url)
            do { _ = try await router.send(value, maximumResponseBytes: 1024); XCTFail("wrong route dispatched") } catch {}
        }
        let requests = await capture.requests; XCTAssertTrue(requests.isEmpty)
    }
    func testCancellationBeforeDispatchNeverAttachesCredentialToConsumer() async throws {
        let (verified, _, _, body) = try fixture(), capture = SetupCapture()
        let router = try DeviceLicenceBootstrapRoutingTransport(bootstrap: verified, origin: URL(string: "https://admission.synthetic.invalid")!, transport: capture)
        let request = request(body: body)
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await router.send(request, maximumResponseBytes: 1024) }
        do { _ = try await task.value; XCTFail("cancelled send succeeded") } catch {}
        let requests = await capture.requests; XCTAssertTrue(requests.isEmpty)
    }
    func testRoutingTransportDescriptionsDoNotDiscloseSetupCredential() throws {
        let (verified, _, _, _) = try fixture(), capture = SetupCapture()
        let router = try DeviceLicenceBootstrapRoutingTransport(bootstrap: verified, origin: URL(string: "https://admission.synthetic.invalid")!, transport: capture)
        // Boolean-only assertions keep even the failing reproduction credential-free.
        let description = String(describing: router), debug = String(reflecting: router)
        XCTAssertFalse(description.contains("CLIPB1."))
        XCTAssertFalse(debug.contains("CLIPB1."))
    }
}
#endif
