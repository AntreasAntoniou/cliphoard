#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE
import XCTest
@testable import Cliphoard

private final class ApprovalProtocolState: @unchecked Sendable {
    let lock = NSLock()
    var handler: ((URLProtocol) -> Void)?
    var stopped: (() -> Void)?
    var requests: [URLRequest] = []
    func configure(_ handler: @escaping (URLProtocol) -> Void, stopped: (() -> Void)? = nil) {
        lock.lock(); defer { lock.unlock() }; self.handler = handler; self.stopped = stopped; requests = []
    }
    func start(_ instance: URLProtocol) {
        lock.lock(); requests.append(instance.request); let callback = handler; lock.unlock()
        if let callback { callback(instance) }
        else { instance.client?.urlProtocol(instance, didFailWithError: URLError(.unsupportedURL)) }
    }
    func stop() { lock.lock(); let callback = stopped; lock.unlock(); callback?() }
    func snapshot() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}
private final class ApprovalStubURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = ApprovalProtocolState()
    // Intercept every URL in this explicit fixture session: no fallback can reach a socket.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.state.start(self) }
    override func stopLoading() { Self.state.stop() }
}
private final class ApprovalChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}

final class DeviceLicenceApprovalTransportTests: XCTestCase {
    private let url = URL(string: "https://transport.example.invalid/device-licensing/v1/begin")!
    private func request() -> URLRequest {
        var value = URLRequest(url: url); value.httpMethod = "POST"; value.httpBody = Data("{}".utf8)
        value.setValue("application/json", forHTTPHeaderField: "Content-Type"); return value
    }
    private func transport(timeout: TimeInterval = 1) throws -> DeviceLicenceURLSessionTransport {
        try .init(resourceTimeout: timeout, protocolClasses: [ApprovalStubURLProtocol.self])
    }
    private func emit(_ instance: URLProtocol, headers: [String: String] = ["Content-Type": "application/json"], chunks: [Data], finish: Bool = true) {
        let response = HTTPURLResponse(url: instance.request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        instance.client?.urlProtocol(instance, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks { instance.client?.urlProtocol(instance, didLoad: chunk) }
        if finish { instance.client?.urlProtocolDidFinishLoading(instance) }
    }
    private func failure(_ expected: DeviceLicenceApprovalClientFailure, _ action: () async throws -> DeviceLicenceApprovalHTTPResponse) async {
        do { _ = try await action(); XCTFail("expected typed failure") }
        catch { XCTAssertEqual(error as? DeviceLicenceApprovalClientFailure, expected) }
    }

    func testEphemeralConfigurationExplicitlyRemovesStoresAndCookies() throws {
        let configuration = DeviceLicenceURLSessionTransport.configuration(resourceTimeout: 1, protocolClasses: [ApprovalStubURLProtocol.self])
        XCTAssertNil(configuration.urlCache); XCTAssertNil(configuration.urlCredentialStorage); XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 1); XCTAssertEqual(configuration.timeoutIntervalForRequest, 1)
        XCTAssertThrowsError(try transport(timeout: .infinity)); XCTAssertThrowsError(try transport(timeout: 0))
        XCTAssertThrowsError(try transport(timeout: .nan)); XCTAssertThrowsError(try transport(timeout: 301))
    }
    func testBoundedChunksAndNoCookiePersistenceAcrossCalls() async throws {
        ApprovalStubURLProtocol.state.configure { self.emit($0, headers: ["Content-Type": "application/json", "Set-Cookie": "synthetic_cookie=fixture; Secure"], chunks: [Data("{".utf8), Data("}".utf8)]) }
        let native = try transport()
        for _ in 0..<2 {
            let response = try await native.send(request(), maximumResponseBytes: 2)
            XCTAssertEqual(response.body, Data("{}".utf8)); XCTAssertEqual(response.statusCode, 200)
        }
        let requests = ApprovalStubURLProtocol.state.snapshot(); XCTAssertEqual(requests.count, 2)
        for sent in requests {
            XCTAssertNil(sent.value(forHTTPHeaderField: "Cookie")); XCTAssertNil(sent.value(forHTTPHeaderField: "Authorization"))
            XCTAssertFalse(sent.httpShouldHandleCookies)
        }
    }
    func testDeclaredAndActualAccumulatedResponseLimits() async throws {
        let native = try transport()
        ApprovalStubURLProtocol.state.configure { self.emit($0, headers: ["Content-Type": "application/json", "Content-Length": "5000"], chunks: []) }
        await failure(.invalidResponse) { try await native.send(self.request(), maximumResponseBytes: 16) }
        ApprovalStubURLProtocol.state.configure { self.emit($0, headers: ["Content-Type": "application/json", "Content-Length": "1"], chunks: [Data(repeating: 65, count: 10), Data(repeating: 66, count: 10)]) }
        await failure(.invalidResponse) { try await native.send(self.request(), maximumResponseBytes: 16) }
    }
    func testExplicitDeadlineTerminatesAStalledLocalProtocol() async throws {
        ApprovalStubURLProtocol.state.configure { _ in }
        let native = try transport(timeout: 0.03), started = Date()
        await failure(.transportUncertain) { try await native.send(self.request(), maximumResponseBytes: 16) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }
    func testCancellationCancelsOnlyTheOwnedTask() async throws {
        let started = expectation(description: "local protocol started"), stopped = expectation(description: "owned task stopped")
        ApprovalStubURLProtocol.state.configure({ _ in started.fulfill() }, stopped: { stopped.fulfill() })
        let native = try transport(), command = request()
        let task = Task { try await native.send(command, maximumResponseBytes: 16) }
        await fulfillment(of: [started], timeout: 1); task.cancel()
        await failure(.cancelled) { try await task.value }
        await fulfillment(of: [stopped], timeout: 1)
    }
    func testNativeFailuresAreSanitized() async throws {
        ApprovalStubURLProtocol.state.configure { instance in
            instance.client?.urlProtocol(instance, didFailWithError: NSError(domain: "synthetic-private-domain", code: 7,
                userInfo: [NSLocalizedDescriptionKey: "synthetic-private-body"]))
        }
        let native = try transport()
        await failure(.transportUncertain) { try await native.send(self.request(), maximumResponseBytes: 16) }
    }
    func testInvalidRequestsCannotReachTheProtocol() async throws {
        ApprovalStubURLProtocol.state.configure { _ in XCTFail("no dispatch allowed") }
        let native = try transport()
        for url in ["http://transport.example.invalid", "https://user:secret@transport.example.invalid", "https://transport.example.invalid?token=synthetic"] {
            var command = request(); command.url = URL(string: url)
            await failure(.invalidRequest) { try await native.send(command, maximumResponseBytes: 16) }
        }
        var command = request(); command.setValue("synthetic", forHTTPHeaderField: "Authorization")
        await failure(.invalidRequest) { try await native.send(command, maximumResponseBytes: 16) }
        XCTAssertTrue(ApprovalStubURLProtocol.state.snapshot().isEmpty)
    }
    func testRedirectAuthenticationAndCacheDelegateBoundaries() throws {
        let configuration = DeviceLicenceURLSessionTransport.configuration(resourceTimeout: 1, protocolClasses: [ApprovalStubURLProtocol.self])
        let session = URLSession(configuration: configuration), task = session.dataTask(with: request())
        defer { task.cancel(); session.invalidateAndCancel() } // Never resumed.
        let operation = DeviceLicenceApprovalSessionOperation(maximumResponseBytes: 16)
        let redirect = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://other.example.invalid"])!
        var redirectCalled = false
        operation.urlSession(session, task: task, willPerformHTTPRedirection: redirect, newRequest: URLRequest(url: URL(string: "https://other.example.invalid")!)) { proposed in
            redirectCalled = true; XCTAssertNil(proposed)
        }
        XCTAssertTrue(redirectCalled)
        for method in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodServerTrust] {
            let protection = URLProtectionSpace(host: "transport.example.invalid", port: 443, protocol: "https", realm: nil, authenticationMethod: method)
            let challenge = URLAuthenticationChallenge(protectionSpace: protection, proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil, sender: ApprovalChallengeSender())
            let handler = DeviceLicenceApprovalSessionOperation(maximumResponseBytes: 16)
            var called = false
            handler.urlSession(session, task: task, didReceive: challenge) { disposition, credential in
                called = true; XCTAssertNil(credential)
                XCTAssertEqual(disposition, method == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge)
            }
            XCTAssertTrue(called)
        }
        let cached = CachedURLResponse(response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!, data: Data())
        operation.urlSession(session, dataTask: task, willCacheResponse: cached) { XCTAssertNil($0) }
    }
}
#endif
