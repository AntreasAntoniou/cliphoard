# Disabled Swift approval client

This adds a typed client for the existing experimental HTTP adapter. All source and tests are behind `CLIPHOARD_DEVICE_LICENSING_PROTOTYPE`. Nothing enables that flag, constructs a shipping client, changes legacy CLIP1 or StoreKit behaviour, contacts a service, or grants Pro access. The base is `a38a7c830f19ba4fcbf21251607fde99be782d3f`.

## Ownership and constructor contract

`DeviceLicenceApprovalClient.swift` owns immutable wire values, strict response parsing, canonical proof construction and the `Sendable` `DeviceLicenceApprovalServing` seam. `DeviceLicenceApprovalTransport.swift` supplies an optional, explicitly constructed native transport. The customer-flow coordinator and view are separate work and are not included here.

```swift
let client = try DeviceLicenceApprovalClient(
    origin: trustedHTTPSOrigin,
    expectedEntitlementID: locallyTrustedEntitlementID,
    transport: explicitlyInjectedTransport
)
```

The origin must be HTTPS with no credentials, query, fragment or non-root path. There is no default host. `expectedEntitlementID` is a separately supplied canonical 16-byte base64url identifier; it is never derived from the opaque purchase handle or a response. It must agree with the coordinator's independently trusted recovery bindings. This seam is not public authentication, purchase discovery, tenant resolution, rate limiting, policy admission, issuer provisioning or a customer approval UI.

```swift
protocol DeviceLicenceApprovalServing: Sendable {
    func begin(_ request: DeviceLicenceBeginRequest) async throws -> DeviceLicenceApprovalChallenge
    func prepareApproval(challenge: DeviceLicenceApprovalChallenge, token: String,
                         approvalRequestID: Data,
                         using device: any DeviceLicenceKeyProvider) async throws -> DeviceLicenceApprovalRequest
    func approve(_ request: DeviceLicenceApprovalRequest) async throws -> DeviceLicenceApprovalResult
}
protocol DeviceLicenceApprovalTransport: Sendable {
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws
        -> DeviceLicenceApprovalHTTPResponse
}
```

All request, challenge and result values are `Sendable` and `Equatable`. The transport response contains only `statusCode`, `headers` and `body`. The transport is a trusted injection: an arbitrary implementation must honour its accumulated response limit and its own liveness contract. The typed client additionally rejects an oversized returned body, but cannot stop an injected implementation from buffering excessively or ignoring cancellation internally.

## Exact wire and proof

Only two POST routes are used; there are no credential or entitlement identifiers in URL paths or queries. Requests use `application/json` and `Accept: application/json`, have no Authorization or Cookie header, and are at most 2,048 bytes. The existing JS adapter's confirmation GET is deliberately not exposed here.

| Operation | Exact request fields | Exact successful response |
| --- | --- | --- |
| `/device-licensing/v1/begin` | `entitlementHandle`, `devicePublicKey`, `requestID` | `{ok: true, challenge: {...}}` |
| `/device-licensing/v1/approve` | `challengeID`, `approvalToken`, `approvalRequestID`, `deviceSignature` | `{ok: true, code: "issued" or "already_issued", receipt: "CLIPD1.…"}` |

The challenge has exactly nine fields: `purpose`, `version`, `algorithm`, `entitlementID`, `devicePublicKey`, `deviceKeyHash`, `challengeID`, `nonce`, `expiresAt`. The client rejects any entitlement mismatch, device mismatch, inconsistent device hash, unknown field, duplicate decoded JSON key, invalid encoding, non-integral epoch or unsupported protocol value. Responses are bounded to 2,048 bytes and an exact JSON media type. The parser accepts only the ASCII JSON subset used by this protocol, with objects, strings, booleans and unsigned integers; it rejects unsupported extensions, BOM, trailing data and excessive object depth.

All binary strings are canonical, unpadded base64url: handles and approval tokens are 32 bytes, entitlement/challenge/request IDs are 16, nonce and SHA-256 digests are 32, the P-256 X9.63 public point is 65 and the raw ECDSA signature is 64. A short numeric code is not this protocol's token. Entering or pasting a token in the app remains a candidate delivery UI, not a selected public delivery format.

`prepareApproval` checks the trusted entitlement and token before reading or signing with the device. It reads the existing provider, verifies the exact device point, and signs the following UTF-8 fields joined by single LF bytes with no trailing LF:

1. `cliphoard.device-approval`
2. `1`
3. `P256-SHA256`
4. trusted entitlement ID
5. device public point, base64url
6. SHA-256 of the point, base64url
7. challenge ID
8. nonce
9. canonical integer expiry
10. SHA-256 of the **decoded 32 token bytes**, base64url
11. approval request ID, base64url

It checks the returned signature against that exact message before returning a command. It does not create a key, generate IDs, select a production clock policy, call HTTP or write storage. This matches `protocol.mjs` and the existing identity provider's approval signing domain.

## Replay, cancellation and receipt trust

