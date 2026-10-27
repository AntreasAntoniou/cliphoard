#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE
import XCTest
import CryptoKit
import Foundation
@testable import Cliphoard

actor ReceiptIdentityStore: DeviceIdentityStorage {
    var bytes: Data?
    func read() async throws -> Data? { bytes }
    func insertIfAbsent(_ record: Data) async throws -> Bool {
        guard bytes == nil else { return false }; bytes = record; return true
    }
    func removeForTest() { bytes = nil }
}
actor ReceiptIdentityKeys: DeviceIdentityKeyOperations {
    let key = P256.Signing.PrivateKey()
    var signatures = 0
    var unavailable = false
    func isAvailable() async -> Bool { !unavailable }
    func create() async throws -> DeviceIdentityMaterial {
        DeviceIdentityMaterial(publicKeyX963: key.publicKey.x963Representation, wrappedKey: Data([42]))
    }
    func publicKey(for wrappedKey: Data) async throws -> Data {
        guard wrappedKey == Data([42]) else { throw DeviceIdentityFailure.invalidRecord }
        return key.publicKey.x963Representation
    }
    func sign(_ message: Data, using wrappedKey: Data) async throws -> Data {
        signatures += 1; return try key.signature(for: message).rawRepresentation
    }
    func setUnavailable() { unavailable = true }
}
struct ReceiptRecoveryFixture {
    let issuer = P256.Signing.PrivateKey()
    let store = ReceiptIdentityStore()
    let keys = ReceiptIdentityKeys()
    let entitlement = "AQEBAQEBAQEBAQEBAQEBAQ"
    func identity() throws -> DeviceIdentity { try DeviceIdentity(storage: store, keys: keys) }
    func bindings(_ publicKey: Data) -> DeviceLicenceRecoveryBindings {
        .init(issuerKeyID: "synthetic-recovery", issuerPublicKey: issuer.publicKey.x963Representation,
              entitlementID: entitlement, devicePublicKey: publicKey)
    }
    func envelope(_ publicKey: Data, receiptByte: UInt8 = 2, entitlementID: String? = nil) throws -> String {
        let payload = Data(["cliphoard.device-receipt", "1", "P256-SHA256", "synthetic-recovery",
            entitlementID ?? entitlement, DeviceLicenceVerifier.encode(Data(SHA256.hash(data: publicKey))),
            DeviceLicenceVerifier.encode(Data(repeating: receiptByte, count: 16)), "1767323045", "pro", "perpetual"]
            .joined(separator: "\n").utf8)
        return "CLIPD1.\(DeviceLicenceVerifier.encode(payload)).\(DeviceLicenceVerifier.encode(try issuer.signature(for: payload).rawRepresentation))"
    }
}

