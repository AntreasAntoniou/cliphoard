# Disabled Stripe authority and pinned device issuer

This candidate connects authenticated, read-only inspection of one existing Stripe
order to the device activation ledger. It adds no deployed route, Worker binding,
event subscription, credential, private key, email sender, timer or production
factory. Every new authority/issuer requires literal `enabled: true` at trusted
construction. Shipping call sites do not supply it. Admission remains a separate,
required trusted capability; payment eligibility never implies admission.

Both factories inspect the own `enabled` data descriptor before any dependency
option. Missing or inherited opt-ins stay disabled, and disabled construction
does not evaluate dependency getters. An `enabled` accessor is rejected without
invocation. Once explicitly enabled, the full options object must have exactly
the declared own data fields; accessors, symbols and extra fields are rejected
before any dependency value is used. This R2 repair follows root-identified
extension AC01 and its independent reproduction; it is not represented as part
of the initial plan-blind review. Malicious Proxy traps remain outside the trusted
construction boundary.

The selected policy remains one purchaser's personal Macs, email approval for
each new Mac, no fixed device cap and indefinite offline receipts. Unusual bursts
pause new approvals through the independently revisioned admission authority.
No burst threshold, real issuer, key recovery, public handle delivery, purchaser
recovery or hardware fallback policy is selected here. StoreKit and CLIP1 remain
separate.

## Authenticated inspection capability

`orderService({ ..., deviceAuthority: { enabled: true, orderRef, sessionId } })`
captures one exact order/session. Its new `inspectDeviceAuthority()` method takes
no arguments and returns exactly:

```js
{ accountId, mode, orderRef, sessionId, productId, priceId,
  currency, unitAmount, taxBehavior, state, ownerEmail }
```

`state` is `active`, `pending`, or `blocked`; `ownerEmail` is the current validated
Stripe Checkout email only for active results, otherwise null. It exposes no
claim URL/token, legacy key, signing seed, public trust key or provider body.
The method refuses an order with no already-persisted exact session binding.
Constructor scope is copied, cannot be supplied through the method, and cannot
be retargeted by later mutation of the constructor object.

The method uses the existing authenticated Stripe read capability and the same
account, session, item, amount, minted recovery-link, payment, charge and refund
checks as legacy fulfilment. It does not call `paid`, `claim`, `drain`, `refund`
or `retryDelivery`, issue a CLIP1, save an order, schedule or send anything. The
minimal shared extraction preserves legacy mutation and validation ordering,
including attempt persistence and alarm scheduling before delivery reads. The
new inspection alone maps dependency/validation errors to fixed
`device_authority_unavailable`; legacy error behavior is unchanged.

Any refund attempt, including pending, requires_action, failed or canceled,
partial refunded amount, full refund or disputed charge yields generic blocked.
That preserves existing conservative eligibility behavior; it does **not** assert
that every listed attempt returned money. Missing/invalid provider responses are
unavailable, not cached active results. The callback is trusted because production
must construct it from the existing authenticated Stripe client and fixed stored
order. An arbitrary object arriving over HTTP is not an authenticated observation.

## Durable projection contract

```js
const authority = createStripeDeviceAuthority({
  enabled: true, storage, binding, inspectDeviceAuthority, admission
});
```

`binding` has exactly `entitlementID`, `entitlementHandleDigest`, and the nine
purchase-scope fields above (accountId through taxBehavior). IDs are constructor
pins. The entitlement ID is canonical 16-byte base64url. The handle digest is
canonical 32-byte base64url SHA-256 of a decoded random 32-byte handle, matching
`tokenDigest` in the existing protocol. This adapter neither creates nor delivers
that handle. It accepts no caller eligibility, purchaser, scope or revision facts.

`storage.sql.exec(query, ...args)`, `storage.transactionSync(callback)` and async
`storage.sync()` are required. The authority projection and activation ledger
must share the **same SQLite storage and transaction boundary**. This caller
obligation cannot be proved by comparing generic JavaScript storage wrappers.
One singleton row pins the binding JSON, first eligible purchaser digest, local
revision and state. Reopening with changed scope/handle/entitlement refuses.
Raw handle and email are not persisted by this projection. The domain-separated
email digest is pseudonymous and potentially guessable, not anonymous data.

Methods:

- `resolveEntitlement(handle)` checks the handle before any provider read.
- `readEntitlement(id)` requires the pinned ID before any provider read.
- Both re-inspect the provider and return exactly
  `{id, revision, status:'active', product:'pro', ownerEmail}` or refuse. No stale
  active fallback is available after a read/durability failure.
- `readAuthorityFence()` is synchronous, reads only the current SQLite row and
  returns exact own data `{id, revision, status}`. Initially revision is 0 and
  status unknown; these are ineligible. It performs no remote or asynchronous work.
