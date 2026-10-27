# Disabled Mac device identity candidate

This slice adds an asynchronous identity coordinator, an optional Secure Enclave implementation and an insert-only Keychain storage adapter. All five Swift source/test files are entirely inside `CLIPHOARD_DEVICE_LICENSING_PROTOTYPE`. Nothing instantiates them in the application. No existing source, licence verifier, activation reducer, StoreKit path, app entry, manifest, entitlement, namespace default or deployment is changed. This note supplements the initial `PROTOCOL.md`; its earlier statement that native adapters do not exist describes the previous slice.

The selected policy remains one purchaser's personal Macs, email approval for each new device, no fixed device cap and indefinite offline receipts. Existing CLIP1 and StoreKit behavior stays separate. This implementation selects no software-key fallback, burst threshold, recovery authorization or production keychain access group.

## Owned files and interface

- `Sources/Cliphoard/Support/DeviceIdentity.swift`: injectable storage/key interfaces, a strict storage record, identity lifecycle and implementation of the existing `DeviceLicenceKeyProvider`.
- `Sources/Cliphoard/Support/DeviceIdentityKeychain.swift`: exact-scope generic-password read and atomic insert; native calls are injectable.
- `Sources/Cliphoard/Support/DeviceIdentitySecureEnclave.swift`: optional CryptoKit implementation and background work queue.
- `Tests/CliphoardTests/DeviceIdentityTests.swift` and `DeviceIdentityKeychainTests.swift`: synthetic coordinator, format, concurrency, failure and native-query tests.

`loadExisting()` never creates a key. The receipt verifier's provider calls only load an existing identity or use a previously verified in-memory identity. `createIfAbsent()` is a distinct, explicit first-activation operation. A caller with an approved receipt must not automatically turn a missing key into a creation request. Optional `expectedPublicKey` pins an identity known by the integrating caller; once loaded, the coordinator pins the public key itself. A known/expected identity whose record disappears produces `missing`, even through `createIfAbsent()`.

New material is checked against its restored public key before insertion. The coordinator publishes an identity only after reading and validating the stored winner. `SecItemAdd` duplicate handling never updates or deletes the existing item; independent creators converge on the winner. A crash or cancellation after insertion can leave a valid stored identity that the next load reuses. Creating two provisional enclave keys under contention is possible; exactly-once key creation is not claimed.

Newer load/create requests supersede earlier requests on the same coordinator. Generation checks after awaits discard stale success, failure and signatures. Explicit cancellation preserves the last identity. Failed reads, unavailable hardware, missing entitlements, corruption, unexpected replacement, restoration failure and invalid signatures never erase or overwrite the known identity or stored record. No reset, rotation, delete or repair API exists. This module never receives or mutates an approved receipt.

## Native storage and cryptography

The private key operations use only `SecureEnclave.P256.Signing.PrivateKey`. Availability is checked with `SecureEnclave.isAvailable`; unsupported hardware yields `unavailable(.secureHardware)`. There is no runtime software-key path. The adapter stores CryptoKit's encrypted, enclave-wrapped `dataRepresentation`, not raw private-key bytes. Apple documents restoration as restricted to the same enclave. The public point is canonical 65-byte X9.63/uncompressed P-256, and signatures are 64-byte P1363 from CryptoKit's `rawRepresentation`.

The exact local record is `cliphoard.device-identity\n1\n`, followed by the 65-byte public point, a four-byte big-endian blob length, then 1–16384 opaque wrapped bytes. Total length must match exactly. Unknown versions, noncanonical points, oversized/truncated/extra bytes and public-key/blob mismatch fail. The blob bound is a defensive prototype bound; it is not a documented guarantee about all future Apple representations.

