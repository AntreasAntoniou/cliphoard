# Disabled SQLite approval and delivery candidate

This is a local persistence slice of the exact `CLIPD1` protocol in [PROTOCOL.md](PROTOCOL.md). It has no production Worker export, route, deployment configuration, binding, signer, mailer, scheduler or app integration. The only Worker entry point is under `test/`, and no deployment manifest imports it. Existing `CLIP1` licences and StoreKit are untouched.

The selected policy remains one purchaser's personally owned Macs, email approval for each new device, no fixed device cap, and indefinite offline use of an approved receipt. Abnormal bursts can hold new approvals through the required admission hook. No numeric burst threshold or device-key fallback policy is selected here.

## Storage and authority boundary

`createSqliteActivationService` accepts the SQLite-backed Durable Object storage interface: `sql.exec`, `transactionSync`, and `sync`. R2 pins one entitlement ID and schema version 2 per database; the unreleased R1 schema is rejected, with no automatic migration. A future commerce adapter must route **all** approval operations and verified entitlement revisions/refunds for that entitlement into that same object. It must authenticate provider events, derive eligibility and purchaser email, and advance the revision when eligibility or purchaser identity changes. No API accepts a client-supplied eligible boolean or email address.

`observeEntitlement` is a trusted internal feed, not a public endpoint. Lower revisions cannot replace newer state. At equal revisions an ineligible observation defeats a stale active observation. Only a higher authoritative revision can supersede that fence. An existing challenge remains bound to its original revision, so even a later active revision cannot approve it. Provider outages fail closed for new approval/delivery; they do not affect previously issued offline receipts.

Admission has its own monotonic revision in the same ledger. The required admission hook returns exactly `{ revision, decision: 'allow' | 'hold' }`; a bare boolean/string is rejected. The trusted `observeAdmission({ entitlementID, revision, decision })` feed records asynchronous hold/release observations. Unknown state fails closed; a hold wins equal-revision conflicts; an older allow cannot erase it. Both begin and approval commit transactions read this persisted decision and require the exact revision admitted before asynchronous work. A hold observed while sealing, signing or refreshing therefore blocks the new commit. An explicit higher allow can release a hold, but older in-flight decisions must retry. The signing intent does not pin admission revision, so retrying the original approval request under the new allow reuses its original receipt fields. No numeric threshold is implied. A remote hold that has not reached this ledger is not instantly enforced. Issued-receipt retrieval/delivery bypass admission, including an admission outage; their entitlement/refund checks remain.

The database contains four tables:

| Table | Durable contents |
| --- | --- |
| `device_licence_meta` | Exact schema, entitlement scope, latest eligibility revision/status, separate admission revision/decision |
| `device_licence_challenges` | Unique begin request ID, canonical device/challenge, token hash, expiry, signing intent, committed receipt and approval request ID |
| `device_licence_outbox` | Stable challenge/kind delivery ID, status, sealed approval token, current lease and attempt count |
| `device_licence_delivery_attempts` | Each lease ID, start/finish times and fixed outcome; prior uncertain attempts survive later successful retries |

No purchaser email, purchase handle, private signing/device/sealing key, or plaintext email token is stored. Approval-token sealing/opening are required injected authenticated-encryption operations, bound to the protocol purpose, entitlement, revision, challenge and token hash. The factory cannot establish that an arbitrary injected sealer is secure; there is no production sealer or plaintext fallback. Tests use newly generated nonextractable AES-GCM keys held only in memory. A real durable key-management/rotation/recovery adapter remains required.

## Transaction and crash boundaries

`begin` commits challenge and approval-email outbox together. Duplicate requests return the original challenge without token rotation or a second outbox entry; a different device with that request ID is rejected. `begin` means queued, not emailed. GET/HEAD preview changes nothing and cannot approve.

Approval requires the same canonical device proof and token binding as the original adapter. A transaction reserves a stable signing intent (receipt fields and approval request ID) before asynchronous signing. The canonical expected payload is captured before calling the signer with a separate fields copy; a valid signature over mutated fields is rejected. The signer output is verified against the pinned public issuer and that expected payload. A second transaction rechecks current entitlement revision, expiry and the persisted admission decision/revision, then commits the issued receipt and receipt-delivery outbox together. No receipt is returned before the storage durability barrier. A conflicting approval request cannot replace an in-progress intent; retry the original request or start a fresh challenge after expiry.