Construct `DeviceLicenceBeginRequest(entitlementHandle:devicePublicKeyX963:requestID:)` once and retain it before dispatch. Construct an approval with `prepareApproval` once and retain the returned immutable `DeviceLicenceApprovalRequest` before dispatch. Both retain their exact JSON bytes. Approval also retains the exact challenge, request ID and signature, and is bound to the client origin and trusted entitlement. Keep these values private: the body contains a purchase handle or bearer approval token and must not be logged, placed in a URL or exposed through diagnostics.

The app makes no automatic new logical operation, ID change, challenge replacement, re-sign, payment or retry. Explicit retry passes the same prepared value again. A thrown error or cancellation after dispatch may follow a server commit. Preserve the exact command under that ambiguity; a timeout is not a denial or rollback. Foundation may internally retransmit identical request bytes; these tests do not establish otherwise. The protocol's durable idempotency contract, rather than an exactly-once network assumption, handles duplicate delivery.

The client validates a challenge's epoch representation but does not expire retries locally. A coordinator may check expiry before its first approval attempt; an explicit replay after expiry must still be able to retrieve an already-issued result. The coordinator must retain pending requests privately and distinguish cancellation of its own UI generation from proof that a server mutation did not happen.

`DeviceLicenceApprovalResult.envelope` is structurally checked wire data only. The client checks the expected entitlement/device binding and CLIPD1 shape, but has no issuer trust input and does not authenticate or persist a receipt. The coordinator must call the existing `DeviceLicenceRecovery.accept(_:)` using independently supplied trusted issuer, entitlement and device bindings. Only its successful signature verification, fresh local possession proof and durable storage/readback may publish an accepted licence. An `issued` response alone grants nothing. Existing offline receipts must not be revoked or replaced merely because a new activation fails.

Errors are the finite `DeviceLicenceApprovalClientFailure` cases. Raw transport errors and payloads are not exposed or logged. The server intentionally collapses multiple causes into `403 activation_rejected`; the client maps that to `activationRejected` and cannot tell the UI that a request is held for review. `transportUncertain` and `cancelled` are conservative outcome categories, not evidence of an uncommitted operation. No numeric burst threshold, fallback-key policy or production issuer is selected.

## Optional native transport

`DeviceLicenceURLSessionTransport(resourceTimeout:protocolClasses:)` requires an explicit finite positive timeout of at most 300 seconds; that constructor cap is an engineering bound, not a selected production service deadline. `protocolClasses` is a trusted local test seam and is normally omitted. Every send owns a fresh ephemeral URLSession/task. Cookie, credential and URL cache stores are explicitly nil; cookie handling and proposed cache writes are disabled. Redirects are refused. HTTP authentication challenges are cancelled without credentials. Server trust uses normal operating-system validation, with no custom acceptance or TLS bypass. No global session, proxy, network or account settings change.

The declared Content-Length and actual accumulated response body are checked; the latter remains bounded with absent or inaccurate length. A per-operation deadline covers client-side session work, including a stalled local URLProtocol, and is cancelled on completion. Caller cancellation cancels only that operation's owned task/session. Neither deadline nor cancellation bounds, rolls back or cancels pending work already executing on the server. A generic injected transport has no deadline imposed by the typed client. An injected identity provider's async read/sign work likewise has no new timeout here; cancellation is checked before and after each await, and cooperative adapter behaviour is still required.

Apple documents the configuration and redirect contracts in [URLSessionConfiguration](https://developer.apple.com/documentation/foundation/urlsessionconfiguration), [httpCookieStorage](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/httpcookiestorage), and [redirect handling](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession(_:task:willperformhttpredirection:newrequest:completionhandler:)). Ephemeral configuration alone is insufficient to disable its private in-memory cookie store, hence the explicit nil stores and disabled cookie handling.

## Evidence and limits

The candidate's `.delivery` directory preserves the initial missing-type failures, first successful client/native runs, final 21-test run, four actual Swift-to-JS protocol checks, disabled Direct and APP_STORE typechecks, runtime versions, base inventory, exact additions and their hashes. The focused fixture compiles only the unchanged `DeviceLicence.swift` plus the two new sources and tests; unchanged baseline suites were not rerun. Synthetic keys are created only in process memory. Every native request in tests is intercepted by an explicitly injected URLProtocol that accepts all URLs; no listener or provider is contacted.

The 21 tests cover strict requests/responses, trusted-scope rejection before signing, proof validation, exact replay without re-signing, error sanitization, generic denial, parser and byte limits, pre-dispatch cancellation, native cancellation and deadline, nil stores/cookie handling, and direct redirect/authentication/cache delegate decisions. The four separate interop checks import the unchanged real `protocol.mjs`, compare the exact message, verify the Swift signature, and reject a changed token or nonce. Disabled-flag typechecks establish no new symbols from these files in Direct or APP_STORE builds; they are not a shipping app rebuild.

Local URLProtocol and delegate fixtures do not establish real TLS or provider connectivity, network-stack retransmission behaviour, OS logging behaviour, Secure Enclave/Keychain availability, customer email delivery, service admission, deployment, or a successful customer purchase. No live endpoint, credentials, real hardware key, provider mutation, production route, app launch, release enablement or UI integration occurred.