Keychain scope requires explicit, bounded service/account strings. The query selects generic-password items in the data protection keychain with synchronization disabled. Inserts specify `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. The enclave access control uses the same accessibility and `.privateKeyUsage`, without biometric/user-presence flags. Every Keychain query and enclave operation uses an `LAContext` with interaction disallowed. This conservative prototype choice makes locked/authentication-required conditions unavailable; it is not a new owner-selected requirement for repeated approval or a promise that keys work while the Mac is locked. No legacy keychain search, broad enumeration, access-group guessing, user prompt or fallback store is implemented.

The native adapters schedule synchronous APIs on dedicated utility queues. Their constructors do no Keychain or hardware work, and there is no main-actor dependency. An OS call can still hang its queue: cancellation invalidates returned results but cannot interrupt Security/CryptoKit or undo an insertion already committed. Hard deadlines, queue/backlog policy and recovery UI remain integration work; asynchronous syntax is not a latency guarantee.

Signing accepts only the exact bounded local-proof or approval message shape already specified in `PROTOCOL.md`. Approval messages must contain this identity's exact public key/hash. Returned signatures are checked locally against the requested bytes and identity before exposure. This is not a replacement for user intent, email approval, challenge validation, entitlement checks or service-side expiry checks.

## Focused evidence and limits

Tests use only injected fake key/store operations. Synthetic software P-256 keys exist in memory solely to verify public-key/signature interoperability; fake stored blobs are opaque counters, never serialized private keys. The optional native Secure Enclave implementation is compiled but never instantiated or executed. Native Keychain adapter tests inject fake `copyMatching`/`add` calls and inspect query configuration; no `SecItem` operation is executed. `LAContext` objects are configured without evaluating authentication.

The restart test recreates the client against retained fake storage and a retained fake hardware registry. It establishes the adapter contract across coordinator restart, not actual process, reboot, backup restore, Secure Enclave or Keychain behavior. Real hardware restoration, signed-app access entitlements, locked/login transitions, keychain faults, OS updates and migration are deliberately untested. A copied blob failing against a different fake registry is a negative contract test, not hardware attestation.

The focused command is:

```sh
swift test --jobs 2 --disable-automatic-resolution -Xswiftc -DCLIPHOARD_DEVICE_LICENSING_PROTOTYPE --filter DeviceIdentity
```

The source patch, baseline pins, test logs and final hashes are retained separately under `.delivery/`. The fixture tests cover missing/unsupported state, stored readback uncertainty, stable identity after client recreation, atomic creation races, expected-key loss, malformed records, mismatched/cross-device fake blobs, stale success/failure, cancellation before/after insertion, wrong signer/length, bounded domain-specific proofs, noninteractive device-local query attributes, typed native errors, and the actual offline receipt verifier.

This is per application/keychain-user scope on an enclave-capable Mac, not a physical-Mac serial identity. It provides no hardware attestation, proof of personal ownership, resistance to a patched client, or guarantee against authorized use of the key by compromised local code. Indefinite offline receipts remain nonrevocable; a temporarily inaccessible key must not delete their bytes. A restarted client cannot perform fresh possession proof until the key becomes usable again. Production recovery from permanent key loss still requires a new identity and new email approval.

The next step is independent review of this disabled candidate, then an explicitly scoped hardware test with a temporary namespace and signed app/entitlements. Integrators still need a chosen stable namespace/access policy, user-initiated creation/recovery, timeout/backoff behavior, crash-safe receipt/public-identity persistence and UI. No production access group, trust key or software fallback should be inferred from these tests. No sensitive logging or analytics exists in this slice.

## Primary platform references

- [Storing CryptoKit keys in the Keychain](https://developer.apple.com/documentation/cryptokit/storing-cryptokit-keys-in-the-keychain): encrypted enclave representation and same-enclave restoration; macOS sample entitlement setup.
- [Secure Enclave signing key](https://developer.apple.com/documentation/cryptokit/secureenclave/p256/signing/privatekey): create/restore, public key and signature APIs.
- [Secure Enclave availability](https://developer.apple.com/documentation/cryptokit/secureenclave/isavailable).
- [Data protection keychain](https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain): accessible attributes without iCloud synchronization.
- [Noninteractive authentication](https://developer.apple.com/documentation/security/ksecuseauthenticationuifail): Apple's replacement is `kSecUseAuthenticationContext` with `LAContext.interactionNotAllowed`.
- [Local authentication context](https://developer.apple.com/documentation/localauthentication/lacontext/interactionnotallowed).

SOFA was considered for platform uncertainty but its authenticated tools were not exposed; no credential or alternate endpoint was used. Apple documentation and installed SDK declarations supplied the API evidence. Python custody operations used explicit verified `/opt/homebrew/bin/python3.13` 3.13.13. Root owns Butler/Argus capture; this worker does not integrate, commit, sign, publish or deploy the candidate.
