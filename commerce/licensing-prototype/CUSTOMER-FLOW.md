# Disabled Mac approval and recovery panel

This candidate adds a standalone coordinator and SwiftUI panel. They are compiled only with `CLIPHOARD_DEVICE_LICENSING_PROTOTYPE` and without `APP_STORE`. There is no shipping caller, default flag, service origin, entitlement lookup, issuer selection, persistence path, Keychain use or software-key fallback in this slice. Legacy CLIP1 and Store purchase behavior are unchanged.

The selected policy remains one purchaser's personally owned Macs, email approval for each new device, no fixed device limit, and indefinite offline use of an approved receipt. A new approval may be held for review by the service. The generic wire rejection does not identify a hold, refund, expiry or other reason, so the panel does not invent one. No burst threshold is selected here.

## Owned additions and dependencies

- `Sources/Cliphoard/Support/DeviceLicenceApprovalFlow.swift`: `@MainActor` observable coordinator, public-to-module sanitized state, private pending commands.
- `Sources/Cliphoard/UI/DeviceLicenceApprovalView.swift`: standalone panel and pure presentation/content seam.
- `Tests/CliphoardTests/DeviceLicenceApprovalFlowTests.swift`: memory-only synthetic service, storage and key adapters; focused state/concurrency checks.
- `Tests/CliphoardTests/DeviceLicenceApprovalViewTests.swift`: inert construction, copy distinctions and synthetic offscreen fixtures.
- This document.

The coordinator depends on the separately reviewed `DeviceLicenceApprovalServing` protocol and immutable request/challenge/result types. It delegates proof preparation and wire encoding to that client; it does not duplicate the codec. Existing `DeviceIdentity`, `DeviceLicenceRecovery` and `DeviceLicenceReceiptStorage` retain responsibility for key continuity, fresh local possession, exact trusted bindings, bounded receipt decoding and repository commit semantics. The existing pure activation reducer is unchanged; the observable coordinator adds UI/task lifetime and recovery orchestration around those existing boundaries.

The initializer requires an immutable `DeviceLicenceApprovalContext` with issuer key ID, canonical issuer public key and entitlement ID, plus a separate private entitlement handle. These come from a future trusted composition root, never from an emailed receipt or server challenge. It also requires a `DeviceIdentity`, a receipt storage instance, an approval service, a clock closure and a 16-byte request-ID generator. Constructing or presenting the flow invokes none of them. The injected clock constrains only the first submission of an approval challenge; it never expires or revokes an approved offline receipt.

## Explicit actions and state

The view exposes only phase, notice, approval availability, retry kind and allowed actions. It does not publish the handle, challenge, token, signature, request body, receipt envelope or raw error. Text inputs use `SecureField`; submission, local cancellation and view disappearance clear the visible drafts. There is no clipboard read, analytics, logging or hidden on-appear task. Swift strings are not a secure-memory or guaranteed-zeroization facility.

| Explicit action | Allowed effect and retained state |
| --- | --- |
| Request approval for this Mac | The only action allowed to call `identity.createIfAbsent()`. A newly prepared begin command is retained before dispatch. The returned challenge must match the immutable entitlement and this flow's verified local key. Success means approval was requested/queued, not that email was delivered. |
| Approve this Mac with emailed code | Strictly checks bounded canonical code encoding. The client creates a proof-bound immutable approval command; the coordinator retains the complete command before dispatch. A successful service response still needs local receipt verification and commit. |
| Retry same request | Reuses the retained request ID/body, and for approval the same signature. It neither requests a new challenge nor automatically creates a key. An already-dispatched approval can be replayed after local challenge expiry so the server can return the already-issued receipt. |
| Retry code submission | Applies only when proof preparation failed before an immutable approval command existed or was dispatched. It reuses the same challenge, token and approval request ID; it may ask the key provider to prepare the proof again. |
| Enter a different code | Offered only after a definitive generic approval rejection. It returns to code entry for the same challenge. A subsequent explicit submission creates a new approval request ID. It is unavailable after an unknown outcome. |
| Recover saved approval | Loads an existing identity and calls local recovery only; it cannot create a key or call the service. Fresh possession is required before a restored receipt is published as approved. |
| Import approved receipt | Accepts a bounded exact emailed envelope, loads only an existing identity and calls local recovery. It cannot derive trust from that envelope or make a network request. This covers a server response lost before local saving. |
| Cancel | Cancels this task's wait and fences later UI publication by generation. It retains pending commands and the prior verified receipt. It does not claim to undo a server request, erase an email or revoke a receipt. |

Double invocation while busy is a no-op. All operation returns are checked against the current generation and task cancellation after suspension. Requests, local saves and local recovery are never started automatically by rendering, cancellation, a timer or a failure. A cancelled flow can explicitly resume the retained intent. A later response from the older operation cannot replace the newer UI state.

## Saving, uncertainty and last-good recovery

The coordinator publishes an approved receipt only after `DeviceLicenceRecovery.accept` or `.restore` succeeds under the fixed issuer/entitlement/locally pinned device context. A malformed, foreign or invalid receipt cannot replace the previous verified approval. Storage errors, key unavailability, cancellation and service outage leave that prior in-memory approval available; the coordinator does not perform deletion or rollback.

Cancellation during saving is conservative: even if the task has not yet returned from a repository commit, the coordinator requires a local check. `commitUncertain` has the same barrier. During this barrier, new requests, network retries, code submission and imports are disabled; explicit local restore remains available.

