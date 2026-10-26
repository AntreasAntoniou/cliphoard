# Device licence prototype — disabled, local only

Owner-selected policy, recorded 26 October 2026: one purchaser may use Pro on their personally owned Macs; each new device needs email approval; there is no fixed device cap. An approved device receipt remains valid offline indefinitely. Abnormal activation bursts may pause **new** approvals for review. Already approved receipts and old `CLIP1-` licences keep their existing offline behaviour. The Mac App Store edition remains a separate StoreKit entitlement path.

This directory implements a **local prototype**, not released enforcement. No deployed Worker imports it. New Swift code and tests compile only with `CLIPHOARD_DEVICE_LICENSING_PROTOTYPE`; the shipping build does not set that flag. No app entry, settings, defaults, existing licence, StoreKit, package manifest, Worker route, production signing key, key store or mailer is changed. There is no production trust key or default authority adapter.

## What runs

- `protocol.mjs`: strict canonical receipt/challenge codecs, P-256 signatures, token hashing and offline possession verification using standard Web Crypto.
- `activation-state.mjs`: pure, deterministic approval reducer. It consumes facts verified by the adapter, not Boolean fields accepted from a caller.
- `in-memory-service.mjs`: serializes synthetic requests, resolves authoritative entitlement through required injected adapters, sends an approval through a required injected outbox seam, and issues only after email-token **and** device-key proof. It is not an HTTP server or a Cloudflare Worker export.
- `DeviceLicence.swift`: actual CryptoKit receipt verifier plus an asynchronous local key-provider interface. The only successful verification path asks the provider to sign a newly generated receipt-bound nonce.
- `DeviceLicenceActivation.swift`: pure client state reducer; activation outages, rejected replacement receipts, holds and stale responses preserve an already verified receipt.

All test keys are generated in memory. Tests never serialize a private key, load a real licence, contact a payment provider or send email. Swift/JavaScript interop passes only public keys, signatures and synthetic protocol data through pipes.

## Cryptography and trust

Version 1 uses exactly **ECDSA P-256 with SHA-256** for issuer signatures and device possession. It does not negotiate algorithms. Public keys use the canonical 65-byte SEC1 uncompressed point (`04 || X[32] || Y[32]`), validated by CryptoKit/Web Crypto and round-tripped before use. The device binding is the base64url SHA-256 digest of those exact 65 bytes. Signatures use 64-byte IEEE P1363 `r[32] || s[32]`, not DER. Base64url is unpadded; decoding must round-trip byte-for-byte, rejecting padding, whitespace and alternate unused-bit encodings.

The issuer key ID selects an explicitly injected **new** trusted P-256 public key. It never selects or derives the existing `CLIP1-` Ed25519 key. Signature inputs contain their own purpose and version; changing only an outer prefix cannot change what was signed. Tests relabel a valid new envelope as `CLIP1-` and send it to the actual legacy verifier, which rejects it. The existing verifier and `v >= 1` behaviour are unmodified.

The same signature may have mathematically equivalent ECDSA representations. Receipt identity and approval idempotency use signed IDs and validated command identity, not signature-string uniqueness. This protocol does not depend on signature uniqueness or on JS timing guarantees.

Primary sources consulted:

