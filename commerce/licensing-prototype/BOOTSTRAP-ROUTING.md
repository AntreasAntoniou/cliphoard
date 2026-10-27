# Disabled purchaser bootstrap and public routing

This additive prototype composes the existing per-entitlement server lifecycle. It has no shipping caller, default export, listener, environment lookup, provider binding, production key, purchaser authentication or public bootstrap issuance route. Both factories require an own data property `enabled: true`; omitted, inherited or false switches remain disabled without reading dependency getters. Enabled configuration rejects accessors, inherited fields and extra fields.

## Bootstrap format and trusted issuer

`bootstrap-protocol.mjs` exports `BOOTSTRAP`, `bootstrapPayload(fields)`, `parseBootstrap(envelope)`, `verifyBootstrap(envelope, trust)` and `createDeviceBootstrapIssuer(options)`.

An envelope is `CLIPB1.<base64url(payload)>.<base64url(signature)>`, with an ECDSA P-256 SHA-256 raw 64-byte signature. The payload contains exactly these ten printable ASCII lines, separated by LF with no trailing LF:

```text
cliphoard.device-bootstrap
1
P256-SHA256
bootstrapKeyID
profileID
receiptIssuerKeyID
entitlementID
activationHandle
issuedAt
pro
```

The three key/profile IDs match `[a-z0-9][a-z0-9_-]{0,31}`. The entitlement ID is canonical base64url of 16 bytes and the activation handle of 32 bytes. `issuedAt` is a positive canonical decimal epoch no greater than the existing protocol maximum; it records provenance and adds no expiry or payment-status claim. The envelope is at most 1024 UTF-8 bytes, and its decoded payload at most 512 bytes. Padding, extra lines, alternate encodings and receipt purposes are rejected by exact reconstruction.

`bootstrapPayload` accepts exactly `{ bootstrapKeyID, profileID, receiptIssuerKeyID, entitlementID, activationHandle, issuedAt }`. `parseBootstrap` returns `{ fields, payload, signature }`; its fresh byte arrays are parsing results, not trusted configuration. Verification accepts exactly this independently configured trust object:

```js
{
  expectedProfileID,
  bootstrapKeyID,
  bootstrapPublicKey, // canonical base64url of an uncompressed 65-byte P-256 key
  receiptIssuerKeyIDs // nonempty, unique local allowlist of IDs
}
```

Verification checks purpose, profile, bootstrap key ID, allowed receipt issuer ID and signature, then returns frozen fields. The receipt issuer ID selects an already locally pinned issuer; it supplies no key. A descriptor cannot carry an endpoint, public key, device pin, local path, namespace, recipient or payment scope. Parsing and verification neither grant Pro nor create identity, traffic or saved receipts. `CLIPB1`, `CLIPD1` and `CLIP1` are not interchangeable purposes.

The trusted adapter accepts exactly:

```js
createDeviceBootstrapIssuer({
  enabled: true,
  fields: { profileID, receiptIssuerKeyID, entitlementID, activationHandle, issuedAt },
  signer: { bootstrapKeyID, bootstrapPublicKey, sign }
})
```

Construction captures the purchase fields, signer function and explicit bootstrap public key without signing. Its only method, `issue()`, accepts zero arguments. It supplies a fresh copy of the captured payload to `sign`, then verifies the returned raw 64-byte signature against that captured payload and the separately pinned key before returning an envelope. It never accepts request-selected issuance fields. The signer is a bootstrap-specific capability; actual custody and key separation must be provisioned externally. Trusted purchase creation, protected purchaser delivery, descriptor persistence/recovery and revocation/rotation policy remain separate obligations. No activation or payment authority follows from possession of a descriptor alone.

## Bound targets and a lookup-only directory

`public-router.mjs` exports two factories:

```js
const target = createDeviceLicenceRouteTarget({ enabled: true, lifecycle });
const router = createDeviceLicencePublicRouter({
  enabled: true,
  origin,                // exact canonical HTTPS origin from trusted configuration
  maxConcurrentRequests, // required positive safe integer; no production default
  lookupTarget           // async or sync: canonical entitlementID -> target or missing
});
```

