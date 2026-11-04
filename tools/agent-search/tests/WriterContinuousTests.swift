import Foundation
import CryptoKit

@main struct WriterContinuousTests {
    static func check(_ condition: Bool) { precondition(condition) }
    static func main() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cliphoard-continuous-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = try AgentWriteDirectory(url: base)
        let key = Curve25519.KeyAgreement.PrivateKey()
        let host = try AgentWriteProtocol.currentHost()
        let session = AgentWriteProtocol.Session(sessionID: UUID(), expiresAt: nil,
            publicKey: key.publicKey.rawRepresentation, version: 2, lifetime: .whileAppRuns, host: host)
        let manifest = try AgentWriteProtocol.encodeSession(session)
        try directory.writeExclusive("session.json", data: manifest)
        let writer = try WriterConnection(url: base)
        check(writer.deadline == nil)
        var ids: [UUID] = []
        for index in 0..<40 {
            let id = UUID(); ids.append(id)
            check(try writer.write(id: id, text: "Synthetic continuous note \(index)")["status"] == "pending")
            let opened = try AgentWriteProtocol.open(directory.read(id.uuidString.lowercased() + ".request", maxBytes: 65_536)!, session: session, privateKey: key)
            try directory.writeExclusive(id.uuidString.lowercased() + ".reply", data: AgentWriteProtocol.sealReceipt(status: .saved, opened: opened))
            check(try writer.check(id: id)["status"] == "saved")
        }
        check(try directory.requestNames().isEmpty)
        check(try writer.check(id: ids.last!)["status"] == "saved")
        do { _ = try writer.check(id: ids[0]); fatalError("terminal cache unbounded") } catch {}
        var unresolved: [UUID] = []
        for index in 0..<32 {
            let id = UUID(); unresolved.append(id)
            _ = try writer.write(id: id, text: "Uncertain \(index)")
            let opened = try AgentWriteProtocol.open(directory.read(id.uuidString.lowercased() + ".request", maxBytes: 65_536)!, session: session, privateKey: key)
            try directory.writeExclusive(id.uuidString.lowercased() + ".reply", data: AgentWriteProtocol.sealReceipt(status: .unavailable, opened: opened))
            check(try writer.check(id: id)["status"] == "unavailable")
        }
        do { _ = try writer.write(id: UUID(), text: "No capacity"); fatalError("unresolved keys evicted") } catch {}
        check(try writer.check(id: unresolved[0])["status"] == "unavailable")
        check(try directory.requestNames().count == 32)
        try directory.remove("session.json")
        do { try writer.validate(); fatalError("revoked session live") } catch {}
        writer.disconnect()
        check(try directory.requestNames().isEmpty)
        // Exact host identity must match, not just a potentially recycled PID.
        let wrongHost = AgentWriteProtocol.Host(processID: host.processID, startSeconds: host.startSeconds,
            startMicroseconds: host.startMicroseconds + 1, bootSession: host.bootSession)
        let stale = AgentWriteProtocol.Session(sessionID: UUID(), expiresAt: nil,
            publicKey: key.publicKey.rawRepresentation, version: 2, lifetime: .whileAppRuns, host: wrongHost)
        try directory.writeExclusive("session.json", data: AgentWriteProtocol.encodeSession(stale))
        do { _ = try WriterConnection(url: base); fatalError("stale host admitted") } catch {}
        print("PASS native continuous: real kernel identity, 40 terminal saves without reconnect, bounded32 terminal/unknown states, exact cleanup, revocation and stale host rejected")
    }
}
