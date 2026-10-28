# Explicit Durable Object hosts

`durable-object-hosts.mjs` is an opt-in composition factory. It is not imported by
the deployed Worker or current default application. No deployment binding,
production key retrieval, public authentication provider or operational value is
selected by this module.

`createDeviceLicenceDurableObjectClasses` requires literal `enabled: true`, the
platform `DurableObject` base, and trusted `configureDirectory(ctx, env)` and
`configureEntitlement(ctx, env, reservation)` capabilities. The latter may be
asynchronous. Export the returned Directory and Entitlement classes from a future
reviewed Worker, using SQLite-enabled bindings supplied in both configurations.
The realm pins the object addresses to `realm:directory` and
`realm:entitlement:<entitlementID>`; the hosts verify their actual platform IDs.

Directory configuration supplies `realm`, `directoryNamespace`, `targetNamespace`,
`inspectDeviceAuthority(scope)`, and explicit entitlement/provisioning ID
allocators. The inspector must read the existing authoritative order service.
It must return the exact nine scope fields plus `state` and `ownerEmail` as a
primitive own-data record. A platform RPC adapter must capture those values and
dispose its RPC wrapper before returning them. There is no second order ledger.

Trusted directory RPCs are:

- `processPurchase(scope)`: fresh authority checks, original reservation reuse,
  target initialization, READY acknowledgement and setup issuance request.
- `refreshPurchase(scope)`: refreshes both authority consumers of an existing
  READY target. Returns exactly `{ok:true,code:'authority_refreshed'}` after both
  complete, or `{ok:true,code:'absent'}` for a genuinely missing reservation.
  A pending reservation or failed refresh remains retryable by rejection.
- `lookupReady(entitlementID)`: lookup only. Directory HTTP fetch returns 404.

The entitlement configuration additionally supplies `selection`, `keys`,
`inspectDeviceAuthority`, `admission`, `mail`, `clocks`, `bootstrapOperational`,
`activationOperational`, `limits`, `http`, `maxConcurrentRequests`, and
`alarmRecoveryDelayMilliseconds`. These are explicit existing component inputs;
there are no production numerical defaults. `keys` contains the three existing
host-consumer capabilities (`bootstrapSigner`, `receiptSigner`, `setupSealer`).
Their IDs/public pins must match selection. Activation-token sealing uses a
distinct associated-data domain with that same sealer.

The target owns one SQLite storage containing its immutable reservation, final
acknowledgement, bootstrap state/outbox, activation ledger, authoritative payment
projection and two logical alarm channels. Native physical alarms are owned only
by the existing mux. A partially initialized reservation cannot be finished by a
public request; the trusted original reservation must reconcile it. READY means
initialization, never paid authority or Pro.

Trusted target RPCs are `provision(reservation)`, `requestIssue(ack)`,
`requestRecovery(ack, requestID)`, `refreshAuthority(ack)`, and `recover(ack)`.
Control calls require an exact persisted acknowledgement before reconstructing
capabilities. `alarm()` reconstructs that original target and dispatches due mux
channels. Public `fetch(Request)` is lookup-only against the existing target and
then uses the reviewed lifecycle authority/possession checks. These RPCs are
trusted binding capabilities, not public administration routes.

`createDeviceLicenceAuthenticatedEdge` requires the realm/namespaces, HTTPS
origin, explicit concurrency bound and `authenticate(request, entitlementID)`.
Only an exact `{decision:'allow', realm, entitlementID}` permits directory lookup.
The authenticator must leave the original request body unused and unlocked.
Lookup failure/unknown IDs never create target state. The generic confirmation
GET/HEAD response performs no authentication, directory access or target action.
An occupied edge slot remains occupied until authentication/routing settles,
including after client cancellation. This is not a selected abuse/rate policy.

The new Node tests use real in-memory SQLite and deliberate public synthetic
keys. The new local workerd test uses actual SQLite Durable Objects, a separate
synthetic order RPC, exact descriptor recovery after runtime recreation, both
logical alarm channels and blocked-payment rejection. `cf:false` and zero Worker
outbound calls describe that test only. This is not production provider, real
inbox/TLS, durable disaster restoration, signed-app or shipping evidence. No
cross-object transaction or exactly-once mail delivery is claimed.
