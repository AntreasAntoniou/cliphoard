# Opt-in whole device licensing Worker candidate

`device-licensing-worker.mjs` is a separate candidate entry. The default entry,
Wrangler configuration, deployed Worker and existing switches are unchanged.
No real credentials or key material are embedded. This candidate is restricted
to one explicit owned qualification allocation; it is not a public launch policy.

It exports the existing `StripeOrder` name for the original namespace, plus
`DeviceLicenceDirectory` and `DeviceLicenceEntitlement`, each requiring SQLite
Durable Object storage. It composes the accepted original order service/feed,
directory, bootstrap custody/outbox, per-entitlement lifecycle, signed setup
admission and recovery route. Original order inspection supplies payment and
purchaser authority. A signed setup header proves setup possession only.

`DEVICE_FULFILMENT_ENABLED` must be literal `true` for new checkout, device HTTP
and recovery routes. The four original switches retain their purposes. The
trusted device-row interpreter remains installed when paused so refund and
terminal-state processing can still read existing device rows. Readiness rejects
new Sessions while paused or incompletely bound. Existing legacy order rows keep
their original interpreter and require their original CLIP1 material if used;
new device rows never consult that seed.

Supply canonical JSON `DEVICE_LICENCE_CONFIG_V1` with version 1, realm, exact
selection pins, sealer ID/commitment, qualification and operational records.
The config module defines the closed schema. Qualification is one UUID order
reference, `iam@antreas.io`, and an explicit positive epoch-second interval of
at most 900 seconds. Every operational value is mandatory. Fixture values are
synthetic test inputs, not production defaults. The selected profile must be
exclusive to this realm; global profile uniqueness is a deployment contract.

`DEVICE_LICENCE_CUSTODY_V1` is canonical JSON containing existing host-consumer
bootstrapSigner, receiptSigner and setupSealer material; sealer keyBytes is a
32-byte JSON array. The loader checks pinned role/IDs/public correspondence and
AES commitment, imports nonextractably, and wipes its temporary mutable byte
arrays. The platform-supplied secret string remains platform-managed memory;
JavaScript strings cannot be reliably zeroed. There is no key acquisition,
generation, export, logging or provider installation in this module.

Bindings `STRIPE_ORDERS`, `DEVICE_LICENCE_DIRECTORY`,
`DEVICE_LICENCE_ENTITLEMENTS`, `EMAIL`, and `CHECKOUT_RATE_LIMITER` are mandatory
before checkout, alongside original Stripe/claim configuration. EMAIL is the
existing transactional capability. Its adapter accepts both reviewed native
message shapes, restricts sender/reply-to to support@cliphoard.dev and recipient
to the owned inbox, and rechecks delivery switches immediately before send.
Private claim recovery links remain in memory and the intended email only.

Each target initializes durable admission to HOLD. A trusted operator binding
may call `setAdmission({expectedRevision,decision})` with allow/hold; there is no
public operator endpoint. Revision CAS is target-owned SQLite. Allow expires
with the qualification interval. Readiness proves bindings/configuration, not
preexisting operator approval for a target that has not yet been provisioned.
The supervised qualification workflow must explicitly allow the owned target
after purchase/setup and before new-Mac approval. Public policy remains unset.

The exported physical alarm adapters capture documented retryCount/isRetry and
the installed workerd's scheduledTime own data slots from AlarmInvocationInfo,
then invoke the accepted domain alarm methods with zero arguments. They do not
expose alarms via public HTTP. Unknown metadata is rejected. See Cloudflare's
[alarm API](https://developers.cloudflare.com/durable-objects/api/alarms/).

The focused persisted local workerd test re-exports the actual candidate classes
unchanged. Its separate synthetic control gateway invokes only trusted admission
and read-only original authority. Actual physical alarms drive order feed,
bootstrap mail and activation/receipt mail; no manual alarm invocation supplies
the passing result. Stripe and native mail are synthetic outbound intercepts.
The test recreates workerd with the same disk, verifies exact receipt replay and
same-descriptor recovery, then pauses all switches and processes a refund.
This is not provider, inbox, public TLS, production key, hardware or app proof.
Mail remains at-least-once; no exactly-once or independent disaster-backup claim.

No deployment, migration, production secret transfer, purchase enablement,
numeric public abuse policy, durable-state disaster restoration or shipping
activation is authorized by this source file. Those require the reviewed
release procedure and remaining real qualification gates.
