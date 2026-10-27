#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE && !APP_STORE
import XCTest
import CryptoKit
import Foundation
@testable import Cliphoard

actor FlowGate {
    private var entered = false
    private var released = false
    private var entry: CheckedContinuation<Void, Never>?
    private var exit: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true; entry?.resume(); entry = nil
        if !released { await withCheckedContinuation { exit = $0 } }
    }
    func wait() async { if !entered { await withCheckedContinuation { entry = $0 } } }
    func release() { released = true; exit?.resume(); exit = nil }
}
actor FlowIdentityStore: DeviceIdentityStorage {
    var bytes: Data?
    private(set) var reads = 0
    private(set) var writes = 0
    func read() async throws -> Data? { reads += 1; return bytes }
    func insertIfAbsent(_ record: Data) async throws -> Bool {
        guard bytes == nil else { return false }; bytes = record; writes += 1; return true
    }
    func removeForTest() { bytes = nil }
}
actor FlowKeys: DeviceIdentityKeyOperations {
    private let key = P256.Signing.PrivateKey()
    private var available = true
    private(set) var creations = 0
    private(set) var signatures = 0
    func isAvailable() async -> Bool { available }
    func setAvailable(_ value: Bool) { available = value }
    func create() async throws -> DeviceIdentityMaterial {
        creations += 1
        return .init(publicKeyX963: key.publicKey.x963Representation, wrappedKey: Data([1]))
    }
    func publicKey(for wrappedKey: Data) async throws -> Data {
        guard wrappedKey == Data([1]) else { throw DeviceIdentityFailure.invalidRecord }
        return key.publicKey.x963Representation
    }
    func sign(_ message: Data, using wrappedKey: Data) async throws -> Data {
        signatures += 1
        return try key.signature(for: message).rawRepresentation
    }
}
actor FlowReceiptStore: DeviceLicenceReceiptStorage {
    private var snapshot = DeviceLicenceReceiptSnapshot(envelope: nil, revision: nil)
    private var readError: DeviceLicenceReceiptStorageFailure?
    private var nextWriteError: DeviceLicenceReceiptStorageFailure?
    private var commitBeforeError = false
    private var gate: FlowGate?
    private(set) var reads = 0
    private(set) var writes = 0
    private(set) var attemptedEnvelopes: [String] = []
    func seed(_ envelope: String?) {
        snapshot = .init(envelope: envelope, revision: envelope.map { Data(SHA256.hash(data: Data($0.utf8))) })
    }
    func failRead(_ error: DeviceLicenceReceiptStorageFailure?) { readError = error }
    func failWrite(_ error: DeviceLicenceReceiptStorageFailure, afterCommit: Bool = false) {
        nextWriteError = error; commitBeforeError = afterCommit
    }
    func holdWrite(_ value: FlowGate) { gate = value }
    func saved() -> String? { snapshot.envelope }
    func read() async throws -> DeviceLicenceReceiptSnapshot {
        reads += 1; if let readError { throw readError }; return snapshot
    }
    func replace(_ envelope: String, expectedRevision: Data?, permit: DeviceLicenceReceiptPermit)
        async throws -> DeviceLicenceReceiptSnapshot {
        attemptedEnvelopes.append(envelope)
        let wait = gate; gate = nil
        if let wait { await wait.pause() }
        try Task.checkCancellation()
        guard snapshot.revision == expectedRevision else { throw DeviceLicenceReceiptStorageFailure.conflict }
        let error = nextWriteError; nextWriteError = nil
        if error == nil || commitBeforeError { seed(envelope); writes += 1 }
        commitBeforeError = false
        if let error { throw error }
        return snapshot
    }
}
final class FlowIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var counter: UInt8 = 10
    private(set) var calls = 0
    func next() -> Data {
        lock.lock(); defer { lock.unlock() }
        calls += 1; counter &+= 1; return Data(repeating: counter, count: 16)
    }
}
final class FlowClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 1767323045
    func now() -> UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: UInt64) { lock.lock(); defer { lock.unlock() }; value += seconds }
}
actor FlowNoNetworkTransport: DeviceLicenceApprovalTransport {
    private(set) var calls = 0
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> DeviceLicenceApprovalHTTPResponse {
        calls += 1
        throw DeviceLicenceApprovalClientFailure.unavailable
    }
}
actor FlowService: DeviceLicenceApprovalServing {
    let entitlementID: String
    let issuer: P256.Signing.PrivateKey
    private(set) var begins: [DeviceLicenceBeginRequest] = []
    private(set) var preparations = 0
    private(set) var approvals: [DeviceLicenceApprovalRequest] = []
    var beginGate: FlowGate?
    var beginError: DeviceLicenceApprovalClientFailure?
    var approvalError: DeviceLicenceApprovalClientFailure?
    var approvalGate: FlowGate?
    var overrideChallenge: DeviceLicenceApprovalChallenge?
    var overrideEnvelope: String?
    private var issued: [Data: String] = [:]
    let transport = FlowNoNetworkTransport()
    private let codec: DeviceLicenceApprovalClient
    init(entitlementID: String, issuer: P256.Signing.PrivateKey) throws {
        self.entitlementID = entitlementID; self.issuer = issuer
        codec = try DeviceLicenceApprovalClient(origin: URL(string: "https://synthetic.example.invalid")!,
            expectedEntitlementID: entitlementID, transport: transport)
    }
    func begin(_ request: DeviceLicenceBeginRequest) async throws -> DeviceLicenceApprovalChallenge {
        begins.append(request)
        let gate = beginGate; beginGate = nil
        if let gate { await gate.pause() }
        if let beginError { throw beginError }
        if let overrideChallenge { return overrideChallenge }
        return try .init(entitlementID: entitlementID, devicePublicKeyX963: request.devicePublicKeyX963,
                         challengeID: Data(repeating: 20, count: 16), nonce: Data(repeating: 21, count: 32), expiresAt: 1767323645)
    }
    func prepareApproval(challenge: DeviceLicenceApprovalChallenge, token: String,
                         approvalRequestID: Data, using device: any DeviceLicenceKeyProvider) async throws -> DeviceLicenceApprovalRequest {
        preparations += 1
        return try await codec.prepareApproval(challenge: challenge, token: token, approvalRequestID: approvalRequestID, using: device)
    }
    func approve(_ request: DeviceLicenceApprovalRequest) async throws -> DeviceLicenceApprovalResult {
        approvals.append(request)
        if approvalError == .activationRejected { throw DeviceLicenceApprovalClientFailure.activationRejected }
        let existed = issued[request.body] != nil
        if !existed { issued[request.body] = try envelope(request.challenge.devicePublicKeyX963) }
        let gate = approvalGate; approvalGate = nil
        if let gate { await gate.pause() }
        if let approvalError { throw approvalError }
        return .init(disposition: existed ? .alreadyIssued : .issued, envelope: overrideEnvelope ?? issued[request.body]!)
    }
    func envelope(_ publicKey: Data, entitlement: String? = nil, receiptByte: UInt8 = 30) throws -> String {
        let bytes = Data(["cliphoard.device-receipt", "1", "P256-SHA256", "synthetic-flow",
            entitlement ?? entitlementID, DeviceLicenceVerifier.encode(Data(SHA256.hash(data: publicKey))),
            DeviceLicenceVerifier.encode(Data(repeating: receiptByte, count: 16)), "1767323045", "pro", "perpetual"]
            .joined(separator: "\n").utf8)
        return "CLIPD1.\(DeviceLicenceVerifier.encode(bytes)).\(DeviceLicenceVerifier.encode(try issuer.signature(for: bytes).rawRepresentation))"
    }
    func setBeginError(_ value: DeviceLicenceApprovalClientFailure?) { beginError = value }
    func holdBegin(_ gate: FlowGate) { beginGate = gate }
    func setApprovalError(_ value: DeviceLicenceApprovalClientFailure?) { approvalError = value }
    func holdApproval(_ gate: FlowGate) { approvalGate = gate }
    func setChallenge(_ value: DeviceLicenceApprovalChallenge) { overrideChallenge = value }
    func setEnvelope(_ value: String) { overrideEnvelope = value }
}
@MainActor
struct FlowFixture {
    let identityStore = FlowIdentityStore()
    let keys = FlowKeys()
    let receipts = FlowReceiptStore()
    let ids = FlowIDs()
    let clock = FlowClock()
    let identity: DeviceIdentity
    let service: FlowService
    let flow: DeviceLicenceApprovalFlow
    init() throws {
        let issuer = P256.Signing.PrivateKey()
        let entitlement = DeviceLicenceVerifier.encode(Data(repeating: 1, count: 16))
        identity = try DeviceIdentity(storage: identityStore, keys: keys)
        service = try FlowService(entitlementID: entitlement, issuer: issuer)
        flow = try DeviceLicenceApprovalFlow(context: .init(issuerKeyID: "synthetic-flow",
            issuerPublicKey: issuer.publicKey.x963Representation, entitlementID: entitlement),
            entitlementHandle: DeviceLicenceVerifier.encode(Data(repeating: 2, count: 32)),
            identity: identity, storage: receipts, service: service,
            now: { [clock] in clock.now() }, makeRequestID: { [ids] in ids.next() })
    }
    var token: String { DeviceLicenceVerifier.encode(Data(repeating: 40, count: 32)) }
    func seedApproved() async throws -> String {
        let key = try await identity.createIfAbsent().get()
        let envelope = try await service.envelope(key, receiptByte: 41)
        await receipts.seed(envelope)
        await flow.restoreSavedApproval()?.value
        return envelope
    }
}