- [Apple P-256 public-key and signature APIs](https://developer.apple.com/documentation/cryptokit/p256/signing/publickey)
- [Apple raw ECDSA signature initializer](https://developer.apple.com/documentation/cryptokit/p256/signing/ecdsasignature/init(rawrepresentation:))
- [Cloudflare Workers Web Crypto support](https://developers.cloudflare.com/workers/runtime-apis/web-crypto/)
- [Web Cryptography specification, ECDSA](https://www.w3.org/TR/WebCryptoAPI/#ecdsa-operations)

SOFA was considered for the interop choice. Its authenticated tools were not exposed to this worker; no credential was accessed and no anonymous API request or contribution was made. Primary documentation and local interop tests supply the evidence here.

## Receipt wire format

`CLIPD1.<base64url(payload)>.<base64url(signature)>`

The signed payload is ASCII, exactly ten LF-separated lines, **without** a trailing LF:

```text
cliphoard.device-receipt
1
P256-SHA256
<issuer-key-id>
<entitlement-id>
<device-key-sha256>
<receipt-id>
<issued-at>
pro
perpetual
```

- `issuer-key-id`: `[a-z0-9][a-z0-9_-]{0,31}`; only a caller-supplied trusted key with that exact ID is accepted.
- `entitlement-id`, `receipt-id`: canonical base64url of 16 random opaque bytes. Neither an email address nor the legacy purchase token belongs here.
- `device-key-sha256`: canonical base64url of 32 bytes.
- `issued-at`: canonical positive decimal epoch seconds, at most `253402300799`; no leading zero, sign, fractional value or exponent.
- Maximum encoded envelope: 1024 ASCII bytes. Maximum decoded payload: 512 bytes. Signature: exactly 64 bytes.
- Exact version, algorithm, purpose, `pro` and `perpetual` fields are mandatory. Unknown fields, future versions and alternate formats fail closed.

There is no expiration, lease renewal, periodic connection or revocation query. `issued-at` is provenance rather than an expiry mechanism. Future versions need an explicitly reviewed parser and trust path.

## Offline local proof

After authenticating the receipt, the client asynchronously asks its local key provider for the public key, verifies the receipt's device hash, generates a fresh 32-byte random nonce **inside the verifier**, and asks that provider to sign these ASCII lines:

```text
cliphoard.device-local-proof
1
<base64url(SHA256(receipt-payload-bytes))>
<base64url(fresh-32-byte-nonce)>
```

The verifier checks the returned 64-byte signature with the same local public key before returning `DeviceLicenceReceipt`. Supplying the receipt's public key, copying only a receipt, or replaying an old proof is insufficient. No successful receipt is returned on malformed key, wrong signer, unavailable key provider or bad proof. No network, filesystem or key-store API appears in the verifier.

**This binds to key possession, not proven physical hardware ownership.** A copied software private key plus its receipt still works. The tests intentionally use memory-only keys. Secure Enclave, Keychain persistence, hardware attestation, anti-cloning and nonexportability are not implemented or claimed. Neither software nor hardware proof establishes whether a Mac is personally owned. Open-source clients can be patched to bypass checks.

## Activation transaction

1. A future UI explicitly starts activation. The prototype accepts only a `POST` command with a bounded canonical purchase handle, device public key and 16-byte client request ID. It never trusts a caller-supplied email, entitlement object or “proof verified” flag.
2. `resolveEntitlement(handle)` must verify the direct-purchase entitlement and purchaser address using authoritative commerce records. The prototype checks `product = pro`, `status = active`, ID and revision, and canonicalizes the device public key. Refunded, disputed, unknown or unavailable entitlement state cannot start activation.
3. The required private `admission` hook can return `allow` or hold. No threshold is selected in code. It receives only phase, opaque entitlement ID, device-key hash and timestamp, never the purchase handle, email, challenge nonce or approval token.
4. Create a 16-byte challenge ID, 32-byte nonce and 32-byte approval token. Store the token **hash**, bound entitlement ID/revision, canonical device public key/hash, creation and expiry timestamps. The synthetic TTL is configured explicitly (tests use ten minutes; supported prototype range is 1–1800 seconds).
5. The outbox seam receives the one-time token and the **verified purchaser's** address. The begin response contains only the public challenge; the token is never returned there. There is no real email adapter.
6. An email link's `GET` or `HEAD` only renders a generic confirmation-required response; it does not consume, approve, sign or mutate state. A future email/browser flow must display context and require an explicit user action. The intended handoff is a code returned to the original requesting Mac, where the device key exists. No browser token handoff, deep link or confirmation UI is implemented here.
7. The Mac supplies the token, a new 16-byte approval request ID, and a device signature over the exact approval message below. A `POST` is mandatory. The token hash and signature must both verify against the stored challenge. Another device, challenge, entitlement, nonce, expiry, token or approval request ID fails.
8. Re-read authoritative entitlement status/revision and admission before issuing. Re-read again after asynchronous signing and immediately before commit. Expiry is exclusive (`now >= expiresAt` rejects); backward time also rejects a pending challenge. The candidate receipt must verify against the injected issuer and exactly match the intended payload.
9. Atomically consume the challenge and save the receipt. The in-memory adapter serializes this sequence within **one instance**. A same-ID, same-device retry can recover the exact issued receipt without signing again; a new approval request ID against the consumed challenge is rejected. Pending approval after refund, dispute or entitlement revision change is rejected. An existing offline receipt is unaffected.

A public challenge has exactly `purpose`, `version`, `algorithm`, `entitlementID`, `devicePublicKey`, `deviceKeyHash`, `challengeID`, `nonce`, `expiresAt`. The signed approval message has exactly these LF-separated ASCII lines, without trailing LF:

```text
cliphoard.device-approval
1
P256-SHA256
<entitlement-id>
<canonical-device-public-key-base64url>
<device-key-sha256>
<challenge-id>
<challenge-nonce>
<expires-at>
<base64url(SHA256(decoded-approval-token))>
<approval-request-id>
```

Idempotency keys are scoped to entitlement ID. Reusing a begin ID with another public key conflicts. A duplicate begin does not rotate the token or send another email. A duplicate successful approval returns its original receipt, even if the delivery retry is later than the challenge expiry; it cannot create another activation, still needs the same token/device proof and active current entitlement, and does not grant on a different approval request ID. New approvals may be held while retrieval of an already issued receipt remains possible.

## Failure and recovery limits

- A service or network outage does not invalidate a saved approved receipt. Client state leaves it intact while a new activation is pending, held or rejected. A replacement is installed only after successful local receipt verification for the current request; stale responses are ignored.
- Losing the private key means the corresponding receipt cannot prove possession. Recovery requires a fresh key and email approval on that Mac; it must never silently copy another device's key. No fixed cap should prevent legitimate recovery. Purchaser email loss or suspicious recovery needs an explicit support process, still to be designed.
- A key store that cannot respond must not freeze main-thread startup or erase a saved receipt. The async provider boundary is present, but production timeout/cancellation, user-authentication prompts and recovery UX are not. The client reducer retains the last verified result; a restarted process still needs local possession.
- If synthetic delivery throws, the prototype reports `delivery_unavailable`; it does not claim email was sent. A retry of the same begin ID does not resend. A new request is required. A transactional durable outbox with deduplicated resend and expiry is required before a real service can ship.
- Memory state disappears on process exit and is not coordinated across instances. The local promise queue is **not distributed locking**. Pending state/idempotency are unbounded in this experiment. Durable storage must enforce atomic challenge consumption, request uniqueness, entitlement revision checks, retained issued receipts, retention and resource controls, and safe multi-region/multi-isolate behaviour.
- Refund state can race external payment-provider events. A real service needs an authoritative, versioned entitlement ledger plus reconciliation and transactional issuance; these injected test seams do not make a provider read globally atomic.
- The receipt is public signed data. Email codes, purchase handles and challenges are sensitive. No logging or analytics hooks are implemented. A future HTTP/email adapter must scrub them from URLs, access logs, traces and analytics, use TLS, `Cache-Control: no-store`, restrictive referrer policy, origin/CSRF checks, request size limits, generic errors where appropriate and rate limits. Avoid approval tokens in query strings; a fragment/code handoff requires its own review.
- Permanent offline receipts cannot be revoked after a later refund or signer compromise while preserving the stated permanent-offline promise. Hold new issuance instead; never claim retrospective control. Key rotation must retain verification of previously approved receipts under the selected policy.

## Unselected controls and next integration step

Burst thresholds remain tuning decisions. “Five activations per day / ten per week before a review hold” was a proposal, **not an adopted limit or a device cap**. Production must define hold/review/release semantics, request and email abuse controls, privacy-preserving retention, support recovery and issuer rotation.

The next implementation slice should remain disabled: add a durable per-entitlement transaction/outbox adapter, a verified existing-commerce entitlement adapter and synthetic integration tests that restart the service and race refund events; separately implement an async macOS key-store provider with documented Secure Enclave availability and software-key fallback policy. Then review email confirmation/recovery UX and crash-safe receipt persistence. Shipping requires explicit integration of the new trust key and policy, security review, compatibility/recovery tests, and revised public claims before enabling any app or service path. None of those production steps happened here.

## Local checks

From the repository root:

```sh
swift test --jobs 2 -Xswiftc -DCLIPHOARD_DEVICE_LICENSING_PROTOTYPE --filter DeviceLicence
node --test --test-concurrency=1 commerce/licensing-prototype/test/*.test.mjs
```

The Swift test filter avoids unrelated tests that read maintainer licence files or user defaults. The Node suite runs real cryptography, service/state negatives, concurrent requests, and a compiled Swift harness against the unchanged actual verifier source. The harness generates the device key in its own process, signs the approval for the JS service, receives the service receipt, and proves fresh local possession. The standard commerce test command does not enable this directory. Runtime test dependencies use the existing locked commerce development dependencies; no new package dependency is selected.

The runtime harness under `test/` is used only by Miniflare. It generates its own ephemeral signer/device inside workerd, checks a Node-generated receipt, completes synthetic activation and local possession, checks scanner/replay/refund behaviour, and returns public results for Node verification. It has no Wrangler binding or deployment configuration.
