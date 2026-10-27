#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE && !APP_STORE
import XCTest
import Foundation
@testable import Cliphoard

actor BootstrapCaptureTransport: DeviceLicenceApprovalTransport {
    private(set) var requests: [URLRequest] = [], limits: [Int] = []
    var gate: BootstrapTestGate?
    var failure: Error?
    let response = DeviceLicenceApprovalHTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
    func hold(_ gate: BootstrapTestGate) { self.gate = gate }
    func fail(_ value: Error) { failure = value }
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> DeviceLicenceApprovalHTTPResponse {
        requests.append(request); limits.append(maximumResponseBytes)
        if let gate { await gate.pause() }
        if let failure { throw failure }
        return response
    }
}
struct BootstrapPrivateDependencyError: Error { let secret = "private failure must not escape" }

final class DeviceLicenceBootstrapRoutingTests: XCTestCase {
    let origin = URL(string: "https://bootstrap.example.invalid")!
    func request(path: String = "begin") -> URLRequest {
        var value = URLRequest(url: URL(string: "/device-licensing/v1/" + path, relativeTo: origin)!.absoluteURL)
        value.httpMethod = "POST"; value.httpBody = Data(" {\"byteExact\": true}\n".utf8)
        value.httpShouldHandleCookies = false
        value.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return value
    }
    func testExactBeginAndApproveAddOnlyPinnedLocatorAndPreserveRetries() async throws {
        let f = BootstrapFixture(), transport = BootstrapCaptureTransport()
        let wrapper = try DeviceLicenceBootstrapRoutingTransport(bootstrap: f.verified(), origin: origin, transport: transport)
        for path in ["begin", "approve", "approve"] {
            let value = request(path: path)
            let reply = try await wrapper.send(value, maximumResponseBytes: 1777)
            XCTAssertEqual(reply.statusCode, 200); XCTAssertEqual(reply.body, Data("{}".utf8))
        }
        let values = await transport.requests, limits = await transport.limits
        XCTAssertEqual(limits, [1777, 1777, 1777]); XCTAssertEqual(values.count, 3)
        for (index, value) in values.enumerated() {
            let original = request(path: index == 0 ? "begin" : "approve")
            XCTAssertEqual(value.url, original.url); XCTAssertEqual(value.httpMethod, original.httpMethod)
            XCTAssertEqual(value.httpBody, original.httpBody); XCTAssertEqual(value.httpShouldHandleCookies, original.httpShouldHandleCookies)
            XCTAssertEqual(value.value(forHTTPHeaderField: "X-Cliphoard-Entitlement"), f.entitlement)
            XCTAssertEqual(value.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(value.allHTTPHeaderFields?.count, (original.allHTTPHeaderFields?.count ?? 0) + 1)
            XCTAssertFalse(value.url!.absoluteString.contains(f.handle))
            XCTAssertFalse((value.allHTTPHeaderFields ?? [:]).values.contains(f.handle))
        }
        XCTAssertEqual(values[1].httpBody, values[2].httpBody)
    }
    func testBadOriginsAreRejectedWithoutDispatch() async throws {
        let f = BootstrapFixture(), capture = BootstrapCaptureTransport()
        for raw in ["http://bootstrap.example.invalid", "https://x.invalid/path", "https://x.invalid?", "https://x.invalid#", "https://user@x.invalid", "https://x.invalid:0", "https://x.invalid:65536"] {
            XCTAssertThrowsError(try DeviceLicenceBootstrapRoutingTransport(bootstrap: f.verified(), origin: URL(string: raw)!, transport: capture))
        }
        let count = await capture.requests.count; XCTAssertEqual(count, 0)
    }
    func testMalformedTargetsMethodsBodiesAndBoundsNeverDispatch() async throws {
        let f = BootstrapFixture(), capture = BootstrapCaptureTransport()
        let wrapper = try DeviceLicenceBootstrapRoutingTransport(bootstrap: f.verified(), origin: origin, transport: capture)
        var values: [(URLRequest, Int)] = []
        for url in ["http://bootstrap.example.invalid/device-licensing/v1/begin", "https://foreign.invalid/device-licensing/v1/begin",
                    "https://bootstrap.example.invalid:443/device-licensing/v1/begin", "https://bootstrap.example.invalid/device-licensing/v1/begin?",
                    "https://bootstrap.example.invalid/device-licensing/v1/approve#", "https://user@bootstrap.example.invalid/device-licensing/v1/begin",
                    "https://bootstrap.example.invalid/device-licensing/v1/%62egin", "https://bootstrap.example.invalid/device-licensing/v1/begin/",
                    "https://bootstrap.example.invalid/device-licensing/v1/confirm"] {
            var value = request(); value.url = URL(string: url)!; values.append((value, 2048))
        }
        for method in ["GET", "HEAD", "PUT", "POSTX"] { var value = request(); value.httpMethod = method; values.append((value, 2048)) }
        var relative = request(); relative.url = URL(string: "/device-licensing/v1/begin", relativeTo: origin)!; values.append((relative, 2048))
        var empty = request(); empty.httpBody = Data(); values.append((empty, 2048))
        var large = request(); large.httpBody = Data(repeating: 65, count: 2049); values.append((large, 2048))
        var stream = request(); stream.httpBodyStream = InputStream(data: Data([1])); values.append((stream, 2048))
        values += [(request(), 0), (request(), 2049)]
        for (value, limit) in values {
            do { _ = try await wrapper.send(value, maximumResponseBytes: limit); XCTFail("invalid request dispatched: \(value.url?.absoluteString ?? "nil")") }
            catch { XCTAssertEqual(error as? DeviceLicenceApprovalClientFailure, .invalidRequest) }
        }
        let count = await capture.requests.count; XCTAssertEqual(count, 0)
    }
    func testExistingRoutingAndAuthorityHeadersRejectCaseInsensitively() async throws {
        let f = BootstrapFixture(), capture = BootstrapCaptureTransport()
        let wrapper = try DeviceLicenceBootstrapRoutingTransport(bootstrap: f.verified(), origin: origin, transport: capture)
        for header in ["X-Cliphoard-Entitlement", "x-cliphoard-entitlement", "X-CLIPHOARD-ENTITLEMENT", "Host", "Authorization", "Proxy-Authorization", "Cookie"] {
            var value = request(); value.setValue("caller supplied", forHTTPHeaderField: header)
            do { _ = try await wrapper.send(value, maximumResponseBytes: 2048); XCTFail("header accepted") }
            catch { XCTAssertEqual(error as? DeviceLicenceApprovalClientFailure, .invalidRequest) }
        }
        let count = await capture.requests.count; XCTAssertEqual(count, 0)
    }
    func testFoundationNormalizedPostIsTheActualMethodSeenByWrapper() async throws {
        let f = BootstrapFixture(), capture = BootstrapCaptureTransport()
        let wrapper = try DeviceLicenceBootstrapRoutingTransport(bootstrap: f.verified(), origin: origin, transport: capture)
        var value = request(); value.httpMethod = "post"
        // URLRequest canonicalizes a known standard method before this boundary.
        // The wrapper cannot inspect the setter's original spelling.
        XCTAssertEqual(value.httpMethod, "POST")
        _ = try await wrapper.send(value, maximumResponseBytes: 2048)
        let methods = await capture.requests.map(\.httpMethod)
        XCTAssertEqual(methods, ["POST"])
    }
    func testCancellationBeforeDispatchAndAfterUnderlyingSendAreFenced() async throws {
        let f = BootstrapFixture(), capture = BootstrapCaptureTransport(), gate = BootstrapTestGate()
        let wrapper = try DeviceLicenceBootstrapRoutingTransport(bootstrap: f.verified(), origin: origin, transport: capture)
        let command = request()
        let before = Task { await gate.pause(); return try await wrapper.send(command, maximumResponseBytes: 2048) }
        await gate.wait(); before.cancel(); await gate.release()
        do { _ = try await before.value; XCTFail("cancelled request succeeded") }
        catch { XCTAssertEqual(error as? DeviceLicenceApprovalClientFailure, .cancelled) }
        let beforeCount = await capture.requests.count; XCTAssertEqual(beforeCount, 0)
        let duringGate = BootstrapTestGate(); await capture.hold(duringGate)
        let during = Task { try await wrapper.send(command, maximumResponseBytes: 2048) }
        await duringGate.wait(); during.cancel(); await duringGate.release()
        do { _ = try await during.value; XCTFail("late response published") }
        catch { XCTAssertEqual(error as? DeviceLicenceApprovalClientFailure, .cancelled) }
        let afterCount = await capture.requests.count; XCTAssertEqual(afterCount, 1)
    }
    func testDependencyFailuresAreSanitizedAndInvalidResponseRemainsClassified() async throws {
        let f = BootstrapFixture(), capture = BootstrapCaptureTransport()
        let wrapper = try DeviceLicenceBootstrapRoutingTransport(bootstrap: f.verified(), origin: origin, transport: capture)
        await capture.fail(BootstrapPrivateDependencyError())
        do { _ = try await wrapper.send(request(), maximumResponseBytes: 2048); XCTFail("failure ignored") }
        catch { XCTAssertEqual(error as? DeviceLicenceApprovalClientFailure, .transportUncertain) }
        await capture.fail(DeviceLicenceApprovalClientFailure.invalidResponse)
        do { _ = try await wrapper.send(request(), maximumResponseBytes: 2048); XCTFail("failure ignored") }
        catch { XCTAssertEqual(error as? DeviceLicenceApprovalClientFailure, .invalidResponse) }
    }
}
#endif