The barrier clears after either (a) a fresh-proof successful restore, or (b) `DeviceLicenceRecovery.restore` returning `.missing` after its validated absent snapshot read. Authoritative absence is useful on first activation when a rename did not commit: the user can then explicitly retry a retained service-response envelope, paste the emailed receipt again, or continue a pending request. Missing identity, unavailable key, corrupt record, insecure path and IO failure are not proof of absence and do not clear the barrier. A prior verified in-memory receipt is preserved even if that later authoritative read finds no saved envelope.

Cancellation propagates to the existing recovery operation's own commit permit through its Task. The coordinator does not call a global `cancelPending` after a delay, which could accidentally cancel a newer recovery operation. The repository's actual commit point remains authoritative; no late rollback is attempted. The flow adds no stronger durability, cross-process, filesystem or secure hardware guarantee than its injected adapters provide.

## Retry lifetime and remaining integration work

Pending handles, tokens and prepared commands are held privately in memory. Keeping the same externally owned flow across panel dismissal preserves exact retry. Process restart loses those pending commands: this slice does not persist approval tokens or create a new secret journal. Existing approved-receipt restore and exact emailed-receipt import remain the local restart paths. A durable pending-command design would require its own custody/reconciliation policy and review before claiming exact network replay across restart.

The composition root still needs an independently reviewed way to obtain trusted issuer/entitlement context and the entitlement handle, an explicit endpoint configuration, an owner-approved device storage configuration, a private receipt path, and lifecycle ownership for the flow. No reset, lost-key migration, issuer rotation, deep link, token URL handler, support override, fixed cap or software fallback is chosen here. Missing/unavailable identity is explicit rather than silently replaced during recovery. Only the consented request action can ask `DeviceIdentity` to create an absent identity. Recovery cannot repair a corrupt record automatically.

### R2 qualification: failed manual imports

Independent review reproduced an R1 custody defect: on a fresh Mac, trying local restore and then pasting a receipt with no existing identity left that unverified paste in the pending service-receipt slot. It incorrectly disabled the separately consented first-activation action. A failed foreign manual paste could also discard an already pending service-response receipt and turn a local save retry into a network retry.

R2 keeps the pasted envelope local to the import task. The task still uses existing-key checks and trusted recovery before accepting it, but failure cannot seize or discard the service-response receipt slot. A failed paste on a truly new identity therefore leaves explicit first activation available, without automatically creating a key, sending anything or retrying a request. If an expected or previously known key is missing, `DeviceIdentity` still rejects replacement even after explicit request consent.

After an uncertain or cancelled manual save, the local-recheck barrier still applies. A valid local restore may recover the committed manual receipt. If local restore definitively finds no saved receipt, the user can paste that manual receipt again; the failed draft is not silently cached as an approval response. Any earlier service-response envelope and exact approval command remain authoritative for their own explicit retry. A fully verified successful manual import can finish the flow normally. No prior approved receipt is deleted or rolled back.

This is an offline candidate, not a release or proof of production email delivery, external exactly-once effects, Secure Enclave behavior, Keychain prompts or full-app runtime behavior. The view's existence does not enable Direct licensing or change Store defaults.

## Focused evidence

The task-owned `.delivery` harness uses no remote dependencies and compiles byte-identical selected baseline support sources, these additions, and the separately frozen client API snapshot. The native network transport, hardware key adapter and app entry point are excluded. It records every compile input hash, explicit Python 3.13.13, Swift version, command and log hash. Swift build concurrency is two jobs.

The coordinator fixtures generate issuer/device keys only in memory and use a fake service backed by the real client proof-preparation codec. Assertions cover consent/inert construction, missing-key recovery without creation, double-click deduplication, foreign challenge rejection, code validation, fresh possession before local approval, exact retry after a lost reply and expiry, generic rejection versus explicit code change, cancellation/reentrancy, failed and uncertain saves, authoritative absence, emailed receipt import, and preservation of a prior offline approval.

The fake receipt adapter models CAS, write faults, committed-versus-uncommitted uncertainty and cancellation before a gated write. It does not claim to retest native filesystem locking or the real repository's permit internals; those are existing separately reviewed boundaries. R1's 16 coordinator cases did not catch the independently reproduced custody defect. Four new R2 regression checks run against unchanged R1 source produced three failed tests/five assertions; the missing-known-key case already passed. After the narrow fix, all 12 affected import/retry/cancellation/uncertainty checks passed. Unchanged baseline groups and UI renders were not repeated.

The preserved R1 UI fixtures use only synthetic state and effect-counting closures. The hidden fixture window is never shown, made key or activated. PNGs are rendered from its view, not screenshots of an installed app or user's screen. Three view cases passed, followed by one changed fixture check at the panel's minimum 300×300 size. The light/dark bottom frames visibly contain the recovery controls and complete policy text; a bitmap is not a complete accessibility or real-window interaction audit. The view and its test source remain byte-identical in R2.

Apple's primary documentation describes [NSHostingView](https://developer.apple.com/documentation/swiftui/nshostingview) as the SwiftUI/AppKit layout and event bridge and [ScrollViewReader](https://developer.apple.com/documentation/swiftui/scrollviewreader) as a proxy for scrolling to child views from actions such as `onChange`. The first detached-host fixture attempts did not establish bottom reachability; their logs and images are retained rather than represented as successful checks.
