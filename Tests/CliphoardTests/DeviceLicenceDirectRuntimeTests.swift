#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE && !APP_STORE
import XCTest
import Foundation
import Combine
import CryptoKit
@testable import Cliphoard

@MainActor
final class DeviceLicenceDirectRuntimeTests: XCTestCase {
    func testUnconfiguredRuntimeIsInertAndKeepsLegacy() async throws {
        let runtime = DeviceLicenceDirectRuntime(owner: nil)
        var receipts: [DeviceLicenceReceipt?] = []
        await runtime.start { receipts.append($0) }?.value
        XCTAssertFalse(runtime.isConfigured)
        XCTAssertNil(runtime.session)
        XCTAssertNil(runtime.importBootstrap("untrusted"))
        XCTAssertEqual(runtime.lifecycle, .running)
        XCTAssertTrue(receipts.isEmpty)
        let legacy = Entitlement.pro(orderID: "existing-order", issued: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(DeviceLicenceDirectEntitlements.resolve(legacy: legacy, receipt: nil), legacy)
        runtime.stop()
        XCTAssertEqual(runtime.lifecycle, .stopped)
        XCTAssertNil(runtime.start { _ in XCTFail("restarted stopped runtime") })
    }
    func testReceiptProjectionRetainsActualIdentityAndIssuance() async throws {
        let f = try ApplicationFixture(); defer { f.cleanup() }
        let session = try f.session()
        XCTAssertNil(session.approvedReceipt)
        try await f.activate(session)
        let receipt = try XCTUnwrap(session.approvedReceipt)
        XCTAssertEqual(receipt.entitlementID, f.entitlement)
        XCTAssertEqual(receipt.issuedAt, 1767323045)
        let entitlement = DeviceLicenceDirectEntitlements.resolve(legacy: .free(reason: nil), receipt: receipt)
        guard case .devicePro(let actual) = entitlement else { return XCTFail("missing receipt entitlement") }
        XCTAssertEqual(actual, receipt)
        XCTAssertTrue(entitlement.isPro)
        let legacy = Entitlement.pro(orderID: "old-order", issued: Date(timeIntervalSince1970: 123))
        XCTAssertEqual(DeviceLicenceDirectEntitlements.resolve(legacy: legacy, receipt: receipt), legacy)
        await session.importApprovedReceipt("malformed")?.value
        XCTAssertEqual(session.approvedReceipt, receipt)
    }
    func testValidSetupOwnsOneSessionAndOnlyReceiptApprovalGrantsPro() async throws {
        let f = try RuntimeFixture(); defer { f.cleanup() }
        let runtime = f.runtime()
        var receipts: [DeviceLicenceReceipt] = []
        await runtime.start { if let value = $0 { receipts.append(value) } }?.value
        XCTAssertNil(runtime.session); XCTAssertTrue(f.sessions.isEmpty)
        await runtime.importBootstrap(try f.envelope())?.value
        let session = try XCTUnwrap(runtime.session)
        XCTAssertTrue(session === f.sessions.first)
        XCTAssertTrue(receipts.isEmpty); XCTAssertNil(session.approvedReceipt)
        XCTAssertNil(runtime.start { _ in XCTFail("second start") })
        await runtime.restoreBootstrap()?.value
        XCTAssertEqual(f.sessions.count, 1)
        session.openPanel(); session.closePanel()
        XCTAssertEqual(session.lifecycle, .running)
        try await f.activate(session)
        await drain()
        let receipt = try XCTUnwrap(receipts.last)
        XCTAssertEqual(receipt, session.approvedReceipt)
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipt.issuerKeyID, "synthetic-session")
        XCTAssertEqual(receipt.entitlementID, f.application.entitlement)
        await runtime.importBootstrap("invalid")?.value
        XCTAssertEqual(runtime.failure, .scopeConflict)
        XCTAssertTrue(runtime.session === session)
        XCTAssertEqual(receipts.count, 1)
        runtime.stop(); XCTAssertEqual(session.lifecycle, .stopped)
        XCTAssertNil(runtime.session); XCTAssertNil(runtime.restoreBootstrap())
    }

    func testInvalidSetupHasNoIdentityOrFactoryEffectsAndCanRetry() async throws {
        let f = try RuntimeFixture(); defer { f.cleanup() }
        let runtime = f.runtime()
        await runtime.start { _ in XCTFail("unapproved") }?.value
        await runtime.importBootstrap("invalid")?.value
        XCTAssertEqual(runtime.failure, .invalidBootstrap)
        XCTAssertTrue(f.sessions.isEmpty)
        let creations = await f.application.keys.creations
        XCTAssertEqual(creations, 0)
        await runtime.importBootstrap(try f.envelope())?.value
        XCTAssertNil(runtime.failure); XCTAssertEqual(f.sessions.count, 1)
        runtime.stop()
    }

    func testStopDuringBootstrapReadPreventsLateSessionAndEntitlement() async throws {
        let f = try RuntimeFixture(); defer { f.cleanup() }
        let gate = ApplicationGate()
        await f.storage.seed(try f.envelope()); await f.storage.holdRead(gate)
        let runtime = f.runtime()
        let action = runtime.start { _ in XCTFail("late receipt") }
        await gate.wait(); runtime.stop(); await gate.release(); await action?.value
        await drain()
        XCTAssertEqual(runtime.lifecycle, .stopped)
        XCTAssertNil(runtime.session); XCTAssertFalse(runtime.isWorking)
        XCTAssertTrue(f.sessions.isEmpty)
    }

