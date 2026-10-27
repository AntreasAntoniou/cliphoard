# Disabled device approval mail and alarm adapters

This candidate has no Worker export, route, binding, sender address, credential, production key or shipping caller. Both factories default off. Legacy CLIP1 and the Store edition remain separate. The selected policy remains one purchaser's personally owned Macs, email approval per new Mac, no fixed device cap and indefinite offline use after approval. Operational scheduling limits below do not choose an activation-abuse threshold or a software-key fallback.

## Service additions

`createSqliteActivationService` accepts optional `readAuthorityFence()`. When provided, every `requireCurrent(revision)` also reads this synchronous exact own-data object:

```js
{ id, revision, status }
```

It must identify the pinned entitlement and the operation's exact positive revision with `status: 'active'`. Promises, accessors, extra fields, exceptions and other statuses fail with fixed `authority_fence_rejected`. The hook performs no await or external I/O. Final commit and dispatch checks read it within the existing synchronous SQLite transaction. Production composition must supply a trusted projection from the **same SQLite database**; supplying a callback alone does not prove co-location. Omission preserves existing synthetic consumers, not a production alternative.

The internal entitlement parser also accepts `blocked`, a generic trusted tombstone distinct from a refund or dispute. Any non-active observation cancels pending/leased work. The fence can stop an in-flight operation before its asynchronous notification arrives, but does not update the licensing ledger itself. An orchestrator must still feed a terminal `{id, product:'pro', revision, status:'blocked'}` to `observeEntitlement`. Until then, undelivered work can remain due and wake again. Pending/unknown authority is ineligible; it is not a fabricated refund. Recipient changes must advance the authority revision.

`nextDeliveryAt()` synchronously returns the earliest pending-now or leased-expiry epoch **second**, or `null`. It exposes no identifier, recipient, token or row. Accepted/cancelled rows do not contribute. There is no new schema or migration.

Private delivery context is an exact own-data object:

```js
{
  to, deliveryID, challengeID, entitlementID, entitlementRevision,
  deviceKeyHash, authorizeDispatch,
  // Approval mail adds: token, expiresAt
  // Receipt mail adds: receipt
}
```

`authorizeDispatch()` closes over the selected row/record/lease. It returns `undefined` only while that exact lease, entitlement revision, authority and pending/issued state remain valid; approval expiry is checked too. It must be invoked synchronously immediately before the native send, after any asynchronous verification. A context cannot select another row. Already-dispatched mail cannot be recalled by a later block.

The existing ledger marks dispatch before entering its mail callback. Thus adapter verification or final authorization rejection may conservatively record an **uncertain** attempt even when the native sender was never called. This candidate preserves that behavior; it does not claim a more precise external outcome from a thrown callback.

## Native sender

`createNativeMailDelivery({enabled, entitlementID, trustedIssuers, from, replyTo, send, timeoutMilliseconds, setTimer?, clearTimer?})` returns `deliverApproval(context)`, `deliverReceipt(context)` and `hasUnsettledSend()`.

Configuration is explicit; there is no environment lookup. The issuer map is copied and uses the distinct CLIPD1 trust path. The context's recipient originates only from the service's fresh authoritative read; the adapter is a private capability, not an HTTP endpoint accepting email. It validates exact bounded fields, a single bare mailbox, matching entitlement/challenge/delivery IDs and positive revision. Receipt mail verifies the strict CLIPD1 signature and expected entitlement/device hash before using the exact envelope. It does not treat receipt-derived fields as trust or reuse a CLIP1 signer.

The injected native-compatible call is exactly `send({from, to, replyTo, subject, text})`. There are no extra recipients, headers, links, tracking fields or attachments. Templates include code or exact receipt only in plain text and are deterministic for the persisted context. Only an exact own-data `{messageId: nonempty bounded string}` confirms provider acceptance; the identifier and raw provider responses are discarded. Errors expose fixed codes only. No email, handle, key, token, device/customer ID, receipt or provider error enters logs or aggregate analytics.

Cloudflare's [Workers Email API](https://developers.cloudflare.com/email-service/api/send-emails/workers-api/) documents this native message and `messageId` result. REST recipient-grouped results are not accepted. No provider idempotency or native abort guarantee is assumed; acceptance is not inbox delivery.

A deadline returns `delivery_timeout` while retaining the single dispatch slot until the actual promise settles. Concurrent or subsequent calls return `delivery_busy`; a late settlement only releases the local slot and cannot acknowledge the ledger. If verification finishes after its caller deadline, it cannot start a late send. The runner skips new delivery attempts while this slot remains occupied. Recreating the object loses that in-memory promise; the persisted lease still delays replay, but an older external attempt may already have succeeded. Duplicate delivery of the same code/receipt remains possible across recreation. This is neither exactly-once email nor a global bound on unseen provider work.

## Runner and wake ordering

`createDeliveryRunner({enabled, makeService, alarmStorage, mail, clockMilliseconds, monotonicMilliseconds, operational})` returns `begin`, `approve`, `alarm`, `recover`, `observeEntitlement` and `observeAdmission`. `alarmStorage` is a plain adapter with asynchronous `getAlarm`, `setAlarm`, `deleteAlarm`, `sync`; times are milliseconds. `mail` needs only `hasUnsettledSend`. `makeService()` is synchronous and must wire the same mail adapter into the service; it is lazy and cached. Constructing a runner performs no service, storage or provider operation. Default-off methods inspect no dependency or request.

