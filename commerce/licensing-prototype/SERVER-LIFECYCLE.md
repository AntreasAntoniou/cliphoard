# Disabled per-entitlement server lifecycle

`createDeviceLicenceServerLifecycle` in `server-lifecycle.mjs` composes the existing scoped Stripe authority, pinned P-256 receipt issuer, SQLite activation ledger, native-mail adapter, durable delivery runner and bounded WHATWG HTTP handler. It has no shipping caller, Worker export, route manifest, environment lookup, provider client or production configuration. Its default is disabled.

The only returned own methods are the frozen `handle(request)`, `alarm()`, `recover()`, `refreshAuthority()` and `refreshAdmission()`. The four trusted lifecycle methods require zero arguments. No service, raw feed, outbox dispatch, SQL, signer, token custody or sender escapes the facade. Public begin/approve reach only the runner, after the existing HTTP parser validates the request.

## Trusted construction

An **own data property** `enabled: true` opts in. Missing/inherited/false switches remain inert without reading dependency getters or capabilities. An enabled getter is rejected without invocation. Enabled options and nested records must contain exactly the following own data fields; inherited fields, getters, symbols and extensions are rejected. Values/functions are captured at construction, so later option mutation does not rebind them. Native host methods must be supplied as plain own-data wrappers with the correct receiver already captured.

| Field | Exact shape / authority |
| --- | --- |
| `storage` | `{sql:{exec},transactionSync,sync}`. One actual SQLite object and synchronous transaction boundary, passed unchanged to both authority projection and activation ledger. |
| `binding` | `{entitlementID,entitlementHandleDigest,accountId,mode,orderRef,sessionId,productId,priceId,currency,unitAmount,taxBehavior}`. Existing fixed purchase binding from `STRIPE-AUTHORITY.md`. |
| `inspectDeviceAuthority` | No-argument trusted, explicitly enabled, scoped `orderService.inspectDeviceAuthority` capability. The request cannot choose a Stripe account/order/session or supply verified facts. |
| `issuer` | `{issuerKeyID,issuerPublicKey,sign}`. Existing pinned new-receipt issuer contract; no CLIP1 key reuse or real issuer selection. |
| `tokenCustody` | `{sealToken,openToken}`. Existing service's token-plus-AAD contract; caller supplies real custody separately. |
| `admission` | `{evaluate,readCurrent}`. `evaluate(event)` retains the authority adapter's exact phase contract and returns `{revision,decision}`. `readCurrent()` returns exact `{entitlementID,revision,decision}`, with the pinned ID, positive safe revision and `allow`/`hold`. Neither defaults to allow. |
| `mail` | `{from,replyTo,send,timeoutMilliseconds}`. Existing native-mail contract; its recipient comes solely from fresh authoritative purchaser reads. |
| `alarmStorage` | `{getAlarm,setAlarm,deleteAlarm,sync}`. Durable alarm capability for the same object's lifecycle. |
| `clocks` | `{epochMilliseconds,monotonicMilliseconds}`. Explicit functions; no clock policy is selected here. |
| `limits` | `{challengeTTLSeconds,deliveryLeaseSeconds}`. Explicit positive integers within the existing service's 1800-second bounds. |
| `operational` | `{maximumAttemptsPerInvocation,maxPendingOperations,invocationBudgetMilliseconds,prearmDelayMilliseconds,retryDelayMilliseconds,continuationDelayMilliseconds}`. Existing runner bounds, all explicitly supplied. |
| `http` | `{origin,bodyTimeoutMs}`. Existing fixed HTTPS-origin and bounded body-reader contract. |

Pure constructors validate the binding/issuer/mail/HTTP options without invoking SQL, timers, providers, signers or senders. The actual projection and ledger initialize lazily. Generic GET/HEAD/OPTIONS, unknown paths, query-bearing requests and malformed bodies do not initialize them or prearm a wake. There is no constructor alarm.

## Commands, observations and durable wakes

The runner gains two optional trusted hooks. Omission preserves existing behavior:

- `refreshFeeds()` runs after a durable prearm, before begin, approve, recovery reconciliation and alarm delivery, including an empty-outbox alarm. A failed refresh rejects the operation and restores a durable prearm; cached active authority cannot substitute for a successful refresh. An unavailable source can therefore retain a retry wake even when there is currently no pending mail.
- `isTerminalAuthority()` must return an exact synchronous boolean. It is read from the same durable monotonic projection inside the short serialized wake chain, after prior alarm writes finish. A true terminal block plus an empty outbox permits removal of a command-owned prearm; false, malformed or throwing results do not. A supplied notification is never by itself authority to delete that wake.