    func testReentrantStopOnRuntimePublicationPreventsWork() async throws {
        let f = try RuntimeFixture(); defer { f.cleanup() }
        let runtime = f.runtime()
        let observation = runtime.objectWillChange.sink {
            if runtime.lifecycle == .running { runtime.stop() }
        }
        await runtime.start { _ in XCTFail("receipt after stop") }?.value
        await drain()
        XCTAssertEqual(runtime.lifecycle, .stopped); XCTAssertFalse(runtime.isWorking)
        XCTAssertTrue(f.sessions.isEmpty)
        let reads = await f.storage.reads; XCTAssertEqual(reads, 0)
        withExtendedLifetime(observation) {}
    }

    func testCallerCancellationBeforeTaskExecutionClearsBusyAndAllowsRetry() async throws {
        let f = try RuntimeFixture(); defer { f.cleanup() }
        let runtime = f.runtime()
        let first = runtime.start { _ in XCTFail("unapproved") }
        first?.cancel(); await first?.value
        XCTAssertFalse(runtime.isWorking); XCTAssertEqual(runtime.failure, .cancelled)
        await runtime.importBootstrap(try f.envelope())?.value
        XCTAssertNil(runtime.failure); XCTAssertEqual(f.sessions.count, 1)
        runtime.stop()
    }

    func testPersistenceFailureCannotProjectProOrReplaceLegacy() async throws {
        let f = try RuntimeFixture(); defer { f.cleanup() }
        let runtime = f.runtime()
        var receipts: [DeviceLicenceReceipt?] = []
        await runtime.start { receipts.append($0) }?.value
        await runtime.importBootstrap(try f.envelope())?.value
        let session = try XCTUnwrap(runtime.session)
        f.application.io.set(.write)
        try await f.activate(session)
        await drain()
        XCTAssertNil(session.approvedReceipt); XCTAssertTrue(receipts.isEmpty)
        let legacy = Entitlement.pro(orderID: "previous-purchase", issued: Date(timeIntervalSince1970: 42))
        XCTAssertEqual(DeviceLicenceDirectEntitlements.resolve(legacy: legacy, receipt: session.approvedReceipt), legacy)
        runtime.stop()
    }

    func testReceiptPublicationReentrantStopIsTerminal() async throws {
        let f = try RuntimeFixture(); defer { f.cleanup() }
        let runtime = f.runtime()
        var deliveries = 0
        await runtime.start { receipt in
            if receipt != nil { deliveries += 1; runtime.stop() }
        }?.value
        await runtime.importBootstrap(try f.envelope())?.value
        let session = try XCTUnwrap(runtime.session)
        try await f.activate(session); await drain()
        XCTAssertEqual(deliveries, 1); XCTAssertEqual(runtime.lifecycle, .stopped)
        XCTAssertEqual(session.lifecycle, .stopped); XCTAssertNil(runtime.session)
        XCTAssertFalse(runtime.isWorking)
    }

    private func drain() async { for _ in 0..<30 { await Task.yield() } }
}

private actor RuntimeBootstrapStorage: DeviceLicenceBootstrapSecureStorage {
    private var data: Data?, readGate: ApplicationGate?
    private(set) var reads = 0
    func seed(_ envelope: String) { data = Data(envelope.utf8) }
    func holdRead(_ gate: ApplicationGate) { readGate = gate }
    func read() async throws -> Data? {
        reads += 1; let gate = readGate; readGate = nil
        if let gate { await gate.pause() }
        return data
    }
    func insertIfAbsent(_ record: Data) async throws -> Bool {
        guard data == nil else { return false }; data = record; return true
    }
}
@MainActor
private final class RuntimeFixture {
    let application: ApplicationFixture
    let signer = P256.Signing.PrivateKey()
    let storage = RuntimeBootstrapStorage()
    var sessions: [DeviceLicenceApplicationSession] = []
    init() throws { application = try ApplicationFixture() }
    func envelope() throws -> String {
        let bytes = Data(["cliphoard.device-bootstrap", "1", "P256-SHA256", "runtime-bootstrap",
            "runtime-test", "synthetic-session", application.entitlement,
            DeviceLicenceVerifier.encode(Data(repeating: 2, count: 32)), "1767323045", "pro"].joined(separator: "\n").utf8)
        return "CLIPB1.\(DeviceLicenceVerifier.encode(bytes)).\(DeviceLicenceVerifier.encode(try signer.signature(for: bytes).rawRepresentation))"
    }
    func runtime() -> DeviceLicenceDirectRuntime {
        let profile = try! DeviceLicenceBootstrapTrustProfile(profileID: "runtime-test", bootstrapKeyID: "runtime-bootstrap",
            bootstrapPublicKey: signer.publicKey.x963Representation,
            receiptIssuers: ["synthetic-session": application.issuer.publicKey.x963Representation])
        let repository = DeviceLicenceBootstrapRepository(profile: profile, storage: storage)
        let configuration = try! DeviceLicenceDirectApplicationConfiguration(origin: URL(string: "https://synthetic.example.invalid")!,
            expectedDevicePublicKey: nil, receiptFileURL: application.receiptURL,
            identityKeychainService: "synthetic.session", identityKeychainAccount: "synthetic-device", resourceTimeout: 20)
        let owner = DeviceLicenceDirectApplicationOwner(repository: repository, configuration: configuration) { [self] _ in
            // Same locally pinned synthetic profile/realm; all identity and transport adapters are fixtures.
            let session = try application.session(); sessions.append(session); return session
        }
        return DeviceLicenceDirectRuntime(owner: owner)
    }
    func activate(_ session: DeviceLicenceApplicationSession) async throws {
        // The owner starts restoration asynchronously. Wait for that existing work;
        // a second start is deliberately a no-op and cannot be used as its join.
        for _ in 0..<100 {
            if session.approvalState.phase != .working(.restoring) { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertNotEqual(session.approvalState.phase, .working(.restoring))
        try await application.activate(session)
    }
    func cleanup() { application.cleanup() }
}
#endif
