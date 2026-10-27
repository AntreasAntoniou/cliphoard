# Disabled trusted purchase-to-bootstrap coordinator

This additive backend seam connects an authenticated fixed-order purchase inspector to the existing bootstrap directory and bootstrap service. It has no shipping caller, public route, provider client, payment mutation, mail sender, key material or runtime configuration. It is disabled unless the caller supplies its own literal `enabled: true` data property. No operational defaults, rate thresholds or device caps are selected.

## Host contract

Import `createPurchaseBootstrapCoordinator` from `purchase-bootstrap-coordinator.mjs`. The enabled constructor accepts exactly these own data properties:

```js
{
  enabled: true,
  scope: {
    accountId, mode, orderRef, sessionId, productId, priceId,
    currency, unitAmount, taxBehavior
  },
  inspectDeviceAuthority,
  directory: { reserve, lookupReservation, provision, lookupReady },
  resolveTarget,
  allocateEntitlementID,
  allocateProvisioningID
}
```

The nine scope values are validated and captured synchronously, as are the exact function capabilities. Values must be ordinary or null-prototype records without getters, symbol keys or extra properties. Scope uses the existing directory identifier rules: account, Session, product and price identifiers; UUID order reference; test/live mode; lowercase three-letter currency; positive safe integer unit amount; inclusive tax behavior. There is no currency conversion, tax calculation or settlement decision here.

`inspectDeviceAuthority()` must be an authenticated fixed-order closure composed from the existing `orderService(...).inspectDeviceAuthority`, bound to the stored order and Session. It returns exactly the scope fields plus `state` and `ownerEmail`. Pending and blocked states carry null purchaser email; active state carries the actual authenticated purchaser. Request data cannot supply this fact. The host must normalize RPC records into these exact contracts and wrap receiver-dependent methods with trusted closures.

`directory` is the existing `createDeviceBootstrapDirectory` capability, with no replacement reservation store. Its methods retain their existing arguments and results:

- `lookupReservation(scope)` returns literal null for a genuine miss or `{ entitlementID, provisioningID, scope }`.
- `reserve({ entitlementID, provisioningID, scope })` returns that reservation.
- `provision({ entitlementID, provisioningID })` returns `{ entitlementID, provisioningID, bindingDigest }`.
- `lookupReady(entitlementID)` returns literal null while unavailable/pending or the same READY acknowledgement.

The two no-argument allocators return canonical base64url identifiers of exactly 16 bytes. They run only following a genuine initial lookup miss. The host selects their production implementation; this component neither generates identifiers nor selects an operational policy.

`resolveTarget(readyAcknowledgement)` is a trusted host closure selecting the actual bootstrap service associated with the authoritative directory result. It returns exactly `{ entitlementID, provisioningID, bindingDigest, requestIssue }`. `requestIssue()` receives **no arguments** and delegates to that exact service's `requestIssue()` method. Identity labels are consistency checks; they cannot establish that an arbitrary callback belongs to the named target. The host must supply the trusted service resolver, and the selected service must retain its own fresh payment and purchaser fences.

The returned frozen capability exposes only `process()`. Supplying any argument rejects before calling a dependency. It accepts no recipient, eligibility, entitlement, provisioning or public target input. Success is a frozen `{ entitlementID, provisioningID, bindingDigest, ok: true, code }`, where code is `issued` or `already_issued`. It exposes no purchaser, handle or signed envelope.

## Sequence and uncertain acknowledgements

Each operation reads fresh authority and requires exact active matching scope. It then looks up the original reservation before allocating. Undefined, malformed data and thrown lookup errors are unavailable, never absence. Only literal null on the initial genuine miss permits the two allocators and one reserve dispatch.

A lost, conflicting or malformed reserve acknowledgement is reconciled by looking up the original nine-field scope. Only the actual directory reservation advances. A per-instance uncertainty flag prevents later null results from authorizing replacement allocation after an uncertain reserve dispatch. This flag is not a second durable ledger and does not survive coordinator reconstruction; the authoritative directory's uniqueness and recovery remain essential.

Provisioning always uses the recovered reservation's original IDs. If its acknowledgement is uncertain, only a matching `lookupReady` result advances. READY means initialization, not payment eligibility or permission to issue. Target selection checks all three acknowledgement values.

Before requesting issuance, the coordinator reads authority again and requires active matching scope plus the same purchaser string as at the start of this operation. A purchaser change holds before calling issue. This comparison is per operation; it is not durable purchaser enrollment across operations or process reconstruction. The actual bootstrap service's durable purchaser and payment fences remain required. A refund can still occur after this final read; the service's own fresh check protects that boundary.

