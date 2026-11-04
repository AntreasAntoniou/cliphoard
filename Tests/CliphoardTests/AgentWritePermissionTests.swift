import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import Cliphoard

final class AgentWritePermissionTests: XCTestCase {
    enum Failed: Error { case expectation }
    private func require(_ value: Bool) throws { if !value { throw Failed.expectation } }
    @MainActor private final class Fixture {
        let root: URL
        let suite = "Cliphoard.AgentPermission.Tests." + UUID().uuidString
        let defaults: UserDefaults
        var time = 1_800_000_000.0
        var tick = 1_000.0
        var saves = 0
        var notices = 0
        var detector: (String) -> Bool = { $0.contains("sensitive fixture") }
        var saveBody: (() async -> Bool)?
        var identity: () throws -> AgentWriteProtocol.Host = AgentWriteProtocol.currentHost
        var controller: AgentWriteController!
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-permissions-" + UUID().uuidString)
            defaults = UserDefaults(suiteName: suite)!
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            controller = makeController()
        }
        func makeController() -> AgentWriteController {
            let c = AgentWriteController(save: { [weak self] _,_ in
                guard let self else { return false }; self.saves += 1
                return await self.saveBody?() ?? true
            }, sensitive: detector, now: { [weak self] in Date(timeIntervalSince1970: self?.time ?? 0) },
                ticks: { [weak self] in self?.tick ?? 0 }, defaults: defaults, hostIdentity: identity)
            c.onRequest = { [weak self] in self?.notices += 1 }
            return c
        }
        func enable() async throws { try await controller.enable(in: root, startTimer: false) }
        func submit(_ text: String = "Synthetic safe agent note") throws -> (AgentWriteDirectory, AgentWriteProtocol.Prepared, AgentWriteProtocol.Request) {
            let directory = try AgentWriteDirectory(url: controller.folder!)
            let session = try AgentWriteProtocol.decodeSession(directory.read("session.json", maxBytes: 1024)!, now: time)
            let request = AgentWriteProtocol.Request(sessionID: session.sessionID, requestID: UUID(), createdAt: time, text: text)
            let prepared = try AgentWriteProtocol.prepare(request, session: session, now: time)
            try directory.writeExclusive(request.requestID.uuidString.lowercased() + ".request", data: prepared.data)
            return (directory,prepared,request)
        }
        func close() { controller.disconnect(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    }
    private final class ValidationGate: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var count = 0
        static func wait(_ semaphore: DispatchSemaphore) -> Bool { semaphore.wait(timeout: .now() + 5) == .success }
        func waitUntilEntered() -> Bool { entered.wait(timeout: .now() + 5) == .success }
        func scan(_ text: String) -> Bool {
            lock.lock(); count += 1; let shouldWait = count == 2; lock.unlock()
            if shouldWait { entered.signal(); _ = proceed.wait(timeout: .now() + 5) }
            return false
        }
    }
    @MainActor func testDefaultRequiresApproval() async throws {
        let f = try Fixture(); defer { f.close() }
        try require(f.controller.permission == .askEveryTime)
        try await f.enable(); _ = try f.submit(); await f.controller.poll()
        try require(f.saves == 0 && f.notices == 1 && f.controller.pending != nil)
        await f.controller.approve(); try require(f.saves == 1)
    }
    @MainActor func testSessionAutomaticAndExpiryReset() async throws {
        let f = try Fixture(); defer { f.close() }
        f.controller.setPermission(.session)
        try require(f.controller.permission == .askEveryTime)
        try await f.enable(); f.controller.setPermission(.session)
        _ = try f.submit(); await f.controller.poll()
        _ = try f.submit(); await f.controller.poll()
        try require(f.saves == 2 && f.notices == 0 && f.controller.pending == nil)
        f.tick += 901; await f.controller.poll()
        try require(f.controller.folder == nil && f.controller.permission == .askEveryTime)
        f.tick = 1_000; try await f.enable(); _ = try f.submit(); await f.controller.poll()
        try require(f.saves == 2 && f.controller.pending != nil)
    }
    @MainActor func testFullAccessPersistsButDoesNotConnect() async throws {
        let f = try Fixture(); defer { f.close() }
        f.controller.setPermission(.fullAccess); f.controller.disconnect()
        f.controller = f.makeController()
        try require(f.controller.permission == .fullAccess && f.controller.folder == nil)
        try await f.enable(); _ = try f.submit(); await f.controller.poll()
        try require(f.saves == 1 && f.notices == 0)
        f.controller.setPermission(.askEveryTime); f.controller.disconnect(); f.controller = f.makeController()
        try require(f.controller.permission == .askEveryTime)
    }
    @MainActor func testSessionIsNeverPersisted() async throws {
        let f = try Fixture(); defer { f.close() }
        f.controller.setPermission(.fullAccess); try await f.enable(); f.controller.setPermission(.session)
        f.controller.disconnect(); f.controller = f.makeController()
        try require(f.controller.permission == .askEveryTime && f.controller.folder == nil)
    }
    @MainActor func testSensitiveStillRejectedWithoutPrompt() async throws {
        let f = try Fixture(); defer { f.close() }
        try await f.enable(); f.controller.setPermission(.fullAccess)
        let (directory,prepared,request) = try f.submit("sensitive fixture")
        await f.controller.poll()
        let receipt = try AgentWriteProtocol.openReceipt(directory.read(request.requestID.uuidString.lowercased()+".reply", maxBytes: 2048)!, prepared: prepared, expectedSessionID: request.sessionID, expectedRequestID: request.requestID)
        try require(f.saves == 0 && f.notices == 0 && receipt.status == .rejected)
    }
    @MainActor func testDowngradeDuringValidationRequiresApproval() async throws {
        let f = try Fixture(); defer { f.close() }
        let gate = ValidationGate(); f.detector = gate.scan; f.controller = f.makeController()
        try await f.enable(); f.controller.setPermission(.fullAccess); _ = try f.submit()
        let poll = Task { await f.controller.poll() }
        let reached = await Task.detached { gate.waitUntilEntered() }.value
        try require(reached)
        f.controller.setPermission(.session); gate.proceed.signal(); await poll.value
        try require(f.saves == 0 && f.notices == 1 && f.controller.pending != nil)
        await f.controller.poll(); try require(f.saves == 0)
        await f.controller.approve(); try require(f.saves == 1)
    }
    @MainActor func testDisconnectDuringValidationPreventsAutomaticSave() async throws {
        let f = try Fixture(); defer { f.close() }
        let gate = ValidationGate(); f.detector = gate.scan; f.controller = f.makeController()
        try await f.enable(); f.controller.setPermission(.fullAccess); _ = try f.submit()
        let poll = Task { await f.controller.poll() }
        let reached = await Task.detached { gate.waitUntilEntered() }.value
        try require(reached)
        f.controller.disconnect(); gate.proceed.signal(); await poll.value
        try require(f.saves == 0 && f.controller.pending == nil && f.controller.folder == nil)
    }
    @MainActor func testAuthorizedCommitCompletesTruthfullyAfterRevoke() async throws {
        let f = try Fixture(); defer { f.close() }
        var release: CheckedContinuation<Bool, Never>?
        f.saveBody = { await withCheckedContinuation { release = $0 } }
        try await f.enable(); f.controller.setPermission(.fullAccess)
        let (directory, prepared, request) = try f.submit()
        let poll = Task { await f.controller.poll() }
        for _ in 0..<1000 {
            if release != nil { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard let committed = release else { throw Failed.expectation }
        f.controller.setPermission(.askEveryTime); f.controller.disconnect()
        committed.resume(returning: true); await poll.value
        let bytes = try directory.read(request.requestID.uuidString.lowercased()+".reply", maxBytes: 2048)
        let receipt = try AgentWriteProtocol.openReceipt(try XCTUnwrap(bytes), prepared: prepared,
            expectedSessionID: request.sessionID, expectedRequestID: request.requestID)
        try require(f.saves == 1 && receipt.status == .saved)
        try require(f.controller.permission == .askEveryTime && f.controller.folder == nil)
    }

    @MainActor func testContinuousFullLifetimeAndDowngrade() async throws {
        let f = try Fixture(); defer { f.close() }
        f.controller.setPermission(.fullAccess); try await f.enable()
        try require(f.controller.connectionLifetime == .whileAppRuns && f.controller.expiresAt == nil)
        f.tick += 3600; f.time += 3600
        _ = try f.submit(); await f.controller.poll()
        try require(f.saves == 1 && f.controller.folder != nil)
        f.controller.setPermission(.session)
        try require(f.controller.folder == nil && f.controller.permission == .session)
        try await f.enable()
        try require(f.controller.connectionLifetime == .bounded && f.controller.expiresAt != nil)
        _ = try f.submit(); await f.controller.poll(); try require(f.saves == 2)
        f.controller.disconnect(); try require(f.controller.permission == .askEveryTime)
    }
    @MainActor func testUpgradeDoesNotExtendPinnedBoundedConnection() async throws {
        let f = try Fixture(); defer { f.close() }; try await f.enable()
        f.controller.setPermission(.fullAccess)
        try require(f.controller.connectionLifetime == .bounded)
        f.tick += 901; f.time += 901; await f.controller.poll()
        try require(f.controller.folder == nil && f.controller.permission == .fullAccess)
        try await f.enable(); try require(f.controller.connectionLifetime == .whileAppRuns)
    }
    @MainActor func testContinuousCapacityPrunesAfterTTLWithoutDisconnect() async throws {
        let f = try Fixture(); defer { f.close() }; f.controller.setPermission(.fullAccess); try await f.enable()
        for _ in 0..<64 { _ = try f.submit(); await f.controller.poll() }
        try require(f.saves == 64 && f.controller.folder != nil)
        _ = try f.submit(); await f.controller.poll(); try require(f.saves == 64)
        f.tick += 121; f.time += 121
        _ = try f.submit(); await f.controller.poll()
        try require(f.saves == 65 && f.controller.folder != nil)
    }
    @MainActor func testExpiredReplayCannotReviveAfterClockRollback() async throws {
        let f = try Fixture(); defer { f.close() }; f.controller.setPermission(.fullAccess); try await f.enable()
        let (directory, prepared, request) = try f.submit(); await f.controller.poll()
        try require(f.saves == 1)
        try directory.remove(request.requestID.uuidString.lowercased()+".reply")
        f.tick += 121; f.time -= 600
        try directory.writeExclusive(request.requestID.uuidString.lowercased()+".request", data: prepared.data)
        await f.controller.poll(); try require(f.saves == 1 && f.controller.folder != nil)
    }
    func testV2SchemaAndHostInstanceLiveness() throws {
        let host = try AgentWriteProtocol.currentHost()
        try require(AgentWriteProtocol.hostIsAlive(host))
        let wrong = AgentWriteProtocol.Host(processID: host.processID, startSeconds: host.startSeconds + 1,
            startMicroseconds: host.startMicroseconds, bootSession: host.bootSession)
        try require(!AgentWriteProtocol.hostIsAlive(wrong))
        let key = Curve25519.KeyAgreement.PrivateKey()
        let time = Date().timeIntervalSince1970
        let session = AgentWriteProtocol.Session(sessionID: UUID(), expiresAt: nil, publicKey: key.publicKey.rawRepresentation,
            version: 2, lifetime: .whileAppRuns, host: host)
        let data = try AgentWriteProtocol.encodeSession(session, now: time)
        try require(try AgentWriteProtocol.decodeSession(data, now: time + 10000) == session)
        var bad = session; bad.version = 1
        do { _ = try AgentWriteProtocol.encodeSession(bad, now: time); throw Failed.expectation }
        catch AgentWriteProtocol.Failure.invalid {}
        bad = session; bad.lifetime = .bounded
        do { _ = try AgentWriteProtocol.encodeSession(bad, now: time); throw Failed.expectation }
        catch AgentWriteProtocol.Failure.invalid {}
        bad = session; bad.expiresAt = time + 900
        do { _ = try AgentWriteProtocol.encodeSession(bad, now: time); throw Failed.expectation }
        catch AgentWriteProtocol.Failure.invalid {}
        let request = AgentWriteProtocol.Request(sessionID: session.sessionID, requestID: UUID(), createdAt: time, text: "Synthetic continuous request")
        let prepared = try AgentWriteProtocol.prepare(request, session: session, now: time)
        do { _ = try AgentWriteProtocol.open(prepared.data, session: session, privateKey: key, now: time + 121); throw Failed.expectation }
        catch AgentWriteProtocol.Failure.expired {}
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sleep"); process.arguments = ["0.2"]
        try process.run()
        var info = proc_bsdinfo()
        try require(proc_pidinfo(process.processIdentifier, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size)
        let child = AgentWriteProtocol.Host(processID: process.processIdentifier, startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec, bootSession: host.bootSession)
        try require(AgentWriteProtocol.hostIsAlive(child))
        process.waitUntilExit()
        try require(!AgentWriteProtocol.hostIsAlive(child))
    }

    @MainActor func testPermissionChangeDuringCreationRefusesPublication() async throws {
        let f = try Fixture(); defer { f.close() }
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        f.identity = {
            entered.signal(); _ = release.wait(timeout: .now() + 5)
            return try AgentWriteProtocol.currentHost()
        }
        f.controller = f.makeController(); f.controller.setPermission(.fullAccess)
        let enabling = Task { try await f.enable() }
        let ready = await Task.detached { ValidationGate.wait(entered) }.value; try require(ready)
        f.controller.setPermission(.askEveryTime); release.signal(); try await enabling.value
        try require(f.controller.folder == nil && f.controller.permission == .askEveryTime && !f.controller.isWorking)
        let children = try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil)
        try require(children.allSatisfy { !FileManager.default.fileExists(atPath: $0.appendingPathComponent("session.json").path) })
    }
    @MainActor func testUnavailableHostFailsClosedClearly() async throws {
        let f = try Fixture(); defer { f.close() }
        f.identity = { throw Failed.expectation }; f.controller = f.makeController()
        do { try await f.enable(); throw Failed.expectation }
        catch { try require(f.controller.folder == nil && f.controller.message.contains("process identity")) }
        try require(try FileManager.default.contentsOfDirectory(atPath: f.root.path).isEmpty)
    }
    func testV1CompatibilityAndBootMismatch() throws {
        let host = try AgentWriteProtocol.currentHost()
        let wrong = AgentWriteProtocol.Host(processID: host.processID, startSeconds: host.startSeconds,
            startMicroseconds: host.startMicroseconds, bootSession: UUID().uuidString.lowercased())
        try require(!AgentWriteProtocol.hostIsAlive(wrong))
        let time = Date().timeIntervalSince1970, key = Curve25519.KeyAgreement.PrivateKey()
        let session = AgentWriteProtocol.Session(sessionID: UUID(), expiresAt: time + 900, publicKey: key.publicKey.rawRepresentation)
        let data = try AgentWriteProtocol.encodeSession(session, now: time)
        try require(try AgentWriteProtocol.decodeSession(data, now: time) == session)
        try require(!String(decoding: data, as: UTF8.self).contains("lifetime") && !String(decoding: data, as: UTF8.self).contains("host"))
        let request = AgentWriteProtocol.Request(sessionID: session.sessionID, requestID: UUID(), createdAt: time, text: "Synthetic v1 legacy request")
        let prepared = try AgentWriteProtocol.prepare(request, session: session, now: time)
        try require(try AgentWriteProtocol.open(prepared.data, session: session, privateKey: key, now: time).request == request)
    }

}
