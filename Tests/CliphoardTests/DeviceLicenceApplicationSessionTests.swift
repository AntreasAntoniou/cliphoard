#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE && !APP_STORE
import XCTest
import CryptoKit
import Foundation
import Combine
import Darwin
@testable import Cliphoard

// All keys are synthetic, in-memory signing fixtures. No native key adapter is run.
actor ApplicationGate {
    private var entered = false, released = false
    private var entry: CheckedContinuation<Void, Never>?
    private var exit: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true; entry?.resume(); entry = nil
        if !released { await withCheckedContinuation { exit = $0 } }
    }
    func wait() async { if !entered { await withCheckedContinuation { entry = $0 } } }
    func release() { released = true; exit?.resume(); exit = nil }
}
actor ApplicationIdentityStorage: DeviceIdentityStorage {
    private var bytes: Data?
    private(set) var reads = 0, insertions = 0
    private var gate: ApplicationGate?
    func hold(_ value: ApplicationGate) { gate = value }
    func read() async throws -> Data? {
        reads += 1; let wait = gate; gate = nil
        if let wait { await wait.pause() }
        return bytes
    }
    func insertIfAbsent(_ record: Data) async throws -> Bool {
        guard bytes == nil else { return false }; bytes = record; insertions += 1; return true
    }
    func removeForTest() { bytes = nil }
}
actor ApplicationKeys: DeviceIdentityKeyOperations {
    private var key = P256.Signing.PrivateKey()
    private var gate: ApplicationGate?
    private var available = true
    private(set) var creations = 0, signatures = 0, availabilityChecks = 0
    func isAvailable() async -> Bool { availabilityChecks += 1; return available }
    func setAvailable(_ value: Bool) { available = value }
    func publicBytes() -> Data { key.publicKey.x963Representation }
    func substituteForTest() { key = P256.Signing.PrivateKey() }
    func holdSignature(_ value: ApplicationGate) { gate = value }
    func create() async throws -> DeviceIdentityMaterial {
        creations += 1; return .init(publicKeyX963: key.publicKey.x963Representation, wrappedKey: Data([1]))
    }
    func publicKey(for wrappedKey: Data) async throws -> Data {
        guard wrappedKey == Data([1]) else { throw DeviceIdentityFailure.invalidRecord }
        return key.publicKey.x963Representation
    }
    func sign(_ message: Data, using wrappedKey: Data) async throws -> Data {
        signatures += 1; let wait = gate; gate = nil
        if let wait { await wait.pause() }
        return try key.signature(for: message).rawRepresentation
    }
}
final class ApplicationIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var nextByte: UInt8 = 10
    private(set) var calls = 0
    func next() -> Data {
        lock.lock(); defer { lock.unlock() }; calls += 1; nextByte &+= 1
        return Data(repeating: nextByte, count: 16)
    }
}
final class ApplicationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 1767323045
    func now() -> UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    func change(_ value: UInt64) { lock.lock(); self.value = value; lock.unlock() }
}
final class ApplicationFileIO: DeviceLicenceReceiptFileIO, @unchecked Sendable {
    enum Fault { case none, read, write, beforeRename, afterRename }
    private let lock = NSLock(), native = DeviceLicenceReceiptPOSIXIO()
    private var fault: Fault = .none
    private(set) var readCalls = 0, writes = 0
    func set(_ value: Fault) { lock.lock(); fault = value; lock.unlock() }
    private func current() -> Fault { lock.lock(); defer { lock.unlock() }; return fault }
    func read(_ fd: Int32, maximum: Int) throws -> Data {
        lock.lock(); readCalls += 1; lock.unlock()
        if current() == .read { throw DeviceLicenceReceiptStorageFailure.io }
        return try native.read(fd, maximum: maximum)
    }
    func write(_ bytes: Data, to fd: Int32) throws {
        lock.lock(); writes += 1; lock.unlock()
        if current() == .write { throw DeviceLicenceReceiptStorageFailure.io }
        try native.write(bytes, to: fd)
    }
    func synchronize(_ fd: Int32, full: Bool) throws { try native.synchronize(fd, full: full) }
    func rename(in directory: Int32, from: String, to: String) throws {
        if current() == .beforeRename { throw DeviceLicenceReceiptStorageFailure.io }
        try native.rename(in: directory, from: from, to: to)
        if current() == .afterRename { throw DeviceLicenceReceiptStorageFailure.io }
    }
}
actor ApplicationTransport: DeviceLicenceApprovalTransport {
    let entitlementID: String
    let issuer: P256.Signing.PrivateKey
    private var device: Data?
    private var beginGate: ApplicationGate?, approveGate: ApplicationGate?
    private var failApproval = false
    private var issued: [Data: String] = [:]
    private(set) var begins: [Data] = [], approvals: [Data] = []
    init(entitlementID: String, issuer: P256.Signing.PrivateKey) {
        self.entitlementID = entitlementID; self.issuer = issuer
    }
    func holdBegin(_ gate: ApplicationGate) { beginGate = gate }
    func holdApproval(_ gate: ApplicationGate) { approveGate = gate }
    func failApprovalReply(_ value: Bool) { failApproval = value }
    var mintCount: Int { issued.count }
    func envelope(for key: Data, entitlement: String? = nil) throws -> String {
        let payload = Data(["cliphoard.device-receipt", "1", "P256-SHA256", "synthetic-session",
            entitlement ?? entitlementID, DeviceLicenceVerifier.encode(Data(SHA256.hash(data: key))),
            DeviceLicenceVerifier.encode(Data(repeating: 40, count: 16)), "1767323045", "pro", "perpetual"].joined(separator: "\n").utf8)
        return "CLIPD1.\(DeviceLicenceVerifier.encode(payload)).\(DeviceLicenceVerifier.encode(try issuer.signature(for: payload).rawRepresentation))"
    }
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> DeviceLicenceApprovalHTTPResponse {
        guard let body = request.httpBody, maximumResponseBytes == 2048,
              request.url?.host == "synthetic.example.invalid" else { throw DeviceLicenceApprovalClientFailure.invalidRequest }
        let object = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let response: [String: Any]
        if request.url?.path == "/device-licensing/v1/begin" {
            begins.append(body)
            let text = object["devicePublicKey"] as! String
            var encoded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            let key = Data(base64Encoded: encoded)!; device = key
            let gate = beginGate; beginGate = nil; if let gate { await gate.pause() }
            response = ["ok": true, "challenge": ["purpose": "cliphoard.device-approval", "version": 1,
                "algorithm": "P256-SHA256", "entitlementID": entitlementID, "devicePublicKey": text,
                "deviceKeyHash": DeviceLicenceVerifier.encode(Data(SHA256.hash(data: key))),
                "challengeID": DeviceLicenceVerifier.encode(Data(repeating: 20, count: 16)),
                "nonce": DeviceLicenceVerifier.encode(Data(repeating: 21, count: 32)), "expiresAt": 1767323645]]
        } else {
            guard request.url?.path == "/device-licensing/v1/approve", let device else {
                throw DeviceLicenceApprovalClientFailure.invalidRequest
            }
            approvals.append(body)
            let existed = issued[body] != nil
            if !existed { issued[body] = try envelope(for: device) }
            let gate = approveGate; approveGate = nil; if let gate { await gate.pause() }
            if failApproval { throw DeviceLicenceApprovalClientFailure.transportUncertain }
            response = ["ok": true, "code": existed ? "already_issued" : "issued", "receipt": issued[body]!]
        }
        return .init(statusCode: 200, headers: ["Content-Type": "application/json"],
                     body: try JSONSerialization.data(withJSONObject: response, options: .sortedKeys))
    }
}