`lifecycle` is the existing exact enabled server-lifecycle configuration: `{ enabled, storage, binding, inspectDeviceAuthority, issuer, tokenCustody, admission, mail, alarmStorage, clocks, limits, operational, http }`. The target factory copies the exact binding and HTTP origin before constructing that facade, whose dependency capture remains authoritative. Later configuration mutation cannot retarget the captured entitlement or origin. The target exposes only `alarm`, `recover`, `refreshAuthority` and `refreshAdmission`; its request handler and `{ entitlementID, origin }` binding remain private in a module-owned WeakMap. Arbitrary objects, proxies, inherited targets, wrong-entitlement targets and foreign-origin targets cannot supply a handler.

The directory remains an **injected production obligation**, not a provisioned global persistent registry. `lookupTarget` receives only the canonical locator string. It must retrieve an already provisioned target without allocating a ledger for arbitrary request IDs. Requests cannot choose storage, issuer, Stripe scope, email recipient or admission policy. Trusted capabilities can still perform their configured work; in-process branding does not sandbox malicious trusted code.

## Public admission and unchanged proof

Only POST `/device-licensing/v1/begin` and `/device-licensing/v1/approve` use `X-Cliphoard-Entitlement`. Each needs exactly one canonical 16-byte base64url ID. The existing JSON bodies remain exact and unchanged:

```js
// begin
{ entitlementHandle, devicePublicKey, requestID }
// approve
{ challengeID, approvalToken, approvalRequestID, deviceSignature }
```

The header is a routing locator. Begin still binds the activation handle to trusted purchase authority; approve still binds its stored challenge and device proof to the entitlement. Even an identical challenge ID in another ledger cannot move a valid proof. No global challenge index is needed. Exact issued retries and the existing freshness, reservation and runner fences remain those of the captured lifecycle.

The router rejects invalid paths, methods, origin/Fetch Metadata, query/fragment, headers, media type, declared lengths, absent or already consumed/locked body, and prior abort before directory access where those facts are locally knowable. Streamed JSON parsing remains the existing facade's separately bounded work; malformed JSON need not be pre-read before lookup. Duplicate WHATWG header values combine with a comma and fail canonical decoding. A production ingress must preserve/reject duplicates and raw request-target ambiguities before WHATWG normalization; these in-process tests do not prove wire ingress behavior.

Generic GET/HEAD `/device-licensing/v1/confirmation` returns an inert confirmation instruction without a locator, directory access or customer-state lookup. Invalid routes and errors use fixed sanitized responses with `no-store` and `no-referrer`; no request logging or permissive CORS is added.

`maxConcurrentRequests` bounds requests in asynchronous directory/facade work. It is neither a request rate limit nor a device/activation policy. There is no production numeric default. A slot stays held until the awaited lookup or facade command actually settles, including after caller abort. A permanently unsettled trusted call can therefore exhaust this finite capacity. There is no router timeout or inferred cancellation of a committed command. Existing body byte/deadline limits separately bound body parsing; completion of parsing does not bound awaited provider/issuer/storage calls. An abort after command dispatch does not prove rollback.

## Focused evidence and remaining gates

The focused tests use synthetic ephemeral P-256 keys, fake mail, explicit test-only limits, temporary SQLite WAL/FULL databases and an explicitly fake in-memory token-custody map. They compose two actual existing server lifecycles. Wrong-ledger approval is tested with forced identical challenge ID, token, nonce, device key and time, leaving the entitlement binding as the distinguishing signed value. Other cases cover immutable capture, forged/mismatched directory targets, exact retries, unknown pins/purposes, malformed canonical fields, disabled getters, finite capacity and cancellation while trusted work is pending.

The initial new-suite run passed 20 of 21 cases; one absent-capacity test accidentally invoked a test helper's default. The corrected fixture passed separately. New regressions exposed origin coercion and empty-body preflight lookup; their RED snapshots/logs and affected GREEN reruns are retained in the release evidence. There are 22 distinct test cases with passing observations across those runs, not a claim that the complete final suite was rerun together. No previously passing legacy suite was rerun.

These are local Node/SQLite observations and static additive-scope checks. They do not demonstrate deployed HTTP ingress, live provider freshness, mail delivery, secure bootstrap delivery, production custody/directory provisioning, hardware identity, shipping integration or Swift interoperability. Independent review and cross-language tests remain separate acceptance work. No package, route configuration, policy default or shipping source is changed by this slice.
