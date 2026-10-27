#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE && !APP_STORE
import Foundation

/// Adds a locator, not authority. The verified bootstrap never supplies an origin.
/// This wrapper does not retry, allocate service state or change request bodies.
struct DeviceLicenceBootstrapRoutingTransport: DeviceLicenceApprovalTransport {
    static let routingHeader = "X-Cliphoard-Entitlement"
    private let entitlementID: String
    private let beginURL: URL
    private let approveURL: URL
    private let transport: any DeviceLicenceApprovalTransport

    init(bootstrap: VerifiedDeviceLicenceBootstrap, origin: URL,
         transport: any DeviceLicenceApprovalTransport) throws {
        let origin = try Self.canonicalOrigin(origin)
        guard let begin = URL(string: "/device-licensing/v1/begin", relativeTo: origin)?.absoluteURL,
              let approve = URL(string: "/device-licensing/v1/approve", relativeTo: origin)?.absoluteURL else {
            throw DeviceLicenceApprovalClientFailure.invalidConfiguration
        }
        self.entitlementID = bootstrap.entitlementID; beginURL = begin; approveURL = approve
        self.transport = transport
    }

    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> DeviceLicenceApprovalHTTPResponse {
        if Task.isCancelled { throw DeviceLicenceApprovalClientFailure.cancelled }
        guard let url = request.url, url.baseURL == nil,
              url.absoluteString == beginURL.absoluteString || url.absoluteString == approveURL.absoluteString,
              request.httpMethod == "POST", request.httpBodyStream == nil,
              let body = request.httpBody, !body.isEmpty, body.count <= 2048,
              (1...DeviceLicenceApprovalClient.maximumResponseBytes).contains(maximumResponseBytes) else {
            throw DeviceLicenceApprovalClientFailure.invalidRequest
        }
        // No duplicate/case-variant routing value, host override or credential
        // header can reach an injected transport by bypassing its native checks.
        let forbidden = Set([Self.routingHeader.lowercased(), "host", "authorization", "proxy-authorization", "cookie"])
        guard !(request.allHTTPHeaderFields ?? [:]).keys.contains(where: { forbidden.contains($0.lowercased()) }) else {
            throw DeviceLicenceApprovalClientFailure.invalidRequest
        }
        var routed = request
        routed.httpBody = Data(Array(body))
        routed.setValue(entitlementID, forHTTPHeaderField: Self.routingHeader)
        let response: DeviceLicenceApprovalHTTPResponse
        do { response = try await transport.send(routed, maximumResponseBytes: maximumResponseBytes) }
        catch {
            if Task.isCancelled || error is CancellationError || error as? DeviceLicenceApprovalClientFailure == .cancelled {
                throw DeviceLicenceApprovalClientFailure.cancelled
            }
            if error as? DeviceLicenceApprovalClientFailure == .invalidResponse {
                throw DeviceLicenceApprovalClientFailure.invalidResponse
            }
            throw DeviceLicenceApprovalClientFailure.transportUncertain
        }
        // Cancellation cannot recall bytes already sent or roll back server work.
        if Task.isCancelled { throw DeviceLicenceApprovalClientFailure.cancelled }
        return response
    }

    static func canonicalOrigin(_ origin: URL) throws -> URL {
        guard origin.baseURL == nil,
              var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false), parts.scheme == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.path.isEmpty || parts.path == "/", parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else {
            throw DeviceLicenceApprovalClientFailure.invalidConfiguration
        }
        parts.host = host.lowercased(); parts.path = ""
        guard let value = parts.url else { throw DeviceLicenceApprovalClientFailure.invalidConfiguration }
        return value
    }
}
#endif
