#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE
import CryptoKit
import XCTest
@testable import Cliphoard

actor DeviceIdentityTestGate {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        entryWaiter?.resume(); entryWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitForEntry() async {
        if !entered { await withCheckedContinuation { entryWaiter = $0 } }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

actor DeviceIdentityTestStorage: DeviceIdentityStorage {
    var bytes: Data?
    var readFailure: DeviceIdentityFailure?
    var failReadback = false
    var nextReadGate: DeviceIdentityTestGate?
    var insertGate: DeviceIdentityTestGate?
    private(set) var reads = 0
    private(set) var insertions = 0
    private(set) var writes = 0
    func set(_ data: Data?) { bytes = data }
    func fail(_ error: DeviceIdentityFailure?) { readFailure = error }
    func failAfterInsertion() { failReadback = true }
    func holdRead(_ gate: DeviceIdentityTestGate) { nextReadGate = gate }
    func holdInsertion(_ gate: DeviceIdentityTestGate) { insertGate = gate }
    func read() async throws -> Data? {
        reads += 1
        let snapshot = bytes, failure = readFailure, gate = nextReadGate
        nextReadGate = nil
        if let gate { await gate.pause() }
        if let failure { throw failure }
        return snapshot
    }
    func insertIfAbsent(_ record: Data) async throws -> Bool {
        insertions += 1
        if bytes != nil { return false }
        bytes = record; writes += 1
        if failReadback { readFailure = .unavailable(.storage) }
        if let insertGate { await insertGate.pause() }
        return true
    }
}

/// Only ephemeral software keys for synthetic proof checking. The stored blob is
/// an opaque counter, never a serialized private key. No native adapter is used.
actor DeviceIdentityTestKeys: DeviceIdentityKeyOperations {
    private var keys: [Data: P256.Signing.PrivateKey] = [:]
    private var available = true
    private var signMode = 0
    private var misrepresentCreation = false
    private var createGate: DeviceIdentityTestGate?
    private var signGate: DeviceIdentityTestGate?
    private(set) var creations = 0
    private(set) var signatures = 0
    func setAvailable(_ value: Bool) { available = value }
    func setSignMode(_ value: Int) { signMode = value }
    func misrepresentNextCreation() { misrepresentCreation = true }
    func holdCreation(_ gate: DeviceIdentityTestGate) { createGate = gate }
    func holdSignature(_ gate: DeviceIdentityTestGate) { signGate = gate }
    func isAvailable() async -> Bool { available }
    func create() async throws -> DeviceIdentityMaterial {
        creations += 1
        let blob = Data([UInt8(creations)])
        let key = P256.Signing.PrivateKey(); keys[blob] = key
        let gate = createGate; createGate = nil
        if let gate { await gate.pause() }
        let publicKey = misrepresentCreation ? P256.Signing.PrivateKey().publicKey.x963Representation : key.publicKey.x963Representation
        misrepresentCreation = false
        return DeviceIdentityMaterial(publicKeyX963: publicKey, wrappedKey: blob)
    }
    func publicKey(for wrappedKey: Data) async throws -> Data {
        guard let key = keys[wrappedKey] else { throw DeviceIdentityFailure.unavailable(.secureKey) }
        return key.publicKey.x963Representation
    }
    func sign(_ message: Data, using wrappedKey: Data) async throws -> Data {
        signatures += 1
        guard let key = keys[wrappedKey] else { throw DeviceIdentityFailure.unavailable(.secureKey) }
        let gate = signGate; signGate = nil
        if let gate { await gate.pause() }
        switch signMode {
        case 1: throw DeviceIdentityFailure.unavailable(.secureKey)
        case 2: return Data(repeating: 0, count: 63)
        case 3: return try P256.Signing.PrivateKey().signature(for: message).rawRepresentation
        default: return try key.signature(for: message).rawRepresentation
        }
    }
}

final class DeviceIdentityTests: XCTestCase {
    private func localMessage() -> Data {
        Data([DeviceLicenceVerifier.localProofPurpose, "1", DeviceLicenceVerifier.encode(Data(repeating: 3, count: 32)),
              DeviceLicenceVerifier.encode(Data(repeating: 4, count: 32))].joined(separator: "\n").utf8)
    }
    private func approvalMessage(_ key: Data) -> Data {
        let token = DeviceLicenceVerifier.encode(Data(repeating: 1, count: 16))
        let nonce = DeviceLicenceVerifier.encode(Data(repeating: 2, count: 32))
        return Data(["cliphoard.device-approval", "1", "P256-SHA256", token, DeviceLicenceVerifier.encode(key),
                     DeviceLicenceVerifier.encode(Data(SHA256.hash(data: key))), token, nonce, "1767323045", nonce, token]
            .joined(separator: "\n").utf8)
    }
    private func failure<T>(_ expected: DeviceIdentityFailure, _ operation: () async throws -> T) async {
        do { _ = try await operation(); XCTFail("expected typed failure") }
        catch { XCTAssertEqual(error as? DeviceIdentityFailure, expected) }
    }

    func testLoadingMissingIdentityNeverCreatesAndHardwareUnavailableIsExplicit() async throws {
        let storage = DeviceIdentityTestStorage(), keys = DeviceIdentityTestKeys()
        let identity = try DeviceIdentity(storage: storage, keys: keys)
        let missing = await identity.loadExisting()
        XCTAssertEqual(missing, .failure(.missing))
        await keys.setAvailable(false)
        let unavailable = await identity.createIfAbsent()
        XCTAssertEqual(unavailable, .failure(.unavailable(.secureHardware)))
        let counts = await (keys.creations, storage.insertions, storage.reads)
        XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0); XCTAssertEqual(counts.2, 1)
    }

    func testDurableReadbackAndRecreatedClientUseSameIdentityAndP1363Proof() async throws {
        let storage = DeviceIdentityTestStorage(), keys = DeviceIdentityTestKeys()
        let first = try DeviceIdentity(storage: storage, keys: keys)
        let publicKey = try await first.createIfAbsent().get()
        let restarted = try DeviceIdentity(storage: storage, keys: keys, expectedPublicKey: publicKey)
        let recovered = try await restarted.loadExisting().get()
        XCTAssertEqual(recovered, publicKey); XCTAssertEqual(publicKey.count, 65)
        let proof = try await restarted.signLicenceProof(localMessage())
        XCTAssertEqual(proof.count, 64)
        let verifier = try P256.Signing.PublicKey(x963Representation: publicKey)
        XCTAssertTrue(verifier.isValidSignature(try .init(rawRepresentation: proof), for: localMessage()))
        let counts = await (keys.creations, storage.writes)
        XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 1)
    }

    func testUncertainInsertReadbackFailureDoesNotPublishOrCreateAnotherKeyOnRetry() async throws {
        let storage = DeviceIdentityTestStorage(), keys = DeviceIdentityTestKeys()
        await storage.failAfterInsertion()
        let identity = try DeviceIdentity(storage: storage, keys: keys)
        let failed = await identity.createIfAbsent()
        XCTAssertEqual(failed, .failure(.unavailable(.storage)))
        let known = await identity.knownPublicKey; XCTAssertNil(known)
        await storage.fail(nil)
        _ = try await identity.createIfAbsent().get()
        let counts = await (keys.creations, storage.writes)
        XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 1)
    }

    func testFailureMissingAndChangedRecordsPreserveKnownIdentityWithoutOverwrite() async throws {
        let storage = DeviceIdentityTestStorage(), keys = DeviceIdentityTestKeys()
        let identity = try DeviceIdentity(storage: storage, keys: keys)
        let known = try await identity.createIfAbsent().get()
        await storage.fail(.unavailable(.interactionRequired))
        let locked = await identity.loadExisting()
        XCTAssertEqual(locked, .failure(.unavailable(.interactionRequired)))
        await storage.fail(nil); await storage.set(nil)
        let missing = await identity.createIfAbsent(); XCTAssertEqual(missing, .failure(.missing))
        let replacement = try await keys.create()
        await storage.set(try DeviceIdentityRecord.encode(replacement))
        let changed = await identity.loadExisting(); XCTAssertEqual(changed, .failure(.identityChanged))
        let retained = await identity.knownPublicKey; XCTAssertEqual(retained, known)
        let writes = await storage.writes; XCTAssertEqual(writes, 1)
    }

    func testExpectedIdentityBlocksCreationWhenRecordIsMissingAfterRestart() async throws {
        let storage = DeviceIdentityTestStorage(), keys = DeviceIdentityTestKeys()
        let publicKey = try await keys.create().publicKeyX963
        let identity = try DeviceIdentity(storage: storage, keys: keys, expectedPublicKey: publicKey)
        let result = await identity.createIfAbsent(); XCTAssertEqual(result, .failure(.missing))
        let inserts = await storage.insertions; XCTAssertEqual(inserts, 0)
    }

    func testMalformedVersionOversizeAndWrongWrappedKeyNeverTriggerReplacement() async throws {
        let storage = DeviceIdentityTestStorage(), keys = DeviceIdentityTestKeys()
        let one = try await keys.create(), two = try await keys.create()
        let valid = try DeviceIdentityRecord.encode(one)
        let wrong = try DeviceIdentityRecord.encode(.init(publicKeyX963: one.publicKeyX963, wrappedKey: two.wrappedKey))
        var version = valid; version[DeviceIdentityRecord.prefix.count - 2] = 50
        for record in [Data(), valid + Data([0]), Data(valid.dropLast()), version,
                       Data(repeating: 1, count: DeviceIdentityRecord.maximumBytes + 1), wrong] {
            await storage.set(record)
            let identity = try DeviceIdentity(storage: storage, keys: keys)
            let result = await identity.createIfAbsent(); XCTAssertEqual(result, .failure(.invalidRecord))
            let retained = await storage.bytes; XCTAssertEqual(retained, record)
        }
        let inserts = await storage.insertions; XCTAssertEqual(inserts, 0)
    }

    func testConcurrentIndependentClientsAdoptAtomicInsertionWinner() async throws {
        let storage = DeviceIdentityTestStorage(), keys = DeviceIdentityTestKeys(), gate = DeviceIdentityTestGate()
        await keys.holdCreation(gate)
        let first = try DeviceIdentity(storage: storage, keys: keys)
        let second = try DeviceIdentity(storage: storage, keys: keys)
        let pending = Task { await first.createIfAbsent() }
        await gate.waitForEntry()
        let winner = try await second.createIfAbsent().get()
        await gate.release()
        let converged = try await pending.value.get(); XCTAssertEqual(converged, winner)
        let counts = await (keys.creations, storage.insertions, storage.writes)
        XCTAssertEqual(counts.0, 2); XCTAssertEqual(counts.1, 2); XCTAssertEqual(counts.2, 1)
    }

    func testInconsistentNewMaterialIsRejectedBeforeItCanPoisonDurableSlot() async throws {
        let storage = DeviceIdentityTestStorage(), keys = DeviceIdentityTestKeys()
        await keys.misrepresentNextCreation()
        let identity = try DeviceIdentity(storage: storage, keys: keys)
        let result = await identity.createIfAbsent(); XCTAssertEqual(result, .failure(.invalidRecord))
        let state = await (storage.insertions, storage.bytes, identity.knownPublicKey)
        XCTAssertEqual(state.0, 0); XCTAssertNil(state.1); XCTAssertNil(state.2)
    }

    func testRecordCopiedToDifferentFakeHardwareNeverCreatesReplacementKey() async throws {
        let storage = DeviceIdentityTestStorage(), originalKeys = DeviceIdentityTestKeys()
        let original = try DeviceIdentity(storage: storage, keys: originalKeys)
        let publicKey = try await original.createIfAbsent().get()
        let retainedRecord = await storage.bytes
        let otherKeys = DeviceIdentityTestKeys()
        let copied = try DeviceIdentity(storage: storage, keys: otherKeys, expectedPublicKey: publicKey)
        let result = await copied.createIfAbsent(); XCTAssertEqual(result, .failure(.unavailable(.secureKey)))
        let state = await (otherKeys.creations, storage.bytes, storage.writes)
        XCTAssertEqual(state.0, 0); XCTAssertEqual(state.1, retainedRecord); XCTAssertEqual(state.2, 1)
    }

    func testStaleSuccessOrFailureCannotReplaceNewerLoad() async throws {
        for olderFails in [false, true] {
            let storage = DeviceIdentityTestStorage(), keys = DeviceIdentityTestKeys(), gate = DeviceIdentityTestGate()
            let old = try await keys.create(), newer = try await keys.create()
            await storage.set(try DeviceIdentityRecord.encode(old))
            if olderFails { await storage.fail(.unavailable(.storage)) }
            await storage.holdRead(gate)
            let identity = try DeviceIdentity(storage: storage, keys: keys)
            let pending = Task { await identity.loadExisting() }
            await gate.waitForEntry()
            await storage.fail(nil); await storage.set(try DeviceIdentityRecord.encode(newer))
            _ = try await identity.loadExisting().get()
            await gate.release()
            let stale = await pending.value; XCTAssertEqual(stale, .failure(.superseded))
            let state = await (identity.knownPublicKey, identity.lastFailure)
            XCTAssertEqual(state.0, newer.publicKeyX963); XCTAssertNil(state.1)
        }
    }

    func testCancelDuringCreationDiscardsLateKeyBeforeInsertion() async throws {
        let storage = DeviceIdentityTestStorage(), keys = DeviceIdentityTestKeys(), gate = DeviceIdentityTestGate()
        await keys.holdCreation(gate)
        let identity = try DeviceIdentity(storage: storage, keys: keys)
        let pending = Task { await identity.createIfAbsent() }
        await gate.waitForEntry(); await identity.cancelPending(); await gate.release()
        let result = await pending.value; XCTAssertEqual(result, .failure(.superseded))
        let known = await identity.knownPublicKey, writes = await storage.writes
        XCTAssertNil(known); XCTAssertEqual(writes, 0)
    }

    func testTaskCancellationDoesNotPublishIdentity() async throws {
        let storage = DeviceIdentityTestStorage(), keys = DeviceIdentityTestKeys(), gate = DeviceIdentityTestGate()
        await keys.holdCreation(gate)
        let identity = try DeviceIdentity(storage: storage, keys: keys)
        let pending = Task { await identity.createIfAbsent() }
        await gate.waitForEntry(); pending.cancel(); await gate.release()
        let result = await pending.value; XCTAssertEqual(result, .failure(.cancelled))
        let writes = await storage.writes; XCTAssertEqual(writes, 0)
    }

    func testCancellationAfterInsertionRetainsDurableWinnerForNextLoad() async throws {
        let storage = DeviceIdentityTestStorage(), keys = DeviceIdentityTestKeys(), gate = DeviceIdentityTestGate()
        await storage.holdInsertion(gate)
        let identity = try DeviceIdentity(storage: storage, keys: keys)
        let pending = Task { await identity.createIfAbsent() }
        await gate.waitForEntry(); await identity.cancelPending(); await gate.release()
        let stale = await pending.value; XCTAssertEqual(stale, .failure(.superseded))
        _ = try await identity.loadExisting().get()
        let counts = await (keys.creations, storage.writes)
        XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 1)
    }

    func testSignerFailureWrongSignerAndWrongLengthPreserveIdentity() async throws {
        let storage = DeviceIdentityTestStorage(), keys = DeviceIdentityTestKeys()
        let identity = try DeviceIdentity(storage: storage, keys: keys)
        let known = try await identity.createIfAbsent().get()
        for mode in [1, 2, 3] {
            await keys.setSignMode(mode)
            await failure(mode == 1 ? .unavailable(.secureKey) : .invalidProof) {
                try await identity.signLicenceProof(self.localMessage())
            }
        }
        let retained = await identity.knownPublicKey; XCTAssertEqual(retained, known)
        await keys.setSignMode(0)
        let signature = try await identity.signLicenceProof(localMessage()); XCTAssertEqual(signature.count, 64)
    }

    func testLateSignatureIsDiscardedAfterCancellationWithoutErasingIdentity() async throws {
        let storage = DeviceIdentityTestStorage(), keys = DeviceIdentityTestKeys(), gate = DeviceIdentityTestGate()
        let identity = try DeviceIdentity(storage: storage, keys: keys)
        let known = try await identity.createIfAbsent().get()
        await keys.holdSignature(gate)
        let message = localMessage()
        let pending = Task { try await identity.signLicenceProof(message) }
        await gate.waitForEntry(); await identity.cancelPending(); await gate.release()
        await failure(.superseded) { try await pending.value }
        let retained = await identity.knownPublicKey; XCTAssertEqual(retained, known)
    }

    func testExactDomainBoundedProofsAndApprovalDeviceBinding() async throws {
        let storage = DeviceIdentityTestStorage(), keys = DeviceIdentityTestKeys()
        let identity = try DeviceIdentity(storage: storage, keys: keys)
        let known = try await identity.createIfAbsent().get()
        let valid = approvalMessage(known)
        _ = try await identity.signLicenceProof(valid)
        let other = P256.Signing.PrivateKey().publicKey.x963Representation
        let local = String(decoding: localMessage(), as: UTF8.self)
        let bad = [Data(), Data(repeating: 65, count: 1025), Data((local + "\n").utf8),
                   Data(local.replacingOccurrences(of: "\n1\n", with: "\n2\n").utf8),
                   Data(local.replacingOccurrences(of: "device-local-proof", with: "device-receipt").utf8),
                   approvalMessage(other)]
        for message in bad { await failure(.invalidMessage) { try await identity.signLicenceProof(message) } }
        let signatures = await keys.signatures; XCTAssertEqual(signatures, 1)
    }

    func testIdentityProviderWorksWithActualOfflineReceiptVerifier() async throws {
        let storage = DeviceIdentityTestStorage(), keys = DeviceIdentityTestKeys()
        let identity = try DeviceIdentity(storage: storage, keys: keys)
        let publicKey = try await identity.createIfAbsent().get()
        let issuer = P256.Signing.PrivateKey()
        let identifier = DeviceLicenceVerifier.encode(Data(repeating: 1, count: 16))
        let payload = Data(["cliphoard.device-receipt", "1", "P256-SHA256", "synthetic-identity",
                            identifier, DeviceLicenceVerifier.encode(Data(SHA256.hash(data: publicKey))),
                            identifier, "1767323045", "pro", "perpetual"].joined(separator: "\n").utf8)
        let signature = try issuer.signature(for: payload).rawRepresentation
        let envelope = "CLIPD1.\(DeviceLicenceVerifier.encode(payload)).\(DeviceLicenceVerifier.encode(signature))"
        let receipt = try await DeviceLicenceVerifier.verify(envelope, using: identity,
            trustedIssuers: ["synthetic-identity": issuer.publicKey.x963Representation]).get()
        XCTAssertEqual(receipt.deviceKeyHash, DeviceLicenceVerifier.encode(Data(SHA256.hash(data: publicKey))))
        await keys.setSignMode(1)
        let failed = await DeviceLicenceVerifier.verify(envelope, using: identity,
            trustedIssuers: ["synthetic-identity": issuer.publicKey.x963Representation])
        XCTAssertEqual(failed, .failure(.keyUnavailable))
        let retained = await identity.knownPublicKey; XCTAssertEqual(retained, publicKey)
    }
}
#endif
