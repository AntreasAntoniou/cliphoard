# Durable, disabled bootstrap issuance

`bootstrap-service.mjs` adds a per-entitlement SQLite issuance and delivery seam.
`bootstrap-mail.mjs` adds a separately injected, bootstrap-only sender boundary.
Both factories require an own-data `enabled: true`; their disabled forms perform
no storage, signer, custody, inspector, alarm or sender work. There are no keys,
providers, environment defaults, HTTP endpoints, deployment bindings or shipping
wiring in these modules.

## Trusted allocation contract

A directory reserves this exact immutable object before calling the target:

```js
{
  entitlementID, // canonical base64url, 16 bytes
  provisioningID, // canonical base64url, 16 bytes
  scope: {
    accountId, mode, orderRef, sessionId, productId, priceId,
    currency, unitAmount, taxBehavior
  }
}
```

The target's trusted adapter captures that reservation and its own profile and
key selection, constructs the service, and invokes `service.provision()`.
Provision returns exactly `{ entitlementID, provisioningID, bindingDigest }`
after durable allocation and authority initialization. The digest binds the
complete reservation, key/profile selection, custody key ID, generated handle
digest and fixed issuance time. Matching retries return the same acknowledgment;
changed reservations, profile pins or custody IDs fail closed. The raw activation
handle is generated inside the target and is never returned to the directory.

Directory readiness proves durable target initialization. It does not prove
payment, descriptor issuance, sender acceptance, inbox delivery or activation.
Directory and target initialization form an idempotent saga, without a shared
transaction. The directory must retain and retry the original reservation after
an uncertain RPC result. Public headers and descriptors cannot reserve targets.

## Factory and methods

```js
createDeviceBootstrapService({
  enabled: true,
  storage: { sql: { exec }, transactionSync, sync },
  reservation,
  selection: {
    profileID, bootstrapKeyID, bootstrapPublicKey,
    receiptIssuerKeyID, receiptIssuerPublicKey
  },
  signer: { sign },
  custody: { keyID, seal, open },
  inspectDeviceAuthority,
  delivery: { deliverBootstrap, hasUnsettledSend },
  alarmStorage: { getAlarm, setAlarm, deleteAlarm, sync },
  clocks: { epochMilliseconds, monotonicMilliseconds },
  operational: {
    maxPendingOperations, maximumAttemptsPerInvocation,
    invocationBudgetMilliseconds, prearmDelayMilliseconds,
    retryDelayMilliseconds, continuationDelayMilliseconds,
    deliveryLeaseSeconds
  }
})
```

These are captured own-data records with the exact listed keys. Adapt methods
with closures when the underlying implementation needs a receiver. SQL returns
an iterable of rows. `transactionSync` must execute its callback atomically and
synchronously; `sync` must fulfill the storage durability barrier. The service
does not accept an asynchronous transaction substitute.

`sign` receives the existing canonical CLIPB1 payload bytes and returns the raw
64-byte P-256 signature. Only the bootstrap signer capability is supplied.
The receipt private key belongs to the separate activation lifecycle. `seal` and
`open` receive `(string, exactAADString)` and return strings; the service binds
purpose, entitlement, provisioning ID, immutable binding, payload/envelope hash
and custody key ID into AAD. Use the dedicated AES-GCM custody adapter with a
separately supplied nonextractable key. Changing only the key while retaining its
ID still fails authenticated opening; the service cannot recover lost custody.

All operational fields are required positive safe integers. Pending capacity is
at most 64, attempts per invocation at most 100, invocation budget at most 60,000
milliseconds, lease at most 1,800 seconds and each delay at most one day.
`continuationDelayMilliseconds` is retained in the required shared policy shape;
this slice currently schedules both retry and continuation using the retry delay.

| Method | Meaning |
| --- | --- |
| `provision()` | Persist one sealed canonical payload, fixed handle/time and immutable binding; initialize authority; return the three-field acknowledgment. |
| `requestIssue()` | Durably request issuance, obtain fresh payment authority, sign and commit one sealed descriptor plus initial outbox row. It does not call the sender. |
| `requestRecovery({ requestID })` | Add an idempotent delivery request for the already committed descriptor. The canonical 16-byte request ID belongs to a trusted recovery caller. |
| `refreshAuthority()` | Refresh the fixed payment scope independently of a suspended serial signer or sender; project known terminal state and cancel pending/leased outboxes. |
| `recover()` / `alarm()` | Recover requested issuance and drain bounded delivery work; alarm entry has reserved, coalesced admission. |
| `readActivationBinding()` | Return only entitlement ID, handle digest and the nine fixed scope fields for the existing local activation lifecycle. |
| `snapshot()` | Return aggregate allocation, issuance, blocked, pending, accepted and uncertain counts. No secrets or recipient are returned. |