@MainActor
final class DeviceLicenceApprovalFlowTests: XCTestCase {
    func testConstructionHasNoIdentityStorageOrServiceEffects() async throws {
        let f = try FlowFixture()
        let counts = await (f.identityStore.reads, f.keys.creations, f.receipts.reads, f.service.begins.count)
        XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0); XCTAssertEqual(counts.2, 0); XCTAssertEqual(counts.3, 0)
        XCTAssertEqual(f.ids.calls, 0)
        XCTAssertEqual(f.flow.state.phase, .ready)
    }
    func testExplicitRequestCreatesIdentityOnceAndReportsQueuedNotDelivered() async throws {
        let f = try FlowFixture()
        await f.flow.requestApprovalForThisMac()?.value
        let counts = await (f.keys.creations, f.service.begins.count)
        XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 1)
        XCTAssertEqual(f.flow.state.phase, .awaitingCode)
        XCTAssertEqual(f.flow.state.notice, .approvalQueued)
        XCTAssertFalse(f.flow.state.isApproved)
    }
    func testRestoreReverifiesExistingReceiptWithoutCreatingIdentityOrServiceCalls() async throws {
        let f = try FlowFixture()
        let key = try await f.identity.createIfAbsent().get()
        let envelope = try await f.service.envelope(key)
        await f.receipts.seed(envelope)
        await f.flow.restoreSavedApproval()?.value
        XCTAssertTrue(f.flow.state.isApproved)
        let counts = await (f.keys.creations, f.keys.signatures, f.service.begins.count, f.service.approvals.count)
        XCTAssertEqual(counts.0, 1); XCTAssertGreaterThan(counts.1, 0); XCTAssertEqual(counts.2, 0); XCTAssertEqual(counts.3, 0)
    }
    func testRestoreMissingIdentityDoesNotCreateOrRequest() async throws {
        let f = try FlowFixture()
        await f.flow.restoreSavedApproval()?.value
        XCTAssertEqual(f.flow.state.notice, .identityMissing)
        let counts = await (f.keys.creations, f.service.begins.count, f.receipts.writes)
        XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0); XCTAssertEqual(counts.2, 0)
    }
    func testFailedManualImportWithoutIdentityDoesNotStrandExplicitFirstActivation() async throws {
        let f = try FlowFixture()
        await f.flow.restoreSavedApproval()?.value
        let publicKey = try await f.keys.publicKey(for: Data([1]))
        let pasted = try await f.service.envelope(publicKey)
        await f.flow.importApprovedReceipt(pasted)?.value
        XCTAssertEqual(f.flow.state.notice, .identityMissing)
        let beforeConsent = await (f.keys.creations, f.identityStore.writes,
                                   f.service.begins.count, f.service.approvals.count, f.receipts.writes)
        XCTAssertEqual(beforeConsent.0, 0); XCTAssertEqual(beforeConsent.1, 0)
        XCTAssertEqual(beforeConsent.2, 0); XCTAssertEqual(beforeConsent.3, 0); XCTAssertEqual(beforeConsent.4, 0)
        XCTAssertTrue(f.flow.state.canRequest, "A failed unverified paste cannot strand consented first activation")
        let consented = try XCTUnwrap(f.flow.requestApprovalForThisMac())
        await consented.value
        let afterConsent = await (f.keys.creations, f.service.begins.count)
        XCTAssertEqual(afterConsent.0, 1); XCTAssertEqual(afterConsent.1, 1)
        XCTAssertEqual(f.flow.state.phase, .awaitingCode)
    }
    func testBadManualImportPreservesPendingServiceReceiptForLocalRetry() async throws {
        let f = try FlowFixture()
        await f.flow.requestApprovalForThisMac()?.value
        await f.receipts.failWrite(.io)
        await f.flow.submitEmailCode(f.token)?.value
        let attempts = await f.receipts.attemptedEnvelopes
        let issued = try XCTUnwrap(attempts.first)
        let key = try await f.identity.loadExisting().get()
        let foreign = try await f.service.envelope(key,
            entitlement: DeviceLicenceVerifier.encode(Data(repeating: 91, count: 16)))
        await f.flow.importApprovedReceipt(foreign)?.value
        XCTAssertEqual(f.flow.state.notice, .invalidReceipt)
        XCTAssertEqual(f.flow.state.retry, .saveReceipt, "Invalid manual input must not discard the existing issued-response envelope")
        XCTAssertFalse(f.flow.state.canRequest)
        await f.flow.retrySameOperation()?.value
        let saved = await f.receipts.saved()
        let counts = await (f.service.begins.count, f.service.approvals.count, f.service.preparations)
        XCTAssertEqual(saved, issued)
        XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 1); XCTAssertEqual(counts.2, 1)
        XCTAssertEqual(f.ids.calls, 2)
        XCTAssertTrue(f.flow.state.isApproved)
    }
    func testFailedManualImportCannotRegenerateMissingKnownIdentity() async throws {
        let f = try FlowFixture()
        let key = try await f.identity.createIfAbsent().get()
        await f.flow.restoreSavedApproval()?.value
        let pasted = try await f.service.envelope(key)
        await f.identityStore.removeForTest()
        await f.flow.importApprovedReceipt(pasted)?.value
        // Even explicit consent cannot replace the expected/previously known key.
        await f.flow.requestApprovalForThisMac()?.value
        XCTAssertEqual(f.flow.state.notice, .identityMissing)
        let counts = await (f.keys.creations, f.identityStore.writes, f.service.begins.count, f.receipts.writes)
        XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 1)
        XCTAssertEqual(counts.2, 0); XCTAssertEqual(counts.3, 0)
    }
    func testManualImportUncertainCommitPreservesPendingServiceReceiptAndBarrier() async throws {
        let f = try FlowFixture()
        await f.flow.requestApprovalForThisMac()?.value
        await f.receipts.failWrite(.io)
        await f.flow.submitEmailCode(f.token)?.value
        let attempts = await f.receipts.attemptedEnvelopes
        let issued = try XCTUnwrap(attempts.first)
        let key = try await f.identity.loadExisting().get()
        let pasted = try await f.service.envelope(key, receiptByte: 42)
        await f.receipts.failWrite(.commitUncertain)
        await f.flow.importApprovedReceipt(pasted)?.value
        XCTAssertEqual(f.flow.state.phase, .recoveryRequired)
        XCTAssertNil(f.flow.requestApprovalForThisMac()); XCTAssertNil(f.flow.retrySameOperation())
        XCTAssertNil(f.flow.importApprovedReceipt(pasted))
        await f.flow.restoreSavedApproval()?.value
        XCTAssertEqual(f.flow.state.notice, .savedApprovalMissing)
        XCTAssertEqual(f.flow.state.retry, .saveReceipt)
        await f.flow.retrySameOperation()?.value
        let saved = await f.receipts.saved()
        let approvals = await f.service.approvals.count
        XCTAssertEqual(saved, issued, "The manual draft cannot overwrite prior service receipt custody")
        XCTAssertEqual(approvals, 1)
        XCTAssertTrue(f.flow.state.isApproved)
    }
    func testUnknownBeginOutcomeAndDoubleClickRetainExactCommandAndIdentity() async throws {
        let f = try FlowFixture(), gate = FlowGate()
        await f.service.holdBegin(gate); await f.service.setBeginError(.transportUncertain)
        let first = f.flow.requestApprovalForThisMac()
        await gate.wait()
        XCTAssertNil(f.flow.requestApprovalForThisMac())
        XCTAssertNil(f.flow.submitEmailCode(f.token))
        await gate.release(); await first?.value
        XCTAssertEqual(f.flow.state.notice, .outcomeUnknown)
        XCTAssertEqual(f.flow.state.retry, .sameRequest)
        XCTAssertFalse(f.flow.state.canRequest)
        await f.service.setBeginError(nil)
        await f.flow.retrySameOperation()?.value
        let commands = await f.service.begins
        XCTAssertEqual(commands.count, 2); XCTAssertEqual(commands[0], commands[1])
        let creations = await f.keys.creations
        XCTAssertEqual(creations, 1); XCTAssertEqual(f.ids.calls, 1)
        XCTAssertEqual(f.flow.state.phase, .awaitingCode)
    }
    func testForeignChallengeIsRejectedBeforeCodeOrProof() async throws {
        let f = try FlowFixture()
        let key = try await f.identity.createIfAbsent().get()
        let foreign = try DeviceLicenceApprovalChallenge(entitlementID: DeviceLicenceVerifier.encode(Data(repeating: 99, count: 16)),
            devicePublicKeyX963: key, challengeID: Data(repeating: 2, count: 16), nonce: Data(repeating: 3, count: 32), expiresAt: 1767323645)
        await f.service.setChallenge(foreign)
        await f.flow.requestApprovalForThisMac()?.value
        XCTAssertEqual(f.flow.state.notice, .invalidResponse)
        XCTAssertFalse(f.flow.state.canEnterCode)
        XCTAssertNil(f.flow.submitEmailCode(f.token))
        let preparations = await f.service.preparations
        XCTAssertEqual(preparations, 0)
    }
    func testInvalidCodeIsNotSignedAndServiceSuccessNeedsLocalProofAndCommit() async throws {
        let f = try FlowFixture()
        await f.flow.requestApprovalForThisMac()?.value
        XCTAssertNil(f.flow.submitEmailCode("not a code"))
        let before = await f.keys.signatures
        XCTAssertEqual(before, 0)
        await f.flow.submitEmailCode(f.token)?.value
        XCTAssertTrue(f.flow.state.isApproved)
        let counts = await (f.service.preparations, f.service.approvals.count, f.receipts.writes, f.keys.signatures, f.service.transport.calls)
        XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 1); XCTAssertEqual(counts.2, 1)
        XCTAssertEqual(counts.3, 2, "one email approval proof and a fresh local receipt proof")
        XCTAssertEqual(counts.4, 0, "the real proof codec needs no transport")
        XCTAssertNil(f.flow.retrySameOperation())
    }
    func testLostApprovalReplyRetriesSameBodyAndSignatureAfterExpiry() async throws {
        let f = try FlowFixture()
        await f.flow.requestApprovalForThisMac()?.value
        await f.service.setApprovalError(.transportUncertain)
        await f.flow.submitEmailCode(f.token)?.value
        XCTAssertEqual(f.flow.state.retry, .sameRequest)
        XCTAssertFalse(f.flow.state.canEnterCode)
        XCTAssertFalse(f.flow.state.canUseDifferentCode)
        f.flow.useDifferentCode()
        f.clock.advance(900)
        await f.service.setApprovalError(nil)
        await f.flow.retrySameOperation()?.value
        let commands = await f.service.approvals
        XCTAssertEqual(commands.count, 2); XCTAssertEqual(commands[0], commands[1])
        let preparations = await f.service.preparations
        XCTAssertEqual(preparations, 1); XCTAssertEqual(f.ids.calls, 2)
        XCTAssertTrue(f.flow.state.isApproved)
    }
    func testKnownRejectionStaysGenericAndChangingCodeRequiresExplicitAction() async throws {
        let f = try FlowFixture()
        await f.flow.requestApprovalForThisMac()?.value
        await f.service.setApprovalError(.activationRejected)
        await f.flow.submitEmailCode(f.token)?.value
        XCTAssertEqual(f.flow.state.notice, .activationRejected)
        XCTAssertEqual(f.flow.state.retry, .sameRequest)
        XCTAssertTrue(f.flow.state.canUseDifferentCode)
        XCTAssertFalse(f.flow.state.canEnterCode)
        f.flow.useDifferentCode()
        XCTAssertTrue(f.flow.state.canEnterCode)
        XCTAssertEqual(f.flow.state.phase, .awaitingCode)
        await f.service.setApprovalError(nil)
        await f.flow.submitEmailCode(DeviceLicenceVerifier.encode(Data(repeating: 42, count: 32)))?.value
        let commands = await f.service.approvals
        XCTAssertNotEqual(commands[0].approvalRequestID, commands[1].approvalRequestID)
        XCTAssertTrue(f.flow.state.isApproved)
    }
    func testCancelAfterServerAcceptanceAllowsExactRetryAndFencesLateReply() async throws {
        let f = try FlowFixture(), gate = FlowGate()
        await f.flow.requestApprovalForThisMac()?.value
        await f.service.holdApproval(gate)
        let old = f.flow.submitEmailCode(f.token)
        await gate.wait()
        f.flow.cancelLocalWork()
        XCTAssertEqual(f.flow.state.phase, .cancelled)
        XCTAssertFalse(f.flow.state.isApproved)
        await f.flow.retrySameOperation()?.value
        let approved = f.flow.approvedReceipt
        XCTAssertNotNil(approved)
        await gate.release(); await old?.value
        XCTAssertEqual(f.flow.approvedReceipt, approved)
        let commands = await f.service.approvals
        XCTAssertEqual(commands.count, 2); XCTAssertEqual(commands[0].body, commands[1].body)
        let writes = await f.receipts.writes
        XCTAssertEqual(writes, 1)
    }
    func testCancelWhileSavingRequiresLocalCheckAndDoesNotPermitStaleWrite() async throws {
        let f = try FlowFixture(), gate = FlowGate()
        await f.flow.requestApprovalForThisMac()?.value
        await f.receipts.holdWrite(gate)
        let work = f.flow.submitEmailCode(f.token)
        await gate.wait()
        f.flow.cancelLocalWork()
        XCTAssertEqual(f.flow.state.phase, .recoveryRequired)
        XCTAssertNil(f.flow.retrySameOperation())
        XCTAssertNil(f.flow.importApprovedReceipt("CLIPD1.invalid"))
        await gate.release(); await work?.value
        let writes = await f.receipts.writes
        XCTAssertEqual(writes, 0)
        await f.flow.restoreSavedApproval()?.value
        XCTAssertEqual(f.flow.state.notice, .savedApprovalMissing)
        XCTAssertEqual(f.flow.state.retry, .saveReceipt)
        await f.flow.retrySameOperation()?.value
        XCTAssertTrue(f.flow.state.isApproved)
        let approvals = await f.service.approvals.count
        XCTAssertEqual(approvals, 1)
    }
    func testUncertainAbsentCommitIsResolvedByAuthoritativeAbsenceThenLocalReplay() async throws {
        let f = try FlowFixture()
        await f.flow.requestApprovalForThisMac()?.value
        await f.receipts.failWrite(.commitUncertain)
        await f.flow.submitEmailCode(f.token)?.value
        XCTAssertEqual(f.flow.state.phase, .recoveryRequired)
        XCTAssertNil(f.flow.requestApprovalForThisMac()); XCTAssertNil(f.flow.retrySameOperation())
        await f.flow.restoreSavedApproval()?.value
        XCTAssertEqual(f.flow.state.notice, .savedApprovalMissing)
        XCTAssertEqual(f.flow.state.retry, .saveReceipt)
        await f.flow.retrySameOperation()?.value
        let counts = await (f.service.approvals.count, f.service.preparations, f.receipts.writes)
        XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 1); XCTAssertEqual(counts.2, 1)
        XCTAssertTrue(f.flow.state.isApproved)
    }
    func testUncertainCommittedReceiptCanBeRecoveredWithoutNetworkOrRewrite() async throws {
        let f = try FlowFixture()
        await f.flow.requestApprovalForThisMac()?.value
        await f.receipts.failWrite(.commitUncertain, afterCommit: true)
        await f.flow.submitEmailCode(f.token)?.value
        XCTAssertFalse(f.flow.state.isApproved)
        await f.flow.restoreSavedApproval()?.value
        XCTAssertTrue(f.flow.state.isApproved)
        await f.flow.retrySameOperation()?.value
        let counts = await (f.service.approvals.count, f.receipts.writes)
        XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 1)
    }
    func testUncertainBarrierSurvivesStorageAndMissingKeyFailures() async throws {
        let f = try FlowFixture()
        await f.flow.requestApprovalForThisMac()?.value
        await f.receipts.failWrite(.commitUncertain)
        await f.flow.submitEmailCode(f.token)?.value
        await f.receipts.failRead(.io)
        await f.flow.restoreSavedApproval()?.value
        XCTAssertEqual(f.flow.state.phase, .recoveryRequired)
        XCTAssertFalse(f.flow.state.canImport); XCTAssertNil(f.flow.retrySameOperation())
        await f.receipts.failRead(nil); await f.identityStore.removeForTest()
        await f.flow.restoreSavedApproval()?.value
        XCTAssertEqual(f.flow.state.phase, .recoveryRequired)
        XCTAssertEqual(f.flow.state.notice, .identityMissing)
        XCTAssertFalse(f.flow.state.canRequest); XCTAssertNil(f.flow.retrySameOperation())
    }
    func testLocalEmailReceiptImportNeverCreatesOrCallsServiceAndUsesFixedTrust() async throws {
        let f = try FlowFixture()
        let key = try await f.identity.createIfAbsent().get()
        let foreign = try await f.service.envelope(key, entitlement: DeviceLicenceVerifier.encode(Data(repeating: 90, count: 16)))
        await f.flow.importApprovedReceipt(foreign)?.value
        XCTAssertEqual(f.flow.state.notice, .invalidReceipt)
        XCTAssertFalse(f.flow.state.isApproved)
        let envelope = try await f.service.envelope(key)
        await f.flow.importApprovedReceipt(envelope)?.value
        XCTAssertTrue(f.flow.state.isApproved)
        let counts = await (f.keys.creations, f.service.begins.count, f.service.approvals.count)
        XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 0); XCTAssertEqual(counts.2, 0)
        let saved = await f.receipts.saved()
        XCTAssertEqual(saved, envelope)
    }
    func testPriorApprovalSurvivesBadImportOutageAndCancellationWithoutClockGate() async throws {
        let f = try FlowFixture()
        let envelope = try await f.seedApproved(), approved = f.flow.approvedReceipt
        f.clock.advance(1_000_000)
        XCTAssertNil(f.flow.importApprovedReceipt(String(repeating: "x", count: 1025)))
        await f.keys.setAvailable(false)
        await f.flow.restoreSavedApproval()?.value
        f.flow.cancelLocalWork()
        XCTAssertTrue(f.flow.state.isApproved); XCTAssertEqual(f.flow.approvedReceipt, approved)
        let saved = await f.receipts.saved()
        XCTAssertEqual(saved, envelope)
        let counts = await (f.service.begins.count, f.service.approvals.count)
        XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0)
    }
}
#endif
