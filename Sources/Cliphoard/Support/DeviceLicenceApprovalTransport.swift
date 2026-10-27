#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE
import Foundation

/// Explicitly constructed only. Immutable configuration; every send owns a separate
/// ephemeral session/task. No default endpoint, shared stores or network-setting changes.
final class DeviceLicenceURLSessionTransport: DeviceLicenceApprovalTransport, @unchecked Sendable {
    private let resourceTimeout: TimeInterval
    private let protocolClasses: [AnyClass]
    /// protocolClasses is an explicit local test seam. Production callers omit it.
    init(resourceTimeout: TimeInterval, protocolClasses: [AnyClass] = []) throws {
        guard resourceTimeout.isFinite, resourceTimeout > 0, resourceTimeout <= 300 else {
            throw DeviceLicenceApprovalClientFailure.invalidConfiguration
        }
        self.resourceTimeout = resourceTimeout; self.protocolClasses = protocolClasses
    }
    static func configuration(resourceTimeout: TimeInterval, protocolClasses: [AnyClass]) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.urlCredentialStorage = nil; configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false; configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = resourceTimeout; configuration.timeoutIntervalForResource = resourceTimeout
        if !protocolClasses.isEmpty { configuration.protocolClasses = protocolClasses }
        return configuration
    }
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> DeviceLicenceApprovalHTTPResponse {
        guard let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host?.isEmpty == false, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, request.httpMethod == "POST", request.httpBodyStream == nil,
              let body = request.httpBody, !body.isEmpty, body.count <= 2048,
              request.value(forHTTPHeaderField: "Authorization") == nil,
              request.value(forHTTPHeaderField: "Proxy-Authorization") == nil,
              request.value(forHTTPHeaderField: "Cookie") == nil,
              (1...DeviceLicenceApprovalClient.maximumResponseBytes).contains(maximumResponseBytes) else {
            throw DeviceLicenceApprovalClientFailure.invalidRequest
        }
        if Task.isCancelled { throw DeviceLicenceApprovalClientFailure.cancelled }
        var command = request
        command.timeoutInterval = resourceTimeout; command.cachePolicy = .reloadIgnoringLocalCacheData; command.httpShouldHandleCookies = false
        let operation = DeviceLicenceApprovalSessionOperation(maximumResponseBytes: maximumResponseBytes)
        return try await operation.run(command, resourceTimeout: resourceTimeout, protocolClasses: protocolClasses)
    }
}

/// Mutable state is locked; finish has one winner and resumes the continuation once.
/// Cancellation/timeout only cancel this operation's session. They do not revoke a
/// server commit or prove that request bytes did not reach it.
final class DeviceLicenceApprovalSessionOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let maximumResponseBytes: Int
    private var continuation: CheckedContinuation<DeviceLicenceApprovalHTTPResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var deadline: DispatchWorkItem?
    private var finished = false
    private var expectedURL: URL?
    private var response: HTTPURLResponse?
    private var body = Data()
    init(maximumResponseBytes: Int) { self.maximumResponseBytes = maximumResponseBytes }

    func run(_ request: URLRequest, resourceTimeout: TimeInterval, protocolClasses: [AnyClass]) async throws -> DeviceLicenceApprovalHTTPResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !finished else { lock.unlock(); continuation.resume(throwing: DeviceLicenceApprovalClientFailure.cancelled); return }
                self.continuation = continuation; expectedURL = request.url
                let configuration = DeviceLicenceURLSessionTransport.configuration(resourceTimeout: resourceTimeout, protocolClasses: protocolClasses)
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                let timer = DispatchWorkItem { [weak self] in self?.finish(.failure(.transportUncertain)) }
                self.session = session; self.task = task; deadline = timer
                lock.unlock()
                // Also bound cooperative custom protocols that do not honor Foundation's timeout.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + resourceTimeout, execute: timer)
                task.resume()
            }
        } onCancel: { self.finish(.failure(.cancelled)) }
    }

    private func finish(_ result: Result<DeviceLicenceApprovalHTTPResponse, DeviceLicenceApprovalClientFailure>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation, session = self.session, task = self.task, deadline = self.deadline
        self.continuation = nil; self.session = nil; self.task = nil; self.deadline = nil
        body.removeAll(keepingCapacity: false); response = nil
        lock.unlock()
        deadline?.cancel(); task?.cancel(); session?.invalidateAndCancel()
        switch result {
        case .success(let response): continuation?.resume(returning: response)
        case .failure(let error): continuation?.resume(throwing: error)
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        let allowed = !finished && self.response == nil && response.url == expectedURL
            && response is HTTPURLResponse && response.expectedContentLength <= Int64(maximumResponseBytes)
        if allowed { self.response = response as? HTTPURLResponse }
        lock.unlock()
        completionHandler(allowed ? .allow : .cancel)
        if !allowed { finish(.failure(.invalidResponse)) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard response != nil, data.count <= maximumResponseBytes - body.count else {
            lock.unlock(); finish(.failure(.invalidResponse)); return
        }
        body.append(data); lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        let response = self.response, bytes = body
        lock.unlock()
        guard error == nil else { finish(.failure(.transportUncertain)); return }
        guard let response else { finish(.failure(.invalidResponse)); return }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        finish(.success(.init(statusCode: response.statusCode, headers: headers, body: bytes)))
    }
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) { finish(.failure(.transportUncertain)) }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil); finish(.failure(.transportUncertain))
    }
    private func authentication(_ challenge: URLAuthenticationChallenge,
                                completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            // Normal operating-system TLS validation, never custom trust acceptance.
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil); finish(.failure(.transportUncertain))
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        authentication(challenge, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        authentication(challenge, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse,
                    completionHandler: @escaping (CachedURLResponse?) -> Void) { completionHandler(nil) }
}
#endif