@MainActor
struct ApplicationFixture {
    let root: URL
    let identityStorage = ApplicationIdentityStorage(), keys = ApplicationKeys()
    let io = ApplicationFileIO(), ids = ApplicationIDs(), clock = ApplicationClock()
    let issuer = P256.Signing.PrivateKey()
    let transport: ApplicationTransport
    let entitlement = DeviceLicenceVerifier.encode(Data(repeating: 1, count: 16))
    init() throws {
        // A fresh task-owned directory only. Resolve /var and /tmp aliases before
        // giving the repository its explicit physical path; never change ancestors.
        guard let path = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(path) }
        root = URL(fileURLWithPath: String(cString: path), isDirectory: true)
            .appendingPathComponent("cliphoard-native-session-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        transport = ApplicationTransport(entitlementID: entitlement, issuer: issuer)
    }
    var receiptURL: URL { root.appendingPathComponent("approved.receipt") }
    var token: String { DeviceLicenceVerifier.encode(Data(repeating: 30, count: 32)) }
    func configuration(pin: Data? = nil, issuerKey: Data? = nil, entitlementID: String? = nil,
                       origin: URL? = nil, path: URL? = nil) -> DeviceLicenceApplicationConfiguration {
        .init(origin: origin ?? URL(string: "https://synthetic.example.invalid")!,
              entitlementID: entitlementID ?? entitlement,
              entitlementHandle: DeviceLicenceVerifier.encode(Data(repeating: 2, count: 32)),
              issuerKeyID: "synthetic-session", issuerPublicKey: issuerKey ?? issuer.publicKey.x963Representation,
              expectedDevicePublicKey: pin, receiptFileURL: path ?? receiptURL,
              identityKeychainService: "synthetic.session", identityKeychainAccount: "synthetic-device", resourceTimeout: 20)
    }
    func session(_ config: DeviceLicenceApplicationConfiguration? = nil) throws -> DeviceLicenceApplicationSession {
        try .init(configuration: config ?? configuration(), identityStorage: identityStorage, identityKeys: keys,
                  transport: transport, receiptIO: io, now: { [clock] in clock.now() }, makeRequestID: { [ids] in ids.next() })
    }
    func seed() async throws -> String {
        let identity = try DeviceIdentity(storage: identityStorage, keys: keys)
        let key = try await identity.createIfAbsent().get()
        let envelope = try await transport.envelope(for: key)
        _ = try await DeviceLicenceReceiptRepository(fileURL: receiptURL).replace(envelope, expectedRevision: nil, permit: .init())
        return envelope
    }
    func activate(_ session: DeviceLicenceApplicationSession) async throws {
        await session.start()?.value
        await session.requestApprovalForThisMac()?.value
        XCTAssertEqual(session.approvalState.phase, .awaitingCode)
        await session.submitEmailCode(token)?.value
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
final class DeviceLicenceApplicationSessionTests: XCTestCase {
    func testConstructionOpeningAndPreStartActionsHaveNoEffects() async throws {
        let f = try ApplicationFixture(); defer { f.cleanup() }
        let session = try f.session()
        session.openPanel(); session.openPanel(); session.closePanel(); session.openPanel()
        XCTAssertEqual(session.lifecycle, .idle); XCTAssertTrue(session.isPanelPresented)
        XCTAssertNil(session.requestApprovalForThisMac()); XCTAssertNil(session.restoreSavedApproval())
        XCTAssertNil(session.submitEmailCode(f.token)); XCTAssertNil(session.importApprovedReceipt("invalid"))
        let counts = await (f.keys.availabilityChecks, f.identityStorage.reads, f.transport.begins.count)
        XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0); XCTAssertEqual(counts.2, 0)
        XCTAssertEqual(f.ids.calls, 0); XCTAssertEqual(f.io.readCalls, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.path), [])
        // Native construction itself is also inert, including an absent parent.
        _ = try DeviceLicenceApplicationSession.native(configuration: f.configuration(path: f.root.appendingPathComponent("absent/receipt")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.path), [])
    }
    func testStartRestoresOnceWithoutCreatingIdentityOrNetworkAndBadPasteAllowsConsent() async throws {
        let f = try ApplicationFixture(); defer { f.cleanup() }
        let session = try f.session()
        await session.start()?.value; XCTAssertNil(session.start())
        XCTAssertEqual(session.lifecycle, .running); XCTAssertEqual(session.approvalState.notice, .identityMissing)
        XCTAssertFalse(session.isProApproved)
        await session.importApprovedReceipt("CLIPD1.YQ.Yg")?.value
        XCTAssertTrue(session.approvalState.canRequest)
        let before = await (f.keys.creations, f.transport.begins.count)
        XCTAssertEqual(before.0, 0); XCTAssertEqual(before.1, 0)
        await session.requestApprovalForThisMac()?.value
        let after = await (f.keys.creations, f.transport.begins.count)
        XCTAssertEqual(after.0, 1); XCTAssertEqual(after.1, 1)
        XCTAssertEqual(session.approvalState.notice, .approvalQueued)
        XCTAssertFalse(session.isProApproved)
    }
    func testOnlyVerifiedPersistedReceiptPublishesProAndRelaunchProvesPossessionOffline() async throws {
        let f = try ApplicationFixture(); defer { f.cleanup() }
        let first = try f.session()
        var observed: [Bool] = []
        let subscription = first.$state.sink { observed.append($0.isProApproved) }
        try await f.activate(first)
        XCTAssertTrue(first.isProApproved); XCTAssertTrue(observed.contains(true))
        let saved = try await DeviceLicenceReceiptRepository(fileURL: f.receiptURL).read()
        XCTAssertNotNil(saved.envelope)
        let before = await (f.keys.creations, f.keys.signatures, f.transport.begins.count, f.transport.approvals.count)
        first.stop(); f.clock.change(UInt64.max)
        let relaunched = try f.session(); await relaunched.start()?.value
        XCTAssertTrue(relaunched.isProApproved); XCTAssertEqual(relaunched.approvalState.notice, .recovered)
        let after = await (f.keys.creations, f.keys.signatures, f.transport.begins.count, f.transport.approvals.count)
        XCTAssertEqual(after.0, before.0); XCTAssertGreaterThan(after.1, before.1)
        XCTAssertEqual(after.2, before.2); XCTAssertEqual(after.3, before.3)
        let unchanged = try await DeviceLicenceReceiptRepository(fileURL: f.receiptURL).read()
        XCTAssertEqual(unchanged, saved)
        withExtendedLifetime(subscription) {}
    }
    func testCloseDuringBeginAndReopenRetainsExactRequestWithoutAutomaticReplay() async throws {
        let f = try ApplicationFixture(); defer { f.cleanup() }
        let session = try f.session(); await session.start()?.value
        let gate = ApplicationGate(); await f.transport.holdBegin(gate)
        let task = session.requestApprovalForThisMac(); await gate.wait()
        session.closePanel(); session.openPanel(); await gate.release(); await task?.value
        XCTAssertEqual(session.approvalState.retry, .sameRequest); XCTAssertFalse(session.isProApproved)
        let count = await f.transport.begins.count; XCTAssertEqual(count, 1)
        await session.retrySameOperation()?.value
        let bodies = await f.transport.begins
        XCTAssertEqual(bodies.count, 2); XCTAssertEqual(bodies[0], bodies[1]); XCTAssertEqual(f.ids.calls, 1)
        let creations = await f.keys.creations; XCTAssertEqual(creations, 1)
        XCTAssertEqual(session.approvalState.phase, .awaitingCode)
    }
    func testCloseDuringApprovalRetainsExactSignedBodyAndOneIssuedReceipt() async throws {
        let f = try ApplicationFixture(); defer { f.cleanup() }
        let session = try f.session(); await session.start()?.value; await session.requestApprovalForThisMac()?.value
        let gate = ApplicationGate(); await f.transport.holdApproval(gate)
        let task = session.submitEmailCode(f.token); await gate.wait()
        session.closePanel(); session.openPanel(); await gate.release(); await task?.value
        XCTAssertFalse(session.isProApproved); XCTAssertEqual(session.approvalState.retry, .sameRequest)
        let signatures = await f.keys.signatures
        await session.retrySameOperation()?.value
        let values = await (f.transport.approvals, f.transport.mintCount, f.keys.signatures)
        XCTAssertEqual(values.0.count, 2); XCTAssertEqual(values.0[0], values.0[1]); XCTAssertEqual(values.1, 1)
        // Retry does not re-sign approval; the one extra signature is local receipt proof.
        XCTAssertEqual(values.2, signatures + 1); XCTAssertTrue(session.isProApproved)
    }
    func testPendingServiceReceiptSurvivesCloseAndBadManualImportForLocalSaveRetry() async throws {
        let f = try ApplicationFixture(); defer { f.cleanup() }
        let session = try f.session(); f.io.set(.write)
        try await f.activate(session)
        XCTAssertFalse(session.isProApproved); XCTAssertEqual(session.approvalState.retry, .saveReceipt)
        session.closePanel(); session.openPanel()
        await session.importApprovedReceipt("CLIPD1.YQ.Yg")?.value
        XCTAssertEqual(session.approvalState.retry, .saveReceipt)
        f.io.set(.none); await session.retrySameOperation()?.value
        XCTAssertTrue(session.isProApproved)
        let approvals = await f.transport.approvals.count; XCTAssertEqual(approvals, 1)
    }
    func testUncertainCommitRequiresRestoreAndAcceptsAuthoritativeAbsenceOrSavedReceipt() async throws {
        for fault in [ApplicationFileIO.Fault.beforeRename, .afterRename] {
            let f = try ApplicationFixture(); defer { f.cleanup() }
            let session = try f.session(); f.io.set(fault); try await f.activate(session)
            XCTAssertFalse(session.isProApproved); XCTAssertEqual(session.approvalState.phase, .recoveryRequired)
            XCTAssertNil(session.requestApprovalForThisMac()); XCTAssertNil(session.submitEmailCode(f.token))
            XCTAssertNil(session.importApprovedReceipt("CLIPD1.YQ.Yg"))
            f.io.set(.none); session.closePanel(); session.openPanel()
            await session.restoreSavedApproval()?.value
            if fault == .beforeRename {
                XCTAssertFalse(session.isProApproved); XCTAssertEqual(session.approvalState.retry, .saveReceipt)
                await session.retrySameOperation()?.value
            }
            XCTAssertTrue(session.isProApproved)
            let counts = await (f.transport.begins.count, f.transport.approvals.count)
            XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 1)
        }
    }
    func testStopDuringRestoreFencesLateProofAndAllFutureActions() async throws {
        let f = try ApplicationFixture(); defer { f.cleanup() }
        _ = try await f.seed()
        let session = try f.session(), gate = ApplicationGate(); await f.keys.holdSignature(gate)
        let task = session.start(); await gate.wait(); session.stop()
        let stopped = session.state
        session.openPanel(); await gate.release(); await task?.value
        XCTAssertEqual(session.state, stopped); XCTAssertEqual(session.lifecycle, .stopped)
        XCTAssertFalse(session.isPanelPresented); XCTAssertFalse(session.isProApproved)
        XCTAssertNil(session.start()); XCTAssertNil(session.restoreSavedApproval())
        XCTAssertNil(session.requestApprovalForThisMac()); XCTAssertNil(session.submitEmailCode(f.token))
        XCTAssertNil(session.importApprovedReceipt("invalid")); XCTAssertNil(session.retrySameOperation())
        session.cancelLocalWork(); session.useDifferentCode(); session.closePanel()
        XCTAssertEqual(session.state, stopped)
        let newSession = try f.session(); await newSession.start()?.value; XCTAssertTrue(newSession.isProApproved)
    }
    func testStopDuringIdentityReadCannotRestartOrCreateAReplacement() async throws {
        let f = try ApplicationFixture(); defer { f.cleanup() }
        let session = try f.session(), gate = ApplicationGate(); await f.identityStorage.hold(gate)
        let task = session.start(); await gate.wait(); session.stop(); let stopped = session.state
        await gate.release(); await task?.value; session.openPanel()
        XCTAssertEqual(session.state, stopped)
        let counts = await (f.keys.creations, f.transport.begins.count)
        XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0)
    }
    func testKnownIdentityLossAndMismatchNeverRegenerate() async throws {
        let f = try ApplicationFixture(); defer { f.cleanup() }
        let session = try f.session(); await session.start()?.value; await session.requestApprovalForThisMac()?.value
        await f.identityStorage.removeForTest()
        await session.restoreSavedApproval()?.value
        await session.requestApprovalForThisMac()?.value; await session.retrySameOperation()?.value
        let creations = await f.keys.creations; XCTAssertEqual(creations, 1)
        XCTAssertFalse(session.isProApproved)
        let known = await f.keys.publicBytes()
        let relaunch = try f.session(f.configuration(pin: known)); await relaunch.start()?.value
        await relaunch.requestApprovalForThisMac()?.value
        let finalCreations = await f.keys.creations; XCTAssertEqual(finalCreations, 1)
        XCTAssertEqual(relaunch.approvalState.notice, .identityMissing)
    }
    func testPinnedDeviceIssuerAndEntitlementRejectWithoutReceiptDerivedTrust() async throws {
        let f = try ApplicationFixture(); defer { f.cleanup() }
        _ = try await f.seed(); let original = try Data(contentsOf: f.receiptURL)
        let foreign = P256.Signing.PrivateKey().publicKey.x963Representation
        let configurations = [f.configuration(pin: foreign), f.configuration(issuerKey: foreign),
            f.configuration(entitlementID: DeviceLicenceVerifier.encode(Data(repeating: 8, count: 16)))]
        for config in configurations {
            let session = try f.session(config); await session.start()?.value
            XCTAssertFalse(session.isProApproved); XCTAssertEqual(try Data(contentsOf: f.receiptURL), original)
        }
        let counts = await (f.keys.creations, f.transport.begins.count, f.transport.approvals.count)
        XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 0); XCTAssertEqual(counts.2, 0)
    }
    func testCorruptPriorBytesArePreservedAndNeverTreatedAsApproved() async throws {
        let f = try ApplicationFixture(); defer { f.cleanup() }
        _ = try await f.seed(); let corrupt = Data("damaged-record".utf8); try corrupt.write(to: f.receiptURL)
        let session = try f.session(); await session.start()?.value
        XCTAssertFalse(session.isProApproved); XCTAssertEqual(session.approvalState.notice, .savedDataProblem)
        let envelope = try await f.transport.envelope(for: f.keys.publicBytes())
        await session.importApprovedReceipt(envelope)?.value
        XCTAssertFalse(session.isProApproved); XCTAssertEqual(try Data(contentsOf: f.receiptURL), corrupt)
    }
    func testLastGoodProSurvivesClockStorageAndHardwareFailureAndStop() async throws {
        let f = try ApplicationFixture(); defer { f.cleanup() }
        _ = try await f.seed(); let original = try Data(contentsOf: f.receiptURL)
        let session = try f.session(); await session.start()?.value; XCTAssertTrue(session.isProApproved)
        f.clock.change(UInt64.max); f.io.set(.read); await session.restoreSavedApproval()?.value
        XCTAssertTrue(session.isProApproved)
        f.io.set(.none); await f.keys.setAvailable(false); await session.restoreSavedApproval()?.value
        XCTAssertTrue(session.isProApproved)
        session.closePanel(); session.openPanel(); session.stop(); XCTAssertTrue(session.isProApproved)
        XCTAssertEqual(try Data(contentsOf: f.receiptURL), original)
        let calls = await f.transport.begins.count + f.transport.approvals.count; XCTAssertEqual(calls, 0)
    }
    func testInvalidConfigurationFailsBeforeAnyAdapterOperation() async throws {
        let f = try ApplicationFixture(); defer { f.cleanup() }
        let cases = [f.configuration(origin: URL(string: "http://synthetic.example.invalid")!),
                     f.configuration(pin: Data([4])), f.configuration(issuerKey: Data([4])),
                     f.configuration(path: URL(string: "https://synthetic.example.invalid/receipt")!)]
        for config in cases {
            XCTAssertThrowsError(try f.session(config)) { error in
                XCTAssertEqual(error as? DeviceLicenceApplicationFailure, .invalidConfiguration)
            }
        }
        let counts = await (f.keys.availabilityChecks, f.identityStorage.reads, f.transport.begins.count)
        XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0); XCTAssertEqual(counts.2, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.path), [])
    }
    func testSynchronousStateObserverCanCloseDuringSavingWithoutStrandingRestore() async throws {
        let f = try ApplicationFixture(); defer { f.cleanup() }
        let session = try f.session()
        var closed = false
        let observer = session.$state.sink { value in
            if !closed, value.approval.phase == .working(.saving) {
                closed = true; session.closePanel()
            }
        }
        try await f.activate(session)
        XCTAssertTrue(closed); XCTAssertFalse(session.isProApproved)
        XCTAssertEqual(session.approvalState.phase, .recoveryRequired)
        let restoring = session.restoreSavedApproval()
        XCTAssertNotNil(restoring, "local cancellation must leave a usable authoritative restore")
        await restoring?.value
        XCTAssertNotEqual(session.approvalState.phase, .recoveryRequired)
        withExtendedLifetime(observer) {}
    }
    func testSynchronousObserverStopAtStartIsTerminalAndRejectsReentrantApproval() async throws {
        let f = try ApplicationFixture(); defer { f.cleanup() }
        let session = try f.session()
        var stopped = false
        let observer = session.$state.sink { value in
            if !stopped, value.lifecycle == .running {
                stopped = true
                XCTAssertNil(session.requestApprovalForThisMac())
                session.stop()
            }
        }
        await session.start()?.value
        XCTAssertTrue(stopped); XCTAssertEqual(session.lifecycle, .stopped)
        XCTAssertFalse(session.isProApproved); XCTAssertNil(session.start())
        let counts = await (f.keys.creations, f.transport.begins.count)
        XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0)
        withExtendedLifetime(observer) {}
    }
}
#endif
