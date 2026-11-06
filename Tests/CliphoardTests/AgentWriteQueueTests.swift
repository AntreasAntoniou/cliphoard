import XCTest
import Foundation
import CryptoKit
@testable import Cliphoard

final class AgentWriteQueueTests: XCTestCase {
    @MainActor func testIndependentDecisionsCancellationAndExpiry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        var tick = 100.0
        let time = Date().timeIntervalSince1970
        var saved: [UUID] = []
        var notifications = 0
        let c = AgentWriteController(save: { id, _ in saved.append(id); return true },
            sensitive: { $0.contains("sensitive") }, now: { Date(timeIntervalSince1970: time) },
            ticks: { tick }, defaults: defaults)
        defer { c.disconnect() }
        try await c.enable(in: root, startTimer: false)
        let directory = try AgentWriteDirectory(url: c.folder!)
        let session = try AgentWriteProtocol.decodeSession(directory.read("session.json", maxBytes: 1024)!)
        c.onRequest = { notifications += 1 }
        func submit(_ text: String) throws -> (UUID, AgentWriteProtocol.Prepared) {
            let id = UUID()
            let request = AgentWriteProtocol.Request(sessionID: session.sessionID, requestID: id, createdAt: time, text: text)
            let prepared = try AgentWriteProtocol.prepare(request, session: session)
            try directory.writeExclusive(id.uuidString.lowercased() + ".request", data: prepared.data)
            return (id, prepared)
        }
        func status(_ entry: (UUID, AgentWriteProtocol.Prepared)) throws -> AgentWriteProtocol.Status {
            try AgentWriteProtocol.openReceipt(directory.read(entry.0.uuidString.lowercased() + ".reply", maxBytes: 2048)!,
                prepared: entry.1, expectedSessionID: session.sessionID, expectedRequestID: entry.0).status
        }
        let a = try submit("Synthetic first note")
        let b = try submit("Synthetic second note")
        let cancelled = try submit("Synthetic cancelled note")
        let secret = try submit("sensitive fixture")
        await c.poll()
        XCTAssertEqual(Set(c.pendingNotes.map(\.id)), Set([a.0, b.0, cancelled.0]))
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(try status(secret), .rejected)
        XCTAssertTrue(saved.isEmpty)
        await c.approve(id: b.0, expectedBytes: a.1.data)
        XCTAssertTrue(saved.isEmpty, "A stale card must not authorize different displayed bytes")
        await c.approve(id: b.0, expectedBytes: b.1.data)
        XCTAssertEqual(saved, [b.0])
        XCTAssertEqual(Set(c.pendingNotes.map(\.id)), Set([a.0, cancelled.0]))
        await c.decline(id: a.0)
        XCTAssertEqual(try status(a), .rejected)
        XCTAssertEqual(try status(b), .saved)
        try directory.remove(cancelled.0.uuidString.lowercased() + ".request")
        await c.poll()
        XCTAssertTrue(c.pendingNotes.isEmpty)
        let expired = try submit("Synthetic expiring note")
        await c.poll()
        tick += 121
        await c.approve(id: expired.0)
        XCTAssertEqual(try status(expired), .expired)
        XCTAssertEqual(saved, [b.0])
        await c.approve(id: b.0)
        XCTAssertEqual(saved, [b.0])
    }
    @MainActor func testQueueCapacityAndRevocation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var saved = 0
        var notices = 0
        let c = AgentWriteController(save: { _, _ in saved += 1; return true }, sensitive: { _ in false },
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
        try await c.enable(in: root, startTimer: false)
        let d = try AgentWriteDirectory(url: c.folder!)
        let session = try AgentWriteProtocol.decodeSession(d.read("session.json", maxBytes: 1024)!)
        c.onRequest = { notices += 1 }
        for i in 0..<33 {
            let request = AgentWriteProtocol.Request(sessionID: session.sessionID, requestID: UUID(),
                createdAt: Date().timeIntervalSince1970, text: "Synthetic queue note \(i)")
            try d.writeExclusive(request.requestID.uuidString.lowercased() + ".request",
                data: AgentWriteProtocol.prepare(request, session: session).data)
        }
        await c.poll()
        XCTAssertEqual(c.pendingNotes.count, 32)
        XCTAssertEqual(notices, 1)
        await c.poll()
        XCTAssertEqual(notices, 1)
        await c.decline(id: c.pendingNotes[12].id)
        await c.poll()
        XCTAssertEqual(c.pendingNotes.count, 32)
        XCTAssertEqual(notices, 2)
        let staleID = c.pendingNotes[0].id
        c.disconnect()
        await c.approve(id: staleID)
        XCTAssertTrue(c.pendingNotes.isEmpty)
        XCTAssertEqual(saved, 0)
    }

}