- `refreshAuthority()` accepts no arguments, performs the trusted inspection and
  commits an observation, then returns `{id, revision, status, product:'pro'}`
  without an email. This is an explicit trusted reconciliation/feed seam.
- `admission({phase, entitlementID, deviceKeyHash, now})` accepts only the pinned
  entitlement and the existing begin/approve/approve_commit phases. It delegates
  to the explicitly injected admission authority and accepts exactly a positive
  integer `revision` plus `decision: 'allow'|'hold'`. There is no default allow.

Only committed local transitions advance the projection revision. Repeated
identical observations are idempotent; no Stripe event timestamp is promoted to a
monotonic authoritative version. Pending is ineligible but may later become
active. Each state transition changes the revision, invalidating older online
operations. First active observation pins the exact email digest. Any later
purchaser or verified purchase-scope conflict terminally blocks the projection.
Verified blocked state is also terminal: a delayed active observation cannot
restore it, even across a database reopen. There is no reset/rebind method.
An already-issued offline receipt is neither rewritten nor remotely revoked.

The projection's sync fence must be passed into Hermes's activation service as
`readAuthorityFence`. That service must compare exact ID, active status and the
operation's persisted revision inside issuance and dispatch transactions. Old
synthetic consumers may omit the hook for compatibility; production composition
must not omit it. A remote refund/hold that has not reached this database is not
an atomic local revocation signal.

## Explicit lifecycle publication

The fence stops a stale in-flight operation immediately after the projection's
local commit, before an awaited lifecycle publication. It does **not** itself
cancel an outbox or provide gap-free event delivery. Compose the explicit feed:

```js
const observed = await authority.refreshAuthority();
if (observed.status === 'active' || observed.status === 'blocked') {
  await activationService.observeEntitlement(observed);
}
```

This example requires Hermes's service extension that accepts the generic blocked
tombstone. Current pending observations remain fenced but are not valid inputs
to that service's entitlement parser. Reconciliation must retry publication after
a crash between projection commit and feed. A terminal re-read returns the same
blocked revision; the feed is idempotent. No scheduler, wake-up guarantee, webhook
feed or restart driver is added here. Refusal of a blocked `readEntitlement`
does not imply that the service already canceled its queued mail.

## Pinned P-256 issuer capability

`createPinnedDeviceReceiptIssuer({ enabled:true, entitlementID, issuerKeyID,
issuerPublicKey, sign })` returns async `issueReceipt(fields)`. The issuer key ID,
canonical raw P-256 public key and entitlement are captured at construction. The
curve point is validated before invoking the injected signer. No legacy seed is
read, imported, converted or used.

Input must contain exactly issuerKeyID, entitlementID, deviceKeyHash, receiptID
and issuedAt. The wrapper snapshots the canonical CLIPD1 receipt payload before
awaiting the signer and passes a separate fields copy. It accepts only a bounded,
strictly parsed CLIPD1 envelope with a valid signature from that pinned key and
the exact expected payload. Mutated fields, wrong keys, CLIP1 and arbitrary
dependency objects refuse. This wrapper verifies a signing capability; the
activation service still owns authorization, durable receipt intent, revision
and admission fences. A direct trusted caller of a signer is not public purchase
authentication.

## Errors and evidence limits

The new projection/issuer expose only fixed `ProtocolError` codes: configuration,
prototype_disabled, storage_scope_mismatch, authority_scope_mismatch,
authority_unavailable, entitlement_ineligible, admission_unavailable,
signer_mismatch and signer_unavailable. The new inspection uses fixed Refusal
codes for configuration, disabled, unexpected arguments, bound-session mismatch
and unavailable. No method logs payloads or interpolates a dependency exception.
Own-data validation rejects getters, symbols, extra fields and thenables where
a synchronous exact result is required; a malicious injected Proxy/capability is
outside the trusted construction boundary.

Focused tests use synthetic Stripe responses, fresh in-memory cryptographic keys
and real on-disk Node 24 SQLite (including separate connections and close/reopen).
Author composition tests use the immutable Hermes compile-input service snapshot
whose hash is recorded under `.delivery/integration-inputs/INPUTS.json`; that is
not a claim about Hermes's later final freeze. The affected legacy test subset
was run before and after extraction. Preserved red runs demonstrate missing
inspection/projection APIs and unsanitized/invalid-key dependency boundaries.

No provider request, credential read, real key, mail send, hardware action,
deployment or shipping enablement occurred. Tests do not prove real Stripe
account/grant availability, remote event ordering/completeness, production alarm
delivery, runtime/network deadlines for injected capabilities, stale-backup
replay safety, irreversible crash durability, key custody, indefinite hardware
key availability or revocation of perpetual offline receipts. Those require
separate selected production wiring and evidence.
