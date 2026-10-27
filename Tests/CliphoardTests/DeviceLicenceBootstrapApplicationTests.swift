#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE && !APP_STORE
import XCTest
import CryptoKit
import Foundation
@testable import Cliphoard

actor BootstrapIdentityStorage: DeviceIdentityStorage {
    private var record: Data?
    private(set) var reads = 0, inserts = 0
    func read() -> Data? { reads += 1; return record }
    func insertIfAbsent(_ value: Data) -> Bool {
        inserts += 1; guard record == nil else { return false }; record = value; return true
    }
}
actor BootstrapIdentityKeys: DeviceIdentityKeyOperations {
    private let key = P256.Signing.PrivateKey()
    private(set) var calls = 0, creations = 0
    func isAvailable() -> Bool { calls += 1; return true }
    func create() -> DeviceIdentityMaterial {
        calls += 1; creations += 1
        return .init(publicKeyX963: key.publicKey.x963Representation, wrappedKey: Data([1]))
    }
    func publicKey(for wrappedKey: Data) -> Data { calls += 1; return key.publicKey.x963Representation }
    func sign(_ message: Data, using wrappedKey: Data) throws -> Data { calls += 1; return try key.signature(for: message).rawRepresentation }
}
final class BootstrapNoFileIO: DeviceLicenceReceiptFileIO, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    private func entered() { lock.lock(); count += 1; lock.unlock() }
    func read(_ fd: Int32, maximum: Int) throws -> Data { entered(); throw DeviceLicenceReceiptStorageFailure.io }
    func write(_ bytes: Data, to fd: Int32) throws { entered(); throw DeviceLicenceReceiptStorageFailure.io }
    func synchronize(_ fd: Int32, full: Bool) throws { entered(); throw DeviceLicenceReceiptStorageFailure.io }
    func rename(in directory: Int32, from: String, to: String) throws { entered(); throw DeviceLicenceReceiptStorageFailure.io }
}
final class BootstrapGeneratorCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func id() -> Data { lock.lock(); defer { lock.unlock() }; count += 1; return Data(repeating: 9, count: 16) }
    func now() -> UInt64 { lock.lock(); defer { lock.unlock() }; count += 1; return 1767323045 }
}

@MainActor
final class DeviceLicenceBootstrapApplicationTests: XCTestCase {
    func configuration(_ verified: VerifiedDeviceLicenceBootstrap, root: URL,
                       origin: URL = URL(string: "https://bootstrap.example.invalid")!,
                       timeout: TimeInterval = 20, device: Data? = nil) throws -> DeviceLicenceBootstrapApplicationConfiguration {
        try .init(bootstrap: verified, origin: origin, expectedDevicePublicKey: device,
                  receiptFileURL: root.appendingPathComponent("absent/approved.receipt"),
                  identityKeychainService: "synthetic.bootstrap", identityKeychainAccount: "synthetic-device", resourceTimeout: timeout)
    }
    func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cliphoard-bootstrap-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
    func testVerifiedConfigurationAndBothFactoriesRemainInertUntilExplicitAction() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let f = BootstrapFixture(), keys = BootstrapIdentityKeys(), storage = BootstrapIdentityStorage()
        let transport = BootstrapCaptureTransport(), io = BootstrapNoFileIO(), ids = BootstrapGeneratorCounter()
        let config = try configuration(f.verified(), root: root)
        let session = try DeviceLicenceBootstrapApplication.makeSession(configuration: config, identityStorage: storage,
            identityKeys: keys, transport: transport, receiptIO: io, now: { ids.now() }, makeRequestID: { ids.id() })
        session.openPanel(); session.closePanel(); session.openPanel()
        XCTAssertEqual(session.lifecycle, .idle); XCTAssertFalse(session.isProApproved)
        XCTAssertNil(session.requestApprovalForThisMac()); XCTAssertNil(session.restoreSavedApproval())
        _ = try DeviceLicenceBootstrapApplication.native(configuration: config)
        let counts = await (keys.calls, storage.reads, storage.inserts, transport.requests.count)
        XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0); XCTAssertEqual(counts.2, 0); XCTAssertEqual(counts.3, 0)
        XCTAssertEqual(io.calls, 0); XCTAssertEqual(ids.calls, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])

        await session.start()?.value
        let starting = await (keys.creations, transport.requests.count)
        XCTAssertEqual(starting.0, 0); XCTAssertEqual(starting.1, 0); XCTAssertFalse(session.isProApproved)
        await session.requestApprovalForThisMac()?.value
        let commands = await transport.requests, creations = await keys.creations
        XCTAssertEqual(creations, 1); XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.value(forHTTPHeaderField: "X-Cliphoard-Entitlement"), f.entitlement)
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(commands.first?.httpBody)) as! [String: String]
        XCTAssertEqual(body["entitlementHandle"], f.handle)
        XCTAssertFalse(session.isProApproved) // Even successful bootstrap and key creation are not approval.
    }
    func testMalformedOrCancelledBootstrapConstructionDoesNotTouchExistingSession() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let f = BootstrapFixture(), keys = BootstrapIdentityKeys(), storage = BootstrapIdentityStorage()
        let transport = BootstrapCaptureTransport(), io = BootstrapNoFileIO(), ids = BootstrapGeneratorCounter()
        let verified = try f.verified(), config = try configuration(verified, root: root)
        let session = try DeviceLicenceBootstrapApplication.makeSession(configuration: config, identityStorage: storage,
            identityKeys: keys, transport: transport, receiptIO: io, now: { ids.now() }, makeRequestID: { ids.id() })
        session.openPanel(); let prior = session.state
        XCTAssertThrowsError(try DeviceLicenceBootstrapVerifier.verify("CLIPB1.invalid.invalid", profile: f.profile()))
        XCTAssertThrowsError(try configuration(verified, root: root, timeout: .infinity))
        XCTAssertThrowsError(try configuration(verified, root: root, device: Data([4])))
        XCTAssertThrowsError(try configuration(verified, root: root, origin: URL(string: "https://foreign.invalid/path")!))
        let gate = BootstrapTestGate()
        let cancelled = Task { @MainActor in
            await gate.pause()
            return try DeviceLicenceBootstrapApplication.makeSession(configuration: config, identityStorage: storage,
                identityKeys: keys, transport: transport, receiptIO: io, now: { ids.now() }, makeRequestID: { ids.id() })
        }
        await gate.wait(); cancelled.cancel(); await gate.release()
        do { _ = try await cancelled.value; XCTFail("cancelled factory succeeded") }
        catch { XCTAssertEqual(error as? DeviceLicenceBootstrapFailure, .cancelled) }
        XCTAssertEqual(session.state, prior)
        let counts = await (keys.calls, storage.reads, storage.inserts, transport.requests.count)
        XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0); XCTAssertEqual(counts.2, 0); XCTAssertEqual(counts.3, 0)
        XCTAssertEqual(io.calls, 0); XCTAssertEqual(ids.calls, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
}
#endif