actor ReceiptRecoveryGate {
    nonisolated let entered = XCTestExpectation(description: "storage boundary entered")
    var continuation: CheckedContinuation<Void, Never>?
    var released = false
    func pause() async {
        entered.fulfill()
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
actor ReceiptControlledStorage: DeviceLicenceReceiptStorage {
    let base: any DeviceLicenceReceiptStorage
    var beforeWrite: ReceiptRecoveryGate?
    var afterWrite: ReceiptRecoveryGate?
    var failRead = false
    init(_ base: any DeviceLicenceReceiptStorage) { self.base = base }
    func holdNextWrite(_ gate: ReceiptRecoveryGate, after: Bool = false) {
        if after { afterWrite = gate } else { beforeWrite = gate }
    }
    func setReadFailure() { failRead = true }
    func read() async throws -> DeviceLicenceReceiptSnapshot {
        if failRead { throw DeviceLicenceReceiptStorageFailure.io }
        return try await base.read()
    }
    func replace(_ envelope: String, expectedRevision: Data?, permit: DeviceLicenceReceiptPermit)
        async throws -> DeviceLicenceReceiptSnapshot {
        let before = beforeWrite, after = afterWrite; beforeWrite = nil; afterWrite = nil
        if let before { await before.pause() }
        let result = try await base.replace(envelope, expectedRevision: expectedRevision, permit: permit)
        if let after { await after.pause() }
        return result
    }
}

final class DeviceLicenceRecoveryTests: XCTestCase {
    func testRelaunchReverifiesStoredEnvelopeWithFreshPossession() async throws {
        let root = try receiptTestDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("approved.receipt"), fixture = ReceiptRecoveryFixture()
        let identity = try fixture.identity(), key = try await identity.createIfAbsent().get()
        let envelope = try fixture.envelope(key)
        let first = try DeviceLicenceRecovery(storage: DeviceLicenceReceiptRepository(fileURL: file),
                                              identity: identity, bindings: fixture.bindings(key))
        let approved = try await first.accept(envelope).get()
        let before = await fixture.keys.signatures
        let restarted = try DeviceLicenceRecovery(storage: DeviceLicenceReceiptRepository(fileURL: file),
                                                  identity: fixture.identity(), bindings: fixture.bindings(key))
        let restored = try await restarted.restore().get()
        XCTAssertEqual(restored, approved)
        let after = await fixture.keys.signatures; XCTAssertGreaterThan(after, before)
    }

    func testWrongEntitlementImportPreservesApprovedBytesAndState() async throws {
        let root = try receiptTestDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("approved.receipt"), fixture = ReceiptRecoveryFixture()
        let identity = try fixture.identity(), key = try await identity.createIfAbsent().get()
        let coordinator = try DeviceLicenceRecovery(storage: DeviceLicenceReceiptRepository(fileURL: file),
                                                    identity: identity, bindings: fixture.bindings(key))
        let approved = try await coordinator.accept(fixture.envelope(key)).get()
        let before = try Data(contentsOf: file)
        let result = await coordinator.accept(try fixture.envelope(key, entitlementID: "AgICAgICAgICAgICAgICAg"))
        XCTAssertEqual(result, .failure(.bindingMismatch))
        XCTAssertEqual(try Data(contentsOf: file), before)
        let retained = await coordinator.receipt; XCTAssertEqual(retained, approved)
    }

    func testInvalidOversizedWrongDeviceAndWrongSignerImportsPreserveBytes() async throws {
        let root = try receiptTestDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("approved.receipt"), fixture = ReceiptRecoveryFixture()
        let identity = try fixture.identity(), key = try await identity.createIfAbsent().get()
        let coordinator = try DeviceLicenceRecovery(storage: DeviceLicenceReceiptRepository(fileURL: file),
                                                    identity: identity, bindings: fixture.bindings(key))
        let approved = try await coordinator.accept(fixture.envelope(key)).get()
        let bytes = try Data(contentsOf: file)
        let otherKey = P256.Signing.PrivateKey().publicKey.x963Representation
        let imports: [(String, DeviceLicenceFailure)] = [
            ("CLIP1.unchanged-legacy-path", .malformed), (String(repeating: "A", count: 1025), .malformed),
            (try fixture.envelope(otherKey), .wrongDevice),
            (try ReceiptRecoveryFixture().envelope(key), .invalidSignature)]
        for (envelope, failure) in imports {
            let result = await coordinator.accept(envelope)
            XCTAssertEqual(result, .failure(.verification(failure)))
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
        let retained = await coordinator.receipt; XCTAssertEqual(retained, approved)
    }

    func testRecoveryRequiresExactCallerBindings() async throws {
        let root = try receiptTestDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("approved.receipt"), fixture = ReceiptRecoveryFixture()
        let identity = try fixture.identity(), key = try await identity.createIfAbsent().get()
        let repository = try DeviceLicenceReceiptRepository(fileURL: file), good = fixture.bindings(key)
        _ = try await DeviceLicenceRecovery(storage: repository, identity: identity, bindings: good)
            .accept(fixture.envelope(key)).get()
        let bytes = try Data(contentsOf: file), other = P256.Signing.PrivateKey().publicKey.x963Representation
        let wrong: [(DeviceLicenceRecoveryBindings, DeviceLicenceRecoveryFailure)] = [
            (.init(issuerKeyID: good.issuerKeyID, issuerPublicKey: good.issuerPublicKey,
                   entitlementID: good.entitlementID, devicePublicKey: other), .bindingMismatch),
            (.init(issuerKeyID: good.issuerKeyID, issuerPublicKey: other,
                   entitlementID: good.entitlementID, devicePublicKey: key), .verification(.invalidSignature)),
            (.init(issuerKeyID: good.issuerKeyID, issuerPublicKey: good.issuerPublicKey,
                   entitlementID: "AgICAgICAgICAgICAgICAg", devicePublicKey: key), .bindingMismatch)]
        for (binding, failure) in wrong {
            let restarted = try DeviceLicenceRecovery(storage: repository, identity: fixture.identity(), bindings: binding)
            let result = await restarted.restore(); XCTAssertEqual(result, .failure(failure))
            let published = await restarted.receipt; XCTAssertNil(published)
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    func testMissingIdentityDoesNotCreateAReplacementOrEraseReceipt() async throws {
        let root = try receiptTestDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("approved.receipt"), fixture = ReceiptRecoveryFixture()
        let identity = try fixture.identity(), key = try await identity.createIfAbsent().get()
        let repository = try DeviceLicenceReceiptRepository(fileURL: file)
        _ = try await DeviceLicenceRecovery(storage: repository, identity: identity, bindings: fixture.bindings(key))
            .accept(fixture.envelope(key)).get()
        let bytes = try Data(contentsOf: file); await fixture.store.removeForTest()
        let restarted = try DeviceLicenceRecovery(storage: repository, identity: fixture.identity(), bindings: fixture.bindings(key))
        let result = await restarted.restore(); XCTAssertEqual(result, .failure(.identity(.missing)))
        let persistedKey = try await fixture.store.read(); XCTAssertNil(persistedKey)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testHardwareOrReadOutagePreservesVerifiedStateAndBytes() async throws {
        let root = try receiptTestDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("approved.receipt"), fixture = ReceiptRecoveryFixture()
        let identity = try fixture.identity(), key = try await identity.createIfAbsent().get()
        let storage = ReceiptControlledStorage(try DeviceLicenceReceiptRepository(fileURL: file))
        let coordinator = try DeviceLicenceRecovery(storage: storage, identity: identity, bindings: fixture.bindings(key))
        let approved = try await coordinator.accept(fixture.envelope(key)).get(), bytes = try Data(contentsOf: file)
        await fixture.keys.setUnavailable()
        let hardware = await coordinator.restore(); XCTAssertEqual(hardware, .failure(.identity(.unavailable(.secureHardware))))
        await storage.setReadFailure()
        let read = await coordinator.restore(); XCTAssertEqual(read, .failure(.storage(.io)))
        let retained = await coordinator.receipt; XCTAssertEqual(retained, approved)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testSemanticallyCorruptPriorEnvelopeIsNeverRepairedByImport() async throws {
        let root = try receiptTestDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("approved.receipt"), fixture = ReceiptRecoveryFixture()
        let identity = try fixture.identity(), key = try await identity.createIfAbsent().get()
        let repository = try DeviceLicenceReceiptRepository(fileURL: file)
        _ = try await repository.replace("CLIPD1.YQ.Yg", expectedRevision: nil, permit: .init())
        let bytes = try Data(contentsOf: file)
        let coordinator = try DeviceLicenceRecovery(storage: repository, identity: identity, bindings: fixture.bindings(key))
        let result = await coordinator.accept(try fixture.envelope(key))
        XCTAssertEqual(result, .failure(.verification(.malformed)))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testDuplicateImportReprovesPossessionWithoutRewritingRecord() async throws {
        let root = try receiptTestDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("approved.receipt"), fixture = ReceiptRecoveryFixture()
        let identity = try fixture.identity(), key = try await identity.createIfAbsent().get()
        let coordinator = try DeviceLicenceRecovery(storage: DeviceLicenceReceiptRepository(fileURL: file),
                                                    identity: identity, bindings: fixture.bindings(key))
        let envelope = try fixture.envelope(key), approved = try await coordinator.accept(envelope).get()
        let bytes = try Data(contentsOf: file), before = await fixture.keys.signatures
        let duplicate = try await coordinator.accept(envelope).get()
        let after = await fixture.keys.signatures
        XCTAssertEqual(duplicate, approved); XCTAssertGreaterThan(after, before)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testNewerFailedImportStillFencesOlderAwaitingCommit() async throws {
        let root = try receiptTestDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("approved.receipt"), fixture = ReceiptRecoveryFixture()
        let identity = try fixture.identity(), key = try await identity.createIfAbsent().get()
        let storage = ReceiptControlledStorage(try DeviceLicenceReceiptRepository(fileURL: file))
        let coordinator = try DeviceLicenceRecovery(storage: storage, identity: identity, bindings: fixture.bindings(key))
        let approved = try await coordinator.accept(fixture.envelope(key)).get(), bytes = try Data(contentsOf: file)
        let gate = ReceiptRecoveryGate(); await storage.holdNextWrite(gate)
        let older = Task { await coordinator.accept(try fixture.envelope(key, receiptByte: 3)) }
        await fulfillment(of: [gate.entered], timeout: 3)
        let invalid = await coordinator.accept("CLIPD1.invalid.value")
        XCTAssertEqual(invalid, .failure(.verification(.malformed)))
        await gate.release()
        let stale = try await older.value; XCTAssertEqual(stale, .failure(.superseded))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let retained = await coordinator.receipt; XCTAssertEqual(retained, approved)
    }

    func testNewerValidImportWinsOverDelayedCommit() async throws {
        let root = try receiptTestDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("approved.receipt"), fixture = ReceiptRecoveryFixture()
        let identity = try fixture.identity(), key = try await identity.createIfAbsent().get()
        let repository = try DeviceLicenceReceiptRepository(fileURL: file), storage = ReceiptControlledStorage(repository)
        let coordinator = try DeviceLicenceRecovery(storage: storage, identity: identity, bindings: fixture.bindings(key))
        _ = try await coordinator.accept(fixture.envelope(key)).get()
        let gate = ReceiptRecoveryGate(); await storage.holdNextWrite(gate)
        let older = Task { await coordinator.accept(try fixture.envelope(key, receiptByte: 3)) }
        await fulfillment(of: [gate.entered], timeout: 3)
        let newestEnvelope = try fixture.envelope(key, receiptByte: 4)
        let newest = try await coordinator.accept(newestEnvelope).get()
        await gate.release()
        let stale = try await older.value; XCTAssertEqual(stale, .failure(.superseded))
        let durable = try await repository.read(); XCTAssertEqual(durable.envelope, newestEnvelope)
        let retained = await coordinator.receipt; XCTAssertEqual(retained, newest)
    }

    func testTaskCancellationBeforeCommitPreservesPriorBytes() async throws {
        let root = try receiptTestDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("approved.receipt"), fixture = ReceiptRecoveryFixture()
        let identity = try fixture.identity(), key = try await identity.createIfAbsent().get()
        let storage = ReceiptControlledStorage(try DeviceLicenceReceiptRepository(fileURL: file))
        let coordinator = try DeviceLicenceRecovery(storage: storage, identity: identity, bindings: fixture.bindings(key))
        let approved = try await coordinator.accept(fixture.envelope(key)).get(), bytes = try Data(contentsOf: file)
        let gate = ReceiptRecoveryGate(); await storage.holdNextWrite(gate)
        let pending = Task { await coordinator.accept(try fixture.envelope(key, receiptByte: 3)) }
        await fulfillment(of: [gate.entered], timeout: 3); pending.cancel(); await gate.release()
        let result = try await pending.value; XCTAssertEqual(result, .failure(.cancelled))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let retained = await coordinator.receipt; XCTAssertEqual(retained, approved)
    }

    func testCancellationAfterCommitDoesNotRollBackAndRelaunchRecoversIt() async throws {
        let root = try receiptTestDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("approved.receipt"), fixture = ReceiptRecoveryFixture()
        let identity = try fixture.identity(), key = try await identity.createIfAbsent().get()
        let repository = try DeviceLicenceReceiptRepository(fileURL: file), storage = ReceiptControlledStorage(repository)
        let coordinator = try DeviceLicenceRecovery(storage: storage, identity: identity, bindings: fixture.bindings(key))
        let approved = try await coordinator.accept(fixture.envelope(key)).get()
        let gate = ReceiptRecoveryGate(); await storage.holdNextWrite(gate, after: true)
        let newerEnvelope = try fixture.envelope(key, receiptByte: 3)
        let pending = Task { await coordinator.accept(newerEnvelope) }
        await fulfillment(of: [gate.entered], timeout: 3); await coordinator.cancelPending(); await gate.release()
        let result = await pending.value; XCTAssertEqual(result, .failure(.superseded))
        let retained = await coordinator.receipt; XCTAssertEqual(retained, approved)
        let durable = try await repository.read(); XCTAssertEqual(durable.envelope, newerEnvelope)
        let relaunched = try DeviceLicenceRecovery(storage: repository, identity: fixture.identity(), bindings: fixture.bindings(key))
        let recovered = try await relaunched.restore().get(); XCTAssertNotEqual(recovered, approved)
    }

    func testUncertainWriteDoesNotPublishButAllowsExplicitRecovery() async throws {
        let root = try receiptTestDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("approved.receipt"), fixture = ReceiptRecoveryFixture()
        let identity = try fixture.identity(), key = try await identity.createIfAbsent().get()
        let native = try DeviceLicenceReceiptRepository(fileURL: file)
        _ = try await DeviceLicenceRecovery(storage: native, identity: identity, bindings: fixture.bindings(key))
            .accept(fixture.envelope(key)).get()
        let uncertain = try DeviceLicenceReceiptRepository(fileURL: file, io: ReceiptFaultIO(.directorySync))
        let coordinator = try DeviceLicenceRecovery(storage: uncertain, identity: identity, bindings: fixture.bindings(key))
        let previous = try await coordinator.restore().get()
        let newer = try fixture.envelope(key, receiptByte: 3)
        let result = await coordinator.accept(newer); XCTAssertEqual(result, .failure(.storage(.commitUncertain)))
        let retained = await coordinator.receipt; XCTAssertEqual(retained, previous)
        let recovered = try await coordinator.restore().get(); XCTAssertNotEqual(recovered, previous)
    }
}
#endif
