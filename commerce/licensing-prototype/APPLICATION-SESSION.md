# Disabled Direct application session

This additive composition is behind `CLIPHOARD_DEVICE_LICENSING_PROTOTYPE && !APP_STORE`.
There is no shipping caller, default flag, real endpoint, purchaser, issuer, identity
namespace or receipt path. Legacy CLIP1 and Store entitlements are unchanged.

The selected policy remains one purchaser's personal Macs, email approval for each
new Mac, no fixed device cap, and indefinite offline use after approval. This slice
does not choose an admission threshold or a software-key fallback.

## Ownership and construction

An application owner retains one `DeviceLicenceApplicationSession` for its entire
lifetime. Its private flow retains prepared requests and pending service receipts
across repeated panel construction, dismissal and reopening. The panel routes all
actions through the session; it cannot reach the flow's mutators.

`DeviceLicenceApplicationConfiguration` has immutable fields:

| Field | Required trusted input |
| --- | --- |
| `origin` | Exact HTTPS origin admitted by the existing client; no request-selected URL |
| `entitlementID`, `entitlementHandle` | Independently provisioned purchaser scope and activation handle |
| `issuerKeyID`, `issuerPublicKey` | Distinct CLIPD1 issuer trust, never a legacy key or receipt-derived key |
| `expectedDevicePublicKey` | Optional independently known 65-byte device pin; nil permits explicit initial enrolment |
| `receiptFileURL` | Explicit absolute physical local path; existing private parent required |
| `identityKeychainService`, `identityKeychainAccount` | Explicit separate identity namespace |
| `resourceTimeout` | Finite native transport timeout admitted by its existing constructor |

The injected initializer accepts `identityStorage`, `identityKeys`, `transport`,
optional `receiptIO`, `now`, and `makeRequestID`. It constructs the existing
`DeviceIdentity`, `DeviceLicenceApprovalClient`, real
`DeviceLicenceReceiptRepository`, and `DeviceLicenceApprovalFlow`. The flow constructs
`DeviceLicenceRecovery` with the configured issuer/entitlement and the loaded,
validated identity key. A pasted or saved receipt cannot select those bindings.

`DeviceLicenceApplicationSession.native(configuration:)` is the concrete optional
factory: existing Keychain storage, Secure Enclave operations, URLSession transport,
and POSIX repository. All construction is inert. No Keychain lookup, availability
check, key creation, file read, directory creation, URLSession or network request
occurs in construction or panel appearance. The clock and UUID request-ID closure
are evaluated only by explicit flow work. Unsupported secure hardware remains an
explicit failure from the existing identity implementation.

All configuration errors become `.invalidConfiguration`. Observable state contains
only lifecycle, presentation, sanitized approval state and a verified-Pro boolean.
The session does not log configuration, handles, tokens, proofs, responses or keys.

## Explicit lifecycle

- `start()` transitions idle to running once and restores only an existing identity
  and saved receipt. It never creates identity, sends approval or repairs storage.
  Missing identity, absence, corruption and IO failure remain distinct flow notices.
- `openPanel()` changes presentation only. `DeviceLicenceApplicationPanel(session:)`
  has no appearance/disappearance effects. Before start, actions are disabled.
- `requestApprovalForThisMac()` is the only action that may create the first identity.
  The existing flow retains exact IDs/body/proof for explicit retries. A queued begin
  response is not an email-delivery claim or local approval.
- Code entry, local receipt import, restore, retry, different-code entry and cancel
  forward through guarded session actions. There are no automatic retries, new
  challenges, key replacement or receipt-derived trust discovery.
- `closePanel()` cancels local work when cancellable, without destroying the flow.
  Reopening has no retry side effect. Unknown request outcomes retain the same exact
  command; pending issued receipts retain local save retry custody.
- `stop()` is terminal, closes presentation and fences actions and queued state
  publication. Reopening and a second start cannot undo it. The previously verified
  Pro value remains intact. Call stop before the application owner releases the
  session; cancelling an OS/remote operation is not a rollback guarantee.

Each async action returns an optional `Task<Void, Never>` whose completion includes
the final session projection. Cancelling that task targets only its own underlying
flow task. Concurrent/reentrant operation starts are rejected; stop/close are fenced
immediately and their cancellation is performed after any current synchronous
forwarding/publication returns. No queue of new network operations is created.

Combine publishes `@Published` values before the stored value changes, as described
by [Apple's Published documentation](https://developer.apple.com/documentation/combine/published?changes=la__7_1_3).
The session therefore coalesces flow notifications into one MainActor task that
reads the latest completed state setter. It does not call observers that can cancel
the flow from inside the flow's own `willSet` publication. The caller-visible state
is a single atomic snapshot; stale captured snapshots are never replayed after stop.

## Approval and recovery invariants

`isProApproved` becomes true only when the flow already holds a verified receipt:
issuer signature, fixed entitlement/device binding, fresh local key-possession
proof, and successful repository acceptance or authoritative readback. A server
success, a parsed envelope, possession of a public key, or a pending write is
insufficient. Once verified in this session, failures in later work do not erase
that offline approval. There is no clock, refund polling or network lease gate.

An uncertain save requires explicit local restore before further network work or
manual import. An authoritative absent snapshot also resolves the barrier: if no
rename committed, the retained service receipt can be saved again explicitly.
Corrupt bytes, missing identity and read failure are not proof of absence. A commit
that already happened is never rolled back to satisfy cancellation. Previous good
bytes and failed/corrupt records retain the existing repository's preservation rules.

The existing repository supplies bounded strict decoding, descriptor-relative path
checks, private-directory requirements, stable sibling flock and atomic rename/CAS
for cooperating processes. This session does not strengthen that into arbitrary
same-user writer protection or a power-loss durability guarantee. It does not create
or repair directories. Known identity loss/mismatch never silently regenerates a key.
Across process loss, an independently supplied device pin protects a known identity;
without one and with all identity custody deleted, this prototype cannot distinguish
a prior enrolment from an entirely new installation.

## Evidence and remaining qualification

The focused harness uses synthetic memory-only P-256 keys, fake identity custody and
transport, plus real receipt files in fresh task-owned private temporary directories.
It covers inert construction and panel reconstruction, existing-only startup, first
approval/save, offline relaunch with fresh proof, exact replay across dismissal,
pending receipt retry, commit uncertainty before/after rename, terminal stop during
read/proof, mismatched bindings, corruption, last-good preservation and synchronous
observer close/stop. The original observer reentrancy failure and its corrected run
are retained in delivery evidence. No real key/Keychain or network request is made by
these tests; native factory construction alone is not native operation qualification.

No hardware runtime, real TLS, email inbox, real purchaser onboarding, displayed app,
installer, or shipping entitlement integration is claimed. Native URLSession runtime
behavior belongs to its earlier adapter tests, not this suite. Public Apple
documentation was consulted separately from the offline test run.

Pending challenge/token/request custody is deliberately memory-only. Relaunch does
not reconstruct unknown request IDs. A saved receipt can be restored locally; an
emailed approved envelope can be imported explicitly on the same identity. A crash
before either durable receipt exists may still require reviewed service recovery.

Next integration must independently supply purchaser-specific entitlement ID/handle,
issuer trust, device namespace and private physical receipt location; retain this
session in an application owner; call start, close and stop explicitly; and observe
its boolean without replacing legacy/Store entitlement rules. Public routing to a
per-entitlement service remains unresolved: the current approve wire carries a
challenge ID, not an entitlement handle. No route or customer-bootstrap decision is
made here. Real hardware/storage/transport qualification and a reviewed shipping
opt-in remain separate work.