Once committed, the exact envelope is reused after restart, after challenge expiry, and during delivery retries. A refund blocks online retrieval/undelivered mail, but cannot revoke an offline receipt already released. An uncommitted signature is never released. A crash between signing and commit may repeat the signing call with the **same persisted receipt ID and payload**; randomized signatures may differ. Separate concurrent adapter instances can also sign that intent more than once, but the commit transaction selects one envelope. This is one committed receipt, not an exactly-once signer guarantee. The normal single-object adapter serializes approval calls in memory as well.

`deliverOne` claims at most one due row and persists the lease before external effects. It checks authoritative eligibility/revision before claiming and again after token decryption, immediately before dispatch; the final transaction also checks the current lease and challenge. Refund/revision observations cancel pending/leased rows and clear retained ciphertext. Expired approval mail is cancelled. Receipt mail reuses the committed receipt and does not call the signer.

An external sender must return `{ accepted: true }` only for confirmed provider acceptance. Acceptance is not inbox delivery. A throw or unconfirmed result after dispatch is uncertain, remains leased until expiry, and is retained in the attempt ledger. Recovery may send the identical token/receipt and stable delivery ID twice. Use that ID with a provider's idempotency API if available. A refund during an in-flight send cannot retract it; a late acceptance is recorded as accepted after cancellation, without reopening the outbox. Old acknowledgements cannot overwrite a newer lease. No exactly-once email guarantee is claimed.

## Local evidence and remaining integration

Run from the repository root with Node supporting `node:sqlite` (verified here with Node 24.11.0):

```sh
node --test --test-concurrency=1 commerce/licensing-prototype/test/sqlite-service.test.mjs commerce/licensing-prototype/test/sqlite-workerd.test.mjs
```

The runtime test uses the repository's already-pinned Miniflare dependency. When reusing another isolated checkout's installed dependencies, explicitly set `CLIPHOARD_TEST_DEPENDENCIES` to that checkout's absolute `commerce/package.json`; no installation or provider connection is performed by the test. Twenty on-disk SQLite tests exercise reopen/restart, independent connections, proof rejection, refund/revision and admission interleavings, signer-input mutation, rollback, encrypted-token binding, lease fencing and uncertain retries. One real local workerd SQLite test checks rollback, duplicate approval, runtime disposal/restart and receipt retry with the signer unavailable. Keys are synthetic/in-memory; temporary databases are removed by their owning tests.

The next integration step is a separately reviewed disabled per-entitlement Durable Object wrapper with verified commerce and admission revision feeds, durable encryption-key recovery, issuer-key management, mail acceptance adapter and scheduled outbox recovery. No such component is provided here. Storage retention, indexing/pagination for large ledgers, backup/restore reconciliation, clock handling, bounded retry/backoff and abuse admission need production design. Restoring stale database state is not proven safe against replay or hold bypass; reconcile authoritative eligibility/admission state before reopening issuance. A local provider read cannot atomically observe a refund/hold that has not reached this ledger or retract an already-dispatched message. A production adapter must document that residual boundary.

`snapshot()` exposes only fixed numeric counters. Do not add entitlement/device IDs, licence strings, tokens, email addresses, purchase handles or outbox contents to analytics or error logs. Admission callbacks receive private identifiers for decisions; they are not analytics. Device Secure Enclave/Keychain persistence, anti-cloning enforcement and startup/UI integration remain outside this slice.

The synchronous transaction and cursor behavior follows [Cloudflare's SQLite storage API](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/): callbacks contain only synchronous storage operations, thrown errors roll back, and query results are consumed before awaits. Explicit durability barriers precede released results and dispatch. The local test shim uses [Node's SQLite API](https://nodejs.org/api/sqlite.html) with real on-disk SQLite, `BEGIN IMMEDIATE`, WAL and `synchronous=FULL`. SOFA's authenticated tools were unavailable in this session; no credential lookup or anonymous API fallback was attempted.