`operational` requires explicit positive integers: `maximumAttemptsPerInvocation` (at most 100), `maxPendingOperations` (at most 64), `invocationBudgetMilliseconds` (at most 60,000), and `prearmDelayMilliseconds`, `retryDelayMilliseconds`, `continuationDelayMilliseconds` (each at most one day). These technical bounds are not selected production defaults or device limits. A native caller deadline is explicit and at most 60 seconds. The soft invocation budget uses the separate injected monotonic millisecond source, checked between attempts; it cannot expand when epoch time moves backwards, and a monotonic regression stops further attempts. It is not a hard interruption of arbitrary trusted storage, authority, signing or sealing callbacks. Those adapters must terminate under their own contracts. The native sender deadline handles an uncooperative provider while retaining its slot.

`maxPendingOperations` counts running plus queued ordinary begin/approve/recover calls. Saturation immediately rejects `runner_busy`; the rejected call never executes later. One reserved alarm operation remains available beyond that capacity, and concurrent alarm callers share its exact promise. This coalescing also bounds wake-chain growth: at most the active operation and one alarm-entry rearm can be awaiting short scheduling work. No timeout releases command ownership while trusted work is unsettled. This is operational admission control, not a limit on approvals or personally owned Macs.

The runner exclusively owns one per-entitlement alarm. Two serialization chains serve different purposes:

1. The command chain serializes explicit begin/approve, delivery and final reconciliation. Commands never send mail inline; `recover()` only reconciles a wake. Trusted entitlement/admission feeds bypass this chain so they can fence paused signing/decryption/mail immediately.
2. A short alarm-storage chain serializes prearming and cleanup. `alarm()` durably rearms on entry **before** waiting behind a busy command, because the runtime has already consumed its prior alarm. After waiting it refreshes the failsafe again before external work. Cleanup cannot race that rearm.

Before any begin/approve enqueue opportunity, prearm and sync must succeed. A crash after prearm but before enqueue leaves a harmless empty wake. A crash after a commit but before acknowledgement/post-command scheduling leaves the prearmed wake. If an alarm is consumed during a paused command, its entry path restores a persisted wake before waiting. This closes the first-draft bug where simply queueing the alarm behind the command left no alarm at a later commit boundary.

After bounded drain, pending work receives a continuation wake; unexpired leases wait for their expiry; a busy sender receives a later wake without another claim. An earlier pre-existing future wake is preserved. A newly installed failsafe can move to the actual next due time. Only an empty outbox permits deletion, under the short chain while enqueue commands remain serialized. Failed storage operations leave the operation rejected with a fixed error; permanent storage/alarm failure and the runtime crash interval before JS handler entry remain platform limitations, not new atomicity guarantees.

Cloudflare documents [one alarm, replacement by `setAlarm`, at-least-once execution and finite automatic retries](https://developers.cloudflare.com/durable-objects/api/alarms/). The adapter explicitly rearms instead of treating those retries as indefinite recovery. The [SQLite storage API](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/) distinguishes synchronous SQL transactions from asynchronous alarm operations. This is an ordered prearm protocol, not an assertion that `setAlarm()` is inside `transactionSync()`.

The focused local workerd test confirmed that a committed receipt plus lost command response retained its prearmed alarm after full runtime recreation; construction/status did not overwrite it, and the actual alarm handler observed `getAlarm() === null`, delivered the stored receipt and cleared the empty wake. An on-disk SQLite interleaving test separately consumed the alarm while begin was paused, then committed and recreated the service from the restored wake. All test provider sends were synthetic; worker outbound fetches were forbidden and counted zero. This counter covers the worker, not the host test runtime: the earlier harness allowed Miniflare's default Cloudflare metadata lookup and created a metadata cache. The corrected harness explicitly sets `cf: false`; its affected runtime check passed again, with the original private cache unchanged and retained. Do not describe the whole milestone as having no network activity.

## Evidence and remaining work

The candidate's `.delivery` freeze pins source, baseline, patch, commands, runtimes and logs. Six new service checks failed against the baseline, then those plus the 20 existing service checks passed. Eight native-mail checks and fourteen runner checks passed. One local workerd composition passed. Initial new-module import failures are scaffold evidence, not reproduced behavior. The first native fixture accidentally included its test-only `fire` method in strict configuration; the rejection and fixture correction are retained. The real first-draft consumed-alarm failure, failed source and corrected test are retained. Root's later queue-capacity/elapsed-clock review produced a bounded API correction; its pre-correction source and failing new-contract configuration checks are preserved separately, without presenting those configuration failures as a runtime saturation reproduction.

Tests use synthetic in-memory P-256/AES keys, new task-owned temporary SQLite/runtime directories and fake native sends. They exercise no owner Keychain, vault, real device, sender or production binding. The corrected local runtime uses ephemeral loopback test transport, disables host CF metadata lookup and rejects worker outbound fetches. Earlier metadata-cache creation is retained as a separate qualification; no packet-level record establishes the exact request outcome. No deployment manifest changes or application tests are included.

Remaining production prerequisites are a reviewed same-database entitlement/recipient authority and gap-free terminal feeds, distinct issuer/seal-key custody, explicit sender/binding, lifecycle composition that cannot bypass prearming, retry/retention tuning and aggregate operational visibility. Arbitrary same-user storage mutation, stale backup restore, lost authority feeds, clock anomalies, permanent infrastructure failure and cross-incarnation external ambiguity remain outside these guarantees. No offline receipt is revoked by this adapter.