Authority and admission refreshes start independently and publish as each completes. Both must settle successfully before the command/delivery continues. An unavailable or indefinitely pending trusted capability can still block that operation; there is no invented provider deadline or cancellation mechanism. The durable wake remains, except a separately confirmed terminal block can safely clear it. If the refresh invocation later fails, the runner restores a conservative retry wake.

The trusted `refreshAuthority()` and `refreshAdmission()` methods bypass the slow command queue. They accept no request-fed facts. The authority read commits the existing local projection, then publishes the committed active/blocked observation to the ledger. If a service read discovers and commits a terminal block but rejects its active-entitlement request, a `finally` path still publishes that block. The same-SQLite synchronous fence protects the issuance and dispatch commits while publication is pending. Pending/unknown authority is never classified terminal or used as cached eligibility.

A terminal payment/recipient block cancels pending/leased outbox entries and clears their sealed approval tokens. It can remove the wake before paused signing or native sending settles. A signer cannot subsequently commit a new receipt through that block. An already-entered native send cannot be recalled, and a late acknowledgement cannot revive the cancelled ledger entry.

A **temporary admission hold does not cancel already-created approval email or issued receipt mail**. It stops new approval issuance through the existing durable admission-revision checks. Pending code delivery, later higher-revision allow and exact request retry remain possible. Already-issued receipt retrieval and delivery survive a hold. Admission-source outage is different: this composed facade requires its refresh hook to complete before a new command/alarm proceeds, even though the underlying service alone supports some retrieval paths without an admission call.

`recover()` rearms, refreshes both feeds and reconciles pending work without sending inline. An alarm consumed while a command is paused rearms immediately outside the slow queue. New commands still serialize with ordinary reconciliation; only confirmed terminal scope may delete their prearm early.

## Results and limits

Trusted configuration errors are fixed `lifecycle_configuration`; arguments to zero-argument methods are `lifecycle_rejected`; disabled trusted methods are `lifecycle_disabled`; dependency/runtime errors are `lifecycle_unavailable`. No raw dependency message, recipient, token, request body or log is returned. Successful trusted refreshes return only `{ok:true,code:'authority_refreshed'}` or `{ok:true,code:'admission_refreshed'}`. Alarm/recovery return the existing runner's fixed result DTOs.

The HTTP handler and its wire shapes are unchanged. The runner collapses service errors, so composed begin/approve failures currently reach HTTP as generic `503 temporarily_unavailable`; clients must not infer a hold or refund from this. Generic GET/HEAD confirmation behavior remains independent of ledger state. The body-reader deadline bounds parsing, not pending trusted provider/signing/storage work. The runner's invocation budget is a soft bound between delivery attempts, not a hard cancellation deadline for injected capabilities.

This is one **already trusted, purchaser-specific** scope. It is not public authentication, customer bootstrap, tenant resolution, CSRF approval UI, request admission/rate limiting or a production routing factory. In particular, approve contains `challengeID` but no `entitlementHandle`; routing it from a global endpoint to the correct per-entitlement object still needs a separate mapping/protocol design. The native client currently needs a trusted purchaser-specific `entitlementID` before its first request. Neither gap is solved here.

No numerical burst rule, fallback identity policy, real receipt issuer, token sealing/key recovery, handle creation/delivery, provider grants, deployment or background monitoring is selected. An external trusted source must actually deliver newer authority/admission observations or a wake/command must refresh them; this module does not prove gap-free event ingestion. Restoring stale SQLite snapshots is not proved replay-safe. Existing saved offline receipts are not revoked by a server-side hold or terminal block. StoreKit and legacy CLIP1 behavior are untouched.

## Focused evidence

The author checks use generated synthetic cryptographic material, fake scoped inspection/admission/send capabilities and real on-disk Node SQLite. They cover disabled/getter boundaries, frozen bindings, hidden components, command prearm, refresh failures, pending authority, holds, exact issuance retry, terminal blocks during signing/sending, reordered observations, consumed alarms and reconstruction. The existing affected runner checks are retained alongside new hook regressions.

`test/server-lifecycle-workerd.test.mjs` uses the already-installed Miniflare/workerd dependency, `cf:false`, synthetic local routing, denied/count-zero Worker outbound, and no real mail/provider. It exercises actual Durable Object SQLite reconstruction and consumed alarms: pending receipt delivery without re-signing, then a newly blocked fake purchase cancelling pending mail after another recreation. The harness's transparent synthetic token custody is deliberately a fake, not a proposed implementation.

These checks establish local composition under the stated injected contracts. They do not establish production routing, provider authentication, real key custody, mail delivery, Cloudflare scheduling availability, public abuse resistance, device hardware behavior or a released product. Exact commands, logs, input hashes, retained failures and candidate preservation are in the delivery freeze.
