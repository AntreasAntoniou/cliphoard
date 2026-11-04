import Foundation
import CryptoKit
import Darwin

@main struct WriterConnectionTests {
    static func check(_ condition: Bool) { precondition(condition) }
    static func main() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cliphoard-writer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = try AgentWriteDirectory(url: base)
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let session = AgentWriteProtocol.Session(sessionID: UUID(), expiresAt: Date().timeIntervalSince1970 + 890,
            publicKey: privateKey.publicKey.rawRepresentation)
        let manifest = try AgentWriteProtocol.encodeSession(session)
        try directory.writeExclusive("session.json", data: manifest)
        let writer = try WriterConnection(url: base)
        let note = "Synthetic bicycle note — never a real clipboard"
        let id = UUID(); let name = id.uuidString.lowercased()
        check(try writer.write(id: id, text: note)["status"] == "pending")
        let encrypted = try directory.read(name + ".request", maxBytes: AgentWriteProtocol.maximumWireBytes)!
        check(!String(decoding: encrypted, as: UTF8.self).contains(note))
        let opened = try AgentWriteProtocol.open(encrypted, session: session, privateKey: privateKey)
        check(opened.request.text == note)
        check(try writer.check(id: id)["status"] == "pending")
        // Repeated check is read-only: exact same encrypted request and one file.
        check(try directory.read(name + ".request", maxBytes: AgentWriteProtocol.maximumWireBytes) == encrypted)
        check(try directory.requestNames().count == 1)
        try directory.writeExclusive(name + ".reply", data: AgentWriteProtocol.sealReceipt(status: .saved, opened: opened))
        check(try writer.check(id: id) == ["status": "saved", "request_id": name, "clip_id": name])
        do { _ = try writer.write(id: id, text: "duplicate"); fatalError("duplicate accepted") } catch {}
        check(try directory.requestNames().count == 1)
        let rejected = UUID(); let rejectedName = rejected.uuidString.lowercased()
        _ = try writer.write(id: rejected, text: "reject fixture")
        let rejectedOpened = try AgentWriteProtocol.open(directory.read(rejectedName + ".request", maxBytes: 65_536)!, session: session, privateKey: privateKey)
        try directory.writeExclusive(rejectedName + ".reply", data: AgentWriteProtocol.sealReceipt(status: .rejected, opened: rejectedOpened))
        check(try writer.check(id: rejected)["status"] == "rejected")
        let tampered = UUID(); let tamperedName = tampered.uuidString.lowercased()
        _ = try writer.write(id: tampered, text: "tampered fixture")
        try directory.writeExclusive(tamperedName + ".reply", data: directory.read(name + ".reply", maxBytes: 2_048)!)
        do { _ = try writer.check(id: tampered); fatalError("cross-request receipt accepted") } catch {}
        let collision = UUID(); let collisionName = collision.uuidString.lowercased()
        let unrelated = Data("unrelated ciphertext placeholder".utf8)
        try directory.writeExclusive(collisionName + ".request", data: unrelated)
        check(try writer.write(id: collision, text: "collision fixture")["status"] == "unknown")
        do { _ = try writer.write(id: UUID(), text: String(repeating: "é", count: 16_385)); fatalError("oversize accepted") } catch {}
        do { _ = try writer.write(id: UUID(), text: "  \n"); fatalError("blank accepted") } catch {}
        do { _ = try writer.check(id: UUID()); fatalError("unknown accepted") } catch {}
        // Revocation: missing/replaced manifest prevents write and readback.
        try directory.remove("session.json")
        do { _ = try writer.check(id: id); fatalError("revoked read accepted") } catch {}
        do { _ = try writer.write(id: UUID(), text: "late"); fatalError("revoked write accepted") } catch {}
        try directory.writeExclusive("session.json", data: manifest)
        writer.disconnect()
        check(try directory.read(name + ".request", maxBytes: 65_536) == nil)
        check(try directory.read(name + ".reply", maxBytes: 2_048) == nil)
        check(try directory.read(collisionName + ".request", maxBytes: 65_536) == unrelated)
        check(try directory.read("session.json", maxBytes: 1_024) == manifest)
        do { _ = try writer.check(id: id); fatalError("closed read accepted") } catch {}
        print("PASS native writer: encrypted save/authenticated receipt, read-only reconciliation, duplicate/bounds/revocation fences, cleanup ownership")
    }
}