The service methods are trusted backend capabilities. This module provides no
public recovery authentication, caller identity inference or arbitrary lookup.
Repeated constructor creation must supply the identical reservation and selection.

## Storage, authority and concurrency

One entitlement Durable Object owns one SQLite database. The new singleton
`device_bootstrap_state` stores schema version, exact configuration, binding and
handle digests, fixed time, payload hash and authenticated sealed payload. The
optional envelope hash and sealed envelope are committed with the first initial
outbox row in one synchronous transaction. `device_bootstrap_outbox` holds stable
delivery/request IDs and leases; `device_bootstrap_attempts` retains outcomes of
uncertain, accepted and reclaimed attempts.

The existing `createStripeDeviceAuthority` uses the same storage and immutable
payment binding. The existing activation lifecycle must also be built locally in
that entitlement object. Its singleton tables and private router brands cannot
be shared across entitlements or transferred over Durable Object RPC.

Allocation is durable before any signing. Payload bytes, issued time, handle,
profile and key IDs are fixed. Issuance rechecks authority after signing and uses
an atomic empty-envelope compare-and-set. Concurrent or crash-retried remote
signing may produce multiple signatures. Only the single committed winning
envelope can reach the sender, and every subsequent recovery uses those exact
bytes. A failed commit acknowledgment never authorizes another released envelope.

Pending or unavailable authority holds work without discarding the allocation.
Known terminal payment or purchaser mismatch is monotonic in the existing
authority ledger and cancels pending or leased delivery. No later active read
resurrects it. The synchronous dispatch callback checks the current authority
revision, lease and committed envelope immediately before invoking the sender.
A terminal update already observed in this object prevents later dispatch. A
remote fact that has not yet reached the object, or a terminal change after
dispatch, cannot retract an external send.

Mail goes only to the exact purchaser returned by the fixed-scope authority.
There is no recipient parameter on issuance or recovery. A changed owner blocks
delivery instead of retargeting the existing descriptor. Neither plaintext
handles nor descriptors are stored in SQL, acknowledgments or diagnostics.

## Mail boundary and durable wake

```js
createDeviceBootstrapMail({
  enabled: true, entitlementID,
  trust: {
    expectedProfileID, bootstrapKeyID, bootstrapPublicKey, receiptIssuerKeyIDs
  },
  from, replyTo, send, timeoutMilliseconds
})
```

It returns `{ deliverBootstrap, hasUnsettledSend }`. The service calls delivery
with exactly `{ to, deliveryID, entitlementID, envelope, payloadHash,
authorizeDispatch }`. The adapter verifies the actual CLIPB1 signature, pinned
profile/issuer and payload hash, then synchronously fences dispatch. The supplied
sender receives `{ deliveryID, message: { from, to, replyTo, subject, text } }` and
must return `{ messageId }` for acceptance. It receives no signer or sealer.

The durable lease and attempt record are synchronized before dispatch. Sender
acceptance means acceptance only, not inbox delivery. A crash, timeout or failed
acknowledgment can cause another send with the identical descriptor and delivery
ID. Provider idempotency is a separate contract; duplicate mail remains possible.
The adapter's soft deadline keeps its busy slot until the underlying send really
settles. Invocation budgets are soft and do not preempt actual I/O.

`alarmStorage` MUST be a dedicated logical channel from the shared alarm
multiplexer. Directly sharing the Durable Object's single physical alarm with
the activation runner is unsupported: either runner could erase the other's wake.
Mutation entry durably prearms the logical wake. Reconciliation retains pending
and leased work, and terminal cleanup deletes only that service's channel after
the terminal state is synchronized. Provider/custody/storage uncertainty leaves
retry work available. The host must restore the logical channels and call their
recovery handlers after object reconstruction.

## Focused evidence and remaining integration

The new test file uses actual file-backed Node SQLite databases with synchronous
transactions, independent memory-only synthetic ECDSA/AES keys, controlled
signing/sending suspensions and private capture sinks. Twelve distinct groups
passed across retained focused runs. The initial eight passed together; later
targeted runs preserved and repaired two source failures: leaked prearm errors
and an empty terminal alarm retained after failure. Already passing groups were
not repeated. Formatting afterward preserved the complete parsed JavaScript AST
apart from positions, raw literal notation and comments.

This is component evidence. It does not establish deployed Durable Object
reconstruction, real provider idempotency, inbox delivery, key provisioning,
shipping configuration or a customer installation. The separate directory and
runtime composition harness and independent review must validate the final
frozen bytes before integration.
