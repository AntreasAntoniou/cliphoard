# Disabled activation HTTP boundary

This adds a WHATWG `Request`/`Response` adapter around one trusted, already-scoped activation service. It is default off and has no production import, Worker export, listener, deployment binding, provider client, mail sender or background scheduler. The three new files are `http-adapter.mjs`, `test/http-adapter.test.mjs` and this handoff. Existing protocol, SQLite ledger, app, StoreKit and legacy CLIP1 files remain unchanged. This slice does not overlap the separate Mac receipt-persistence work.

## Constructor and scope

```js
const handle = createActivationHttpHandler({
  enabled: true, // Only literal true in trusted construction opts in; default false.
  service,      // The existing createSqliteActivationService(...) instance.
  entitlementID, // Same canonical 16-byte ID as that instance; never request input.
  origin: 'https://licensing.example.invalid', // Explicit canonical HTTPS origin.
  bodyTimeoutMs: 1000, // Example only: the integrating host must explicitly choose it.
});
const response = await handle(request);
```

Disabled construction requires no service or valid configuration. Every request then returns a fixed 404 without reading its body or invoking a service method. Request data cannot enable the adapter. Importing this module constructs no service and starts no timer.

Enabled construction requires a canonical HTTPS origin without path, user information, query or fragment; a canonical entitlement ID; existing `begin` and `approve` functions; and an integer parsing deadline from 1 to 30,000 milliseconds. It captures those two methods bound to that service. Changing a method property afterward cannot switch the captured capability. It never derives a service, looks up a tenant, or accepts an entitlement object, purchaser email, eligibility flag or proof-verification flag from a request. The constructor ID provides an output consistency check; it cannot turn an untrusted injected service into an authority.

The real SQLite service already enforces its constructor-bound entitlement, verified commerce and admission revisions, device proof, stable receipt intent and durable commit. This adapter uses its existing input/output shape. It does not instantiate that service or provide any of its required authority, signer, sealer or delivery dependencies. The public edge's trusted mapping to the correct per-entitlement instance remains an unimplemented integration boundary.

## Exact routes and data

The request URL must have the constructor's origin. Queries and fragments are refused, even an empty `?`. Route matching uses the exact pathname exposed by WHATWG `Request`/`URL`; an upstream platform may already have normalized the original raw request target. No customer identifier, handle, token or receipt belongs in the URL. This adapter emits no logs and cannot scrub an upstream proxy's access logs.

| Route | Methods | Body / result |
| --- | --- | --- |
| `/device-licensing/v1/begin` | POST | Exactly `entitlementHandle`, `devicePublicKey`, `requestID`; returns `{ok:true, challenge}`. |
| `/device-licensing/v1/approve` | POST | Exactly `challengeID`, `approvalToken`, `approvalRequestID`, `deviceSignature`; returns `{ok:true, code:'issued'|'already_issued', receipt}`. |
| `/device-licensing/v1/confirmation` | GET, HEAD | Fixed `confirmation_required`, with no service call or challenge lookup; HEAD has no body. |

The adapter supplies `method: 'POST'` to the existing mutation methods itself. No route exposes `observeEntitlement`, `observeAdmission`, `deliverOne`, `snapshot` or any dynamic method name. OPTIONS is rejected, and GET/HEAD never call an approval or begin mutation. Confirmation is a generic read, not email consent, token consumption, or a browser-to-Mac handoff.

POST requires `application/json`, optionally `charset=utf-8`, and no content encoding other than explicit `identity`. The body is limited to 2,048 actual streamed bytes before parsing. A supplied Content-Length must be a canonical safe integer, be within the cap, and match the bytes read. It is never trusted to bypass streaming bounds. Missing Content-Length is supported. Empty/non-byte stream chunks are rejected to prevent unbounded microtask read loops. Invalid UTF-8, BOM, nested/non-string JSON, extra/missing keys and duplicate decoded keys (including escaped aliases) are rejected. Canonical protocol lengths/encodings and the begin request's actual P-256 public point are checked before calling the service.

A request-local timer bounds **only body reading**, including a stream that never yields. The timer and abort listener are removed on every owned-reader exit; overflow, abort and error paths attempt cancellation and release the reader without awaiting an underlying cancellation promise that may never settle. Caller abort is rechecked before service dispatch. This is cooperative asynchronous control, not preemption of a synchronously blocked JavaScript runtime.

The deadline does **not** bound crypto work or a dispatched service call. The service API has no cancellation/rollback signal. Once dispatched, the adapter waits for its result, even if the caller disconnects. No claim that an HTTP timeout or failed response means “nothing committed” is valid: retry the same operation IDs/proof through the existing idempotency contract. There is no new service timeout, automatic retry, outbox wake-up or background timer.

## Response and exposure limits

Every response uses fixed JSON/error shapes and `Cache-Control: no-store`, `Pragma: no-cache`, `Referrer-Policy: no-referrer`, `X-Content-Type-Options: nosniff`, `Cross-Origin-Resource-Policy: same-origin` and a restrictive CSP. No CORS grant, credentials allowance, cookie or reflected Origin is emitted. If an Origin is supplied, it must equal the configured origin; cross-site/same-site Fetch Metadata is refused. Native requests without Origin remain supported. These checks are not public authentication, rate limiting, a complete CSRF/customer-consent UI, or proof that an ingress provides TLS.

Known proof/entitlement/idempotency/admission rejections collapse to a fixed 403 `activation_rejected`. Unknown dependency errors and malformed dependency outputs become fixed 503 `temporarily_unavailable`. Exception messages, properties, request bodies and arbitrary dependency objects are never serialized. Malformed transport requests receive fixed 400/408/413/415 responses; exact routes have fixed 405 Allow values.

Successful service results must have exactly the expected fields. Challenges are copied into a new object and checked against the constructor entitlement plus the request's device key/hash. Receipts are structurally parsed, checked against the constructor entitlement, and returned byte-for-byte. The adapter does not independently verify the issuer signature or device proof; the real SQLite service already performs those checks. Tests use injected fake service responses and do not establish that an arbitrary injected service is safe. A begin result means the service accepted/queued its challenge; it does not mean email was sent. An issued receipt does not prove inbox delivery.

## Focused evidence and remaining work

Run only this new suite with the verified Node runtime:

```sh
/usr/local/bin/node --test --test-concurrency=1 commerce/licensing-prototype/test/http-adapter.test.mjs
```

The suite uses actual Request/Response and ReadableStream objects, fake service capabilities, and fresh synthetic cryptographic material held only in memory. It covers off mode, exact routing/schema, duplicate keys, absent/lying length, streaming limits, stall/abort/cancel cleanup, trusted scoping, output filtering, error redaction and unchanged issued-receipt delivery. It deliberately uses a fake approval service: accepting a request in these tests is transport evidence, not cryptographic approval evidence.

No baseline suite, real server listener, workerd HTTP runtime, provider, live key, mail delivery or browser flow was exercised. Production entitlement routing/authentication, verified revision feeds, issuer/sealer recovery, traffic admission/rate limits, durable mail scheduling, confirmation/recovery UX and safe access-log configuration remain separate work. No numeric burst threshold, device-key fallback policy or shipping enablement is selected here. Existing offline receipts and legacy/StoreKit behavior are unaffected.
