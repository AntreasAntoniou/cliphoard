# Disabled native purchaser bootstrap

These three additive Swift components compile only under
`CLIPHOARD_DEVICE_LICENSING_PROTOTYPE && !APP_STORE`. They add no shipping caller,
embedded real trust key, account selection, build flag, persistence or endpoint.

## Authenticated setup is separate from approval

`DeviceLicenceBootstrapTrustProfile` receives a local profile ID, one pinned
bootstrap key ID/public P-256 point, and the locally permitted receipt issuer
IDs/public points. It validates and copies these values, including detaching
mutable `NSData` bridges. A caller cannot mutate a captured pin afterward.

`DeviceLicenceBootstrapVerifier.verify(_:profile:)` verifies the exact CLIPB1
wire contract against that profile. It returns `VerifiedDeviceLicenceBootstrap`,
whose initializer is file-private to the verifier source. It never accepts a
public key, origin, path, device pin, recipient or policy from descriptor data.
Only a locally permitted receipt issuer can be selected. The verifier checks
canonical base64url, exact field count, printable ASCII, fixed purpose/version/
algorithm/tier, bounded sizes, canonical IDs/epoch and the raw P-256 signature.

Its synchronous verification reads no clock, device or account and creates no
identity, directory, receipt, application session or traffic. `issuedAt` records
provenance, with no expiry rule. A bootstrap does not publish Pro. CLIPB1,
CLIPD1 receipts and legacy CLIP1 keys remain separate domains. Cancellation before
or after signature verification returns no verified value. This is a cancellation
check around bounded local work, not preemption of a cryptographic call.

The returned activation handle remains sensitive. Its descriptions are fixed and
value-free; callers must not log, display in telemetry or put its fields in URLs.
No claim of physical memory zeroization or protection against arbitrary in-process
memory inspection is made. Bootstrap storage, secure delivery, recovery and an
account-switch protocol remain unimplemented.

## Locator-only transport

`DeviceLicenceBootstrapRoutingTransport(bootstrap:origin:transport:)` captures a
verified descriptor and a separately trusted fixed HTTPS origin. Construction is
inert. It forwards only exact absolute POST URLs for the existing `begin` and
`approve` paths, with bounded nonempty buffered bodies and response-limit inputs.
It rejects query/fragment, relative or alternate-origin/port/path representations,
an existing routing header case-insensitively, a Host override, credential/cookie
headers and body streams. It adds exactly `X-Cliphoard-Entitlement`, using the
verified entitlement ID, and copies the body byte-for-byte without reserialization.
The activation handle remains only in the existing begin body. Approval proof
bytes and request IDs are unchanged, so explicit retries retain their identity.

Foundation normalizes a standard method assigned as `post` to the stored value
`POST` before this wrapper sees it. The wrapper checks that actual stored method;
it cannot recover the setter's spelling. The initial test assumption and its
two failed assertions are preserved in author evidence. Only the affected test
and a new normalization observation were rerun after correcting the fixture.

This is a locator, not authorization: the server must still check the activation
handle, email challenge, device proof, payment/admission state and ledger binding.
The wrapper adds no retries or queue. It awaits the underlying send, fences a late
response after cancellation, and maps dependency failures to fixed client errors.
Cancellation cannot recall an entered send or roll back server work. The existing
native transport supplies finite resource/response bounds, normal TLS, no redirects
or authentication challenges. Injected transports must uphold their existing
bounded-response contract. This slice does not separately qualify live TLS,
Foundation retransmission, proxy logs or provider behavior.

## Inert application assembly

`DeviceLicenceBootstrapApplicationConfiguration` accepts only a verified bootstrap
plus explicit local origin, device pin, receipt path, Keychain scope and timeout.
Those local values remain independent of the descriptor. Its validation-only
constructors do not access filesystem/Keychain or start a URL session.

`DeviceLicenceBootstrapApplication.makeSession(...)` accepts injected identity,
transport and file-I/O capabilities and constructs the existing session with the
routing wrapper. `.native(configuration:)` constructs the existing lazy native
adapters. Both return a new idle session; neither starts it or replaces/mutates an
existing session. Opening a panel remains inert. Explicit startup can restore only
an existing identity locally, and explicit first approval remains the only path
that may create a device identity. Only the existing verified saved receipt path
can publish Pro.

The focused author tests use memory-only synthetic P-256 keys, fake identity and
HTTP adapters, and newly created private temporary directories. They demonstrate
inert factories, cancellation, closed trust selection, mutable-pin isolation,
canonical/signature rejection, route/body preservation, and a first explicit
request carrying the verified locator and handle. They do not demonstrate actual
Keychain/Secure Enclave operations, a real approval email, HTTP/TLS, an app process
restart, production directory provisioning, bootstrap durability or shipping Pro.