A lost issuance acknowledgement returns a sanitized error. A later notification reuses the reservation and calls the same no-argument service operation. The actual bootstrap service retains the CAS-winning descriptor and returns `already_issued` when appropriate. The coordinator does not send mail or request recovery automatically. Issuance acknowledgement is not inbox delivery, successful activation, Pro, release or real payment proof.

Same-instance concurrent calls share the same in-flight promise. The promise is installed before scheduling any dependency callback, so a synchronously reentrant inspector also receives that exact promise. Separate coordinator instances can allocate unused candidates during a race; the actual directory's unique purchase reservation selects the winner. Cross-object provisioning and issuance are not atomic. No global exactly-once generation, signing or delivery claim is made.

## Errors and execution limits

Constructor errors are fixed `coordinator_configuration`. Disabled calls reject with `coordinator_disabled`. Enabled operations use fixed `PurchaseBootstrapCoordinatorError` codes, without underlying causes or provider messages: `coordinator_rejected`, `coordinator_authority_unavailable`, `coordinator_ineligible`, `coordinator_scope_mismatch`, `coordinator_purchaser_mismatch`, `coordinator_directory_unavailable`, `coordinator_allocation_unavailable`, `coordinator_target_mismatch`, and `coordinator_issue_unavailable`.

The boundary assumes trusted realm intrinsics and trusted dependency functions. It rejects ordinary own accessors without invocation; malicious Proxy traps and hostile same-realm mutation of built-ins are outside that guarantee. In-flight coalescing is not a rate limit or abuse policy. The coordinator cannot preempt a hung trusted callback; the host must bound execution. Cancellation cannot roll back dispatched durable work.

## Author verification

Only the new focused test file runs. It composes actual in-memory SQLite directory and bootstrap service implementations, predictable synthetic key fixtures and, in one group, the actual fixed-order orderService inspector over the existing fake Stripe adapter. The fake Session is local test data, not a new provider Session. Explicit test operational numbers are synthetic values, not production defaults.

The retained evidence is under `/Users/antreas/Documents/ChatGPT/Cliphoard/release/2026-10-27/purchase-bootstrap-coordinator-20261027/`. `RED-01` retains the missing-module failure. `AUTHOR-RUN-02` passes the initial 18 groups. `PRE-PURCHASER-*` retain source before the new purchaser-race regression. `PURCHASER-RED-03` retains its behavioral failure, followed by the narrow comparison repair and five passing affected groups in `PURCHASER-GREEN-04`. `DISABLED-FIXTURE-05` passes the tightened false-opt-in getter fixture. These are author tests, not independent validation.

Runtime: `/opt/homebrew/bin/node` v26.7.0. Initial command:

```sh
/opt/homebrew/bin/node --test --test-timeout=10000 --test-concurrency=1 commerce/licensing-prototype/test/purchase-bootstrap-coordinator.test.mjs
```

Affected rerun commands and actual exit statuses are retained in their JSON records. Existing passing suites were not rerun. The initial 18 groups plus the new affected group cover disabled/configuration boundaries, unavailable and ineligible authority, malformed lookups, real component composition, duplicates, lost reserve/provision/issue acknowledgements, same/separate-instance concurrency, refund races, target mismatch and actual fixed-order inspection. No real credentials, vault, provider, network delivery, public TLS, hardware, reboot, app process or shipping path was exercised. Existing shipping behavior and the disabled prototype setting are unchanged.

## R2: synchronous reentry repair

Independent R1 review reproduced synchronous inspector reentry before the original in-flight promise assignment. That allowed two operations in the same instance. `PRE-REVIEW-R1/` retains all three exact R1 programs and their hashes, and the original `FROZEN/` and evidence remain unchanged. The new author regression in `REENTRY-RED-07` reproduces distinct promises on R1 (exit 1). The sole runtime repair schedules `run` through `Promise.resolve().then(run)` before storing the resulting promise synchronously. `REENTRY-GREEN-08` passes the new reentry group and three affected negative/retry/concurrency groups (exit 0), with one reserve, one provision and one issue in the reentry case. Twenty distinct author groups have been exercised across retained executions; the complete 20-group file was not rerun. The final three R2 additions are frozen separately in `FROZEN-R2/` with `FREEZE-MANIFEST-R2.json`. Independent affected R2 validation remains pending.
