#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE && !APP_STORE
import XCTest
import CryptoKit
import Foundation
import Security
import Combine
import LocalAuthentication
@testable import Cliphoard

// Synthetic in-memory descriptors only; no identity, native storage or transport.
private struct DirectOwnerFixture {
    let signer = P256.Signing.PrivateKey(), issuer = P256.Signing.PrivateKey()
    func profile() throws -> DeviceLicenceBootstrapTrustProfile {
        try .init(profileID: "owner-test", bootstrapKeyID: "owner-bootstrap",
            bootstrapPublicKey: signer.publicKey.x963Representation,
            receiptIssuers: ["owner-receipt": issuer.publicKey.x963Representation])
    }
    func envelope(entitlement: UInt8 = 6, handle: UInt8 = 7) throws -> String {
        let bytes = Data(["cliphoard.device-bootstrap", "1", "P256-SHA256", "owner-bootstrap",
            "owner-test", "owner-receipt", DeviceLicenceVerifier.encode(Data(repeating: entitlement, count: 16)),
            DeviceLicenceVerifier.encode(Data(repeating: handle, count: 32)), "1767323045", "pro"].joined(separator: "\n").utf8)
        return "CLIPB1.\(DeviceLicenceVerifier.encode(bytes)).\(DeviceLicenceVerifier.encode(try signer.signature(for: bytes).rawRepresentation))"
    }
    func configuration() throws -> DeviceLicenceDirectApplicationConfiguration {
        try .init(origin: URL(string: "https://licence.invalid")!, expectedDevicePublicKey: nil,
            receiptFileURL: URL(fileURLWithPath: "/synthetic-only/owner/receipt.clipd1"),
            identityKeychainService: "synthetic.owner", identityKeychainAccount: "synthetic-account",
            resourceTimeout: 5)
    }
}
private actor DirectOwnerGate {
    private var entered = false, released = false
    private var entry: CheckedContinuation<Void, Never>?, exit: CheckedContinuation<Void, Never>?
    func pause() async { entered = true; entry?.resume(); entry = nil; if !released { await withCheckedContinuation { exit = $0 } } }
    func wait() async { if !entered { await withCheckedContinuation { entry = $0 } } }
    func release() { released = true; exit?.resume(); exit = nil }
}
private actor DirectOwnerStorage: DeviceLicenceBootstrapSecureStorage {
    enum Fault: Equatable { case none, read, insertBefore, insertAfter, mismatchedReadback, absentReadback }
    private var bytes: Data?, fault: Fault = .none, reads = 0, insertions = 0
    private var insertGate: DirectOwnerGate?
    init(_ envelope: String? = nil) { bytes = envelope.map { Data($0.utf8) } }
    func set(_ value: Fault) { fault = value }
    func holdInsert(_ value: DirectOwnerGate) { insertGate = value }
    func counts() -> (Int, Int) { (reads, insertions) }
    func raw() -> Data? { bytes }
    func read() async throws -> Data? {
        reads += 1
        if fault == .read { throw NSError(domain: "PRIVATE-STORAGE-DETAIL", code: 1) }
        if insertions > 0, fault == .mismatchedReadback { return Data("untrusted".utf8) }
        if insertions > 0, fault == .absentReadback { return nil }
        return bytes
    }
    func insertIfAbsent(_ record: Data) async throws -> Bool {
        insertions += 1
        if fault == .insertBefore { throw NSError(domain: "PRIVATE-STORAGE-DETAIL", code: 2) }
        if let gate = insertGate { insertGate = nil; await gate.pause() }
        guard bytes == nil else { return false }; bytes = Data(Array(record))
        if fault == .insertAfter { throw NSError(domain: "PRIVATE-STORAGE-DETAIL", code: 3) }
        return true
    }
}
@MainActor
private final class DirectOwnerSession: DeviceLicenceDirectOwnedSession {
    private var phase: DeviceLicenceApplicationLifecycle = .idle
    var onLifecycleRead: (() -> Void)?
    var lifecycle: DeviceLicenceApplicationLifecycle { let captured = phase; onLifecycleRead?(); return captured }
    private(set) var starts = 0, stops = 0, opens = 0, closes = 0
    var onStart: (() -> Void)?
    func start() -> Task<Void, Never>? { starts += 1; phase = .running; onStart?(); return nil }
    func stop() { stops += 1; phase = .stopped }
    func openPanel() { opens += 1 }
    func closePanel() { closes += 1 }
}
@MainActor
private final class DirectOwnerFactory {
    var sessions: [DirectOwnerSession] = [], fail = false
    var onMake: (() -> Void)?, onStart: (() -> Void)?
    func make(_ configuration: DeviceLicenceBootstrapApplicationConfiguration) throws -> any DeviceLicenceDirectOwnedSession {
        if fail { throw NSError(domain: "PRIVATE-FACTORY-DETAIL", code: 1) }
        let result = DirectOwnerSession(); result.onStart = onStart; sessions.append(result); onMake?(); return result
    }
}
@MainActor
final class DeviceLicenceDirectApplicationOwnerTests: XCTestCase {
    private func make(_ fixture: DirectOwnerFixture, _ storage: DirectOwnerStorage, _ factory: DirectOwnerFactory)
        throws -> DeviceLicenceDirectApplicationOwner {
        let repository = DeviceLicenceBootstrapRepository(profile: try fixture.profile(), storage: storage)
        return DeviceLicenceDirectApplicationOwner(repository: repository, configuration: try fixture.configuration(), makeSession: factory.make)
    }
    func testConstructionIsInertAndMissingRestoreDoesNotMakeSession() async throws {
        let f = DirectOwnerFixture(), storage = DirectOwnerStorage(), factory = DirectOwnerFactory()
        let owner = try make(f, storage, factory)
        let before = await storage.counts(); XCTAssertEqual(before.0, 0); XCTAssertEqual(before.1, 0)
        XCTAssertEqual(owner.state, .idle); XCTAssertFalse(owner.hasSession)
        let restored = try await owner.restoreSavedBootstrap(); XCTAssertFalse(restored)
        XCTAssertTrue(factory.sessions.isEmpty); XCTAssertEqual(owner.state, .idle)
    }
    func testImportPersistsReadbackAndStartsExactlyOneSession() async throws {
        let f = DirectOwnerFixture(), storage = DirectOwnerStorage(), factory = DirectOwnerFactory(), envelope = try f.envelope()
        let owner = try make(f, storage, factory)
        try await owner.importBootstrap(envelope)
        let counts = await storage.counts(); XCTAssertGreaterThanOrEqual(counts.0, 2); XCTAssertEqual(counts.1, 1)
        XCTAssertEqual(factory.sessions.count, 1); XCTAssertEqual(factory.sessions[0].starts, 1)
        XCTAssertTrue(owner.hasSession); XCTAssertEqual(owner.state, .ready)
        let persisted = await storage.raw(); XCTAssertEqual(persisted, Data(envelope.utf8))
        owner.openPanel(); owner.closePanel()
        XCTAssertEqual(factory.sessions[0].opens, 1); XCTAssertEqual(factory.sessions[0].closes, 1)
    }
    func testExactImportAndRestoreAreIdempotent() async throws {
        let f = DirectOwnerFixture(), storage = DirectOwnerStorage(), factory = DirectOwnerFactory(), envelope = try f.envelope()
        let owner = try make(f, storage, factory); try await owner.importBootstrap(envelope)
        let initial = await storage.counts()
        try await owner.importBootstrap(envelope); let restored = try await owner.restoreSavedBootstrap(); XCTAssertTrue(restored)
        let final = await storage.counts(); XCTAssertEqual(initial.0, final.0); XCTAssertEqual(initial.1, final.1)
        XCTAssertEqual(factory.sessions.count, 1); XCTAssertEqual(factory.sessions[0].starts, 1)
    }
    func testBadImportAndConflictingScopePreserveCurrentSession() async throws {
        let f = DirectOwnerFixture(), storage = DirectOwnerStorage(), factory = DirectOwnerFactory(), envelope = try f.envelope()
        let owner = try make(f, storage, factory); try await owner.importBootstrap(envelope)
        let before = await storage.counts()
        for candidate in ["bad", try f.envelope(entitlement: 9), try f.envelope(handle: 8)] {
            do { try await owner.importBootstrap(candidate); XCTFail("accepted invalid/conflicting import") } catch {}
            XCTAssertTrue(owner.hasSession); XCTAssertEqual(owner.state, .ready)
        }
        let after = await storage.counts(); XCTAssertEqual(before.0, after.0); XCTAssertEqual(before.1, after.1)
        XCTAssertEqual(factory.sessions.count, 1); XCTAssertEqual(factory.sessions[0].stops, 0)
    }
    func testInvalidDescriptorHasNoStorageOrFactoryEffects() async throws {
        let f = DirectOwnerFixture(), storage = DirectOwnerStorage(), factory = DirectOwnerFactory()
        let owner = try make(f, storage, factory)
        do { try await owner.importBootstrap("CLIPB1.secret.invalid"); XCTFail("accepted malformed") }
        catch { XCTAssertEqual(error as? DeviceLicenceDirectApplicationFailure, .invalidBootstrap) }
        let counts = await storage.counts(); XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0)
        XCTAssertTrue(factory.sessions.isEmpty); XCTAssertEqual(owner.state, .idle)
    }
    func testStorageFailuresBeforeAndAfterInsertNeverStartSessionAndCanRecover() async throws {
        for fault in [DirectOwnerStorage.Fault.read, .insertBefore, .insertAfter, .mismatchedReadback, .absentReadback] {
            let f = DirectOwnerFixture(), storage = DirectOwnerStorage(), factory = DirectOwnerFactory(), envelope = try f.envelope()
            let owner = try make(f, storage, factory); await storage.set(fault)
            do { try await owner.importBootstrap(envelope); XCTFail("ignored storage fault") } catch {}
            XCTAssertFalse(owner.hasSession); XCTAssertEqual(owner.state, .idle); XCTAssertTrue(factory.sessions.isEmpty)
            await storage.set(.none); try await owner.importBootstrap(envelope)
            XCTAssertEqual(factory.sessions.count, 1)
        }
    }
    func testExistingConflictingOrCorruptStorageCannotBeOverwritten() async throws {
        let f = DirectOwnerFixture()
        for saved in [try f.envelope(entitlement: 9), "corrupt"] {
            let storage = DirectOwnerStorage(saved), factory = DirectOwnerFactory(), owner = try make(f, storage, factory)
            do { try await owner.importBootstrap(f.envelope()); XCTFail("overwrote original") } catch {}
            let persisted = await storage.raw(); XCTAssertEqual(persisted, Data(saved.utf8))
            let counts = await storage.counts(); XCTAssertEqual(counts.1, 0); XCTAssertTrue(factory.sessions.isEmpty)
        }
    }
    func testSavedDescriptorRestoresOneNewOwnerWithoutInsert() async throws {
        let f = DirectOwnerFixture(), envelope = try f.envelope(), storage = DirectOwnerStorage(try f.envelope()), factory = DirectOwnerFactory()
        // Use one exact saved descriptor, never assume ECDSA signatures are identical.
        let exactStorage = DirectOwnerStorage(envelope), owner = try make(f, exactStorage, factory)
        let restored = try await owner.restoreSavedBootstrap(); XCTAssertTrue(restored); XCTAssertEqual(factory.sessions.count, 1)
        let counts = await exactStorage.counts(); XCTAssertEqual(counts.1, 0)
        _ = storage
    }
    func testFactoryFailureDoesNotEraseCommittedBootstrapAndRetryIsPossible() async throws {
        let f = DirectOwnerFixture(), storage = DirectOwnerStorage(), factory = DirectOwnerFactory(), envelope = try f.envelope()
        factory.fail = true; let owner = try make(f, storage, factory)
        do { try await owner.importBootstrap(envelope); XCTFail("ignored factory failure") }
        catch { XCTAssertEqual(error as? DeviceLicenceDirectApplicationFailure, .sessionUnavailable) }
        let persisted = await storage.raw(); XCTAssertEqual(persisted, Data(envelope.utf8)); XCTAssertFalse(owner.hasSession)
        factory.fail = false; let restored = try await owner.restoreSavedBootstrap(); XCTAssertTrue(restored); XCTAssertEqual(factory.sessions.count, 1)
    }
    func testConcurrentImportIsBusyAndStopDuringWritePreventsLateSession() async throws {
        let f = DirectOwnerFixture(), storage = DirectOwnerStorage(), factory = DirectOwnerFactory(), gate = DirectOwnerGate(), envelope = try f.envelope()
        await storage.holdInsert(gate); let owner = try make(f, storage, factory)
        let task = Task { try await owner.importBootstrap(envelope) }; await gate.wait()
        do { try await owner.importBootstrap(envelope); XCTFail("accepted concurrent import") }
        catch { XCTAssertEqual(error as? DeviceLicenceDirectApplicationFailure, .busy) }
        owner.stop(); await gate.release()
        do { try await task.value; XCTFail("started after stop") } catch {}
        XCTAssertEqual(owner.state, .stopped); XCTAssertFalse(owner.hasSession); XCTAssertTrue(factory.sessions.isEmpty)
    }
    func testLifecycleGetterStopFencesCandidateBeforeStart() async throws {
        let f = DirectOwnerFixture(), storage = DirectOwnerStorage(), factory = DirectOwnerFactory()
        let owner = try make(f, storage, factory)
        factory.onMake = { factory.sessions.last?.onLifecycleRead = { owner.stop() } }
        do { try await owner.importBootstrap(f.envelope()); XCTFail("ignored getter stop") } catch {}
        XCTAssertEqual(factory.sessions.count, 1)
        XCTAssertEqual(factory.sessions[0].starts, 0)
        XCTAssertEqual(factory.sessions[0].stops, 1)
        XCTAssertEqual(owner.state, .stopped); XCTAssertFalse(owner.hasSession)
    }
    func testReentrantFactoryStopDiscardsUnstartedCandidate() async throws {
        let f = DirectOwnerFixture(), storage = DirectOwnerStorage(), factory = DirectOwnerFactory()
        let owner = try make(f, storage, factory); factory.onMake = { owner.stop() }
        do { try await owner.importBootstrap(f.envelope()); XCTFail("ignored reentrant stop") } catch {}
        XCTAssertEqual(factory.sessions.count, 1); XCTAssertEqual(factory.sessions[0].starts, 0); XCTAssertEqual(factory.sessions[0].stops, 1)
        XCTAssertEqual(owner.state, .stopped); XCTAssertFalse(owner.hasSession)
    }
    func testReentrantStartStopDoesNotPublishReadyOrStartAnotherSession() async throws {
        let f = DirectOwnerFixture(), storage = DirectOwnerStorage(), factory = DirectOwnerFactory()
        let owner = try make(f, storage, factory); factory.onStart = { owner.stop() }
        do { try await owner.importBootstrap(f.envelope()); XCTFail("ignored reentrant stop") } catch {}
        XCTAssertEqual(factory.sessions.count, 1); XCTAssertEqual(factory.sessions[0].starts, 1); XCTAssertEqual(factory.sessions[0].stops, 1)
        XCTAssertEqual(owner.state, .stopped); XCTAssertFalse(owner.hasSession)
    }
    func testStopIsTerminalAndDoesNotDiscardOrRewriteStoredBootstrap() async throws {
        let f = DirectOwnerFixture(), storage = DirectOwnerStorage(), factory = DirectOwnerFactory(), envelope = try f.envelope()
        let owner = try make(f, storage, factory); try await owner.importBootstrap(envelope)
        owner.stop(); owner.stop(); owner.openPanel(); owner.closePanel()
        do { _ = try await owner.restoreSavedBootstrap(); XCTFail("restored stopped owner") } catch {}
        do { try await owner.importBootstrap(envelope); XCTFail("imported stopped owner") } catch {}
        XCTAssertEqual(factory.sessions[0].stops, 1); XCTAssertEqual(factory.sessions.count, 1)
        let persisted = await storage.raw(); XCTAssertEqual(persisted, Data(envelope.utf8)); XCTAssertEqual(owner.state, .stopped)
    }
    func testPublicationStopAtWorkingFencesStorageBeforeAnyEffect() async throws {
        let f = DirectOwnerFixture(), storage = DirectOwnerStorage(), factory = DirectOwnerFactory()
        let owner = try make(f, storage, factory)
        let observation = owner.$state.sink { state in if state == .working { owner.stop() } }
        do { try await owner.importBootstrap(f.envelope()); XCTFail("ignored publication stop") } catch {}
        let counts = await storage.counts(); XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0)
        XCTAssertEqual(owner.state, .stopped); XCTAssertFalse(owner.hasSession); XCTAssertTrue(factory.sessions.isEmpty)
        withExtendedLifetime(observation) {}
    }
    func testPublicationStopAtReadyCannotOverwriteTerminalProjection() async throws {
        let f = DirectOwnerFixture(), storage = DirectOwnerStorage(), factory = DirectOwnerFactory()
        let owner = try make(f, storage, factory)
        let observation = owner.$state.sink { state in if state == .ready { owner.stop() } }
        do { try await owner.importBootstrap(f.envelope()); XCTFail("ignored publication stop") } catch {}
        XCTAssertEqual(owner.state, .stopped); XCTAssertFalse(owner.hasSession)
        XCTAssertEqual(factory.sessions.count, 1); XCTAssertEqual(factory.sessions[0].stops, 1)
        withExtendedLifetime(observation) {}
    }
    func testNativeFakeKeychainBindingsAreInsertOnlyAndExplicitlyDeviceLocal() async throws {
        let calls = OwnerRecordingKeychainCalls(), storage = try DeviceLicenceBootstrapKeychainStorage(service: "synthetic.bootstrap", account: "record", calls: calls)
        let missing = try await storage.read(); XCTAssertNil(missing)
        let inserted = try await storage.insertIfAbsent(Data("synthetic-only".utf8)); XCTAssertTrue(inserted)
        calls.setDuplicate(); let duplicate = try await storage.insertIfAbsent(Data("synthetic-only".utf8)); XCTAssertFalse(duplicate)
        let queries = calls.snapshot(); XCTAssertEqual(queries.count, 3)
        for query in queries {
            XCTAssertEqual(query[kSecAttrService as String] as? String, "synthetic.bootstrap")
            XCTAssertEqual(query[kSecAttrAccount as String] as? String, "record")
            XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
            XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
            XCTAssertTrue((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
            XCTAssertNil(query[kSecAttrAccessGroup as String])
        }
        XCTAssertEqual(queries[1][kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertThrowsError(try DeviceLicenceBootstrapKeychainStorage(service: "", account: "record", calls: calls))
        XCTAssertThrowsError(try DeviceLicenceBootstrapKeychainStorage(service: "ok", account: "bad scope", calls: calls))
    }
    func testConfigurationRejectsUnpinnedUnsafeScopeAndDescriptionsAreSanitized() async throws {
        let f = DirectOwnerFixture()
        XCTAssertThrowsError(try DeviceLicenceDirectApplicationConfiguration(origin: URL(string: "http://bad.invalid")!, expectedDevicePublicKey: nil,
            receiptFileURL: URL(fileURLWithPath: "/synthetic/receipt"), identityKeychainService: "x", identityKeychainAccount: "x", resourceTimeout: 5))
        let repository = DeviceLicenceBootstrapRepository(profile: try f.profile(), storage: DirectOwnerStorage(try f.envelope()))
        let saved = try await repository.load()
        XCTAssertEqual(String(describing: saved!), "StoredDeviceLicenceBootstrap")
        XCTAssertEqual(String(reflecting: saved!), "StoredDeviceLicenceBootstrap")
        let native = try DeviceLicenceBootstrapKeychainStorage(service: "synthetic.bootstrap", account: "record", calls: OwnerNeverKeychainCalls())
        _ = native // Constructors only; never execute native storage.
    }
}
private final class OwnerRecordingKeychainCalls: DeviceIdentityKeychainCalls, @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [[String: Any]] = [], duplicate = false
    func setDuplicate() { lock.lock(); defer { lock.unlock() }; duplicate = true }
    func snapshot() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return queries }
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?) { lock.lock(); defer { lock.unlock() }; queries.append(query); return (errSecItemNotFound, nil) }
    func add(_ attributes: [String: Any]) -> OSStatus { lock.lock(); defer { lock.unlock() }; queries.append(attributes); return duplicate ? errSecDuplicateItem : errSecSuccess }
}
private struct OwnerNeverKeychainCalls: DeviceIdentityKeychainCalls {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?) { fatalError("native calls forbidden in this test") }
    func add(_ attributes: [String: Any]) -> OSStatus { fatalError("native calls forbidden in this test") }
}
#endif
