import XCTest
import CryptoKit
import Darwin
@testable import Cliphoard

final class AgentWriteProtocolTests: XCTestCase {
    private let now = 1_800_000_000.0
    private func fixture(text: String = "A public project note") -> (Curve25519.KeyAgreement.PrivateKey, AgentWriteProtocol.Session, AgentWriteProtocol.Request) {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let session = AgentWriteProtocol.Session(sessionID: UUID(), expiresAt: now + 900,
                                                  publicKey: key.publicKey.rawRepresentation)
        return (key, session, AgentWriteProtocol.Request(sessionID: session.sessionID,
                                                        requestID: UUID(), createdAt: now, text: text))
    }
    func testEncryptedRoundTripAndAuthenticatedReceipt() throws {
        let (key, session, request) = fixture()
        let prepared = try AgentWriteProtocol.prepare(request, session: session, now: now)
        XCTAssertNil(prepared.data.range(of: Data(request.text.utf8)))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.data) as? [String: Any])
        let ciphertext = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(envelope["sealed"] as? String)))
        XCTAssertEqual(prepared.requestDigest, SHA256.hash(data: ciphertext).map { String(format: "%02x", $0) }.joined())
        let opened = try AgentWriteProtocol.open(prepared.data, session: session, privateKey: key, now: now)
        XCTAssertEqual(opened.request, request)
        for status in [AgentWriteProtocol.Status.saved, .rejected, .expired, .unavailable] {
            let bytes = try AgentWriteProtocol.sealReceipt(status: status, opened: opened)
            XCTAssertNil(bytes.range(of: Data(request.text.utf8)))
            let receipt = try AgentWriteProtocol.openReceipt(bytes, prepared: prepared,
                expectedSessionID: session.sessionID, expectedRequestID: request.requestID)
            XCTAssertEqual(receipt.status, status)
            XCTAssertEqual(receipt.clipID, status == .saved ? request.requestID : nil)
        }
    }
    func testSessionManifestStrictSchemaAndBounds() throws {
        let (_, session, _) = fixture()
        let data = try AgentWriteProtocol.encodeSession(session, now: now)
        XCTAssertEqual(try AgentWriteProtocol.decodeSession(data, now: now), session)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["unexpected"] = "ignored fields must not pass"
        XCTAssertThrowsError(try AgentWriteProtocol.decodeSession(JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), now: now))
        let duplicate = Data((String(decoding: data, as: UTF8.self).dropLast() + ",\"version\":1}").utf8)
        XCTAssertThrowsError(try AgentWriteProtocol.decodeSession(duplicate, now: now))
        XCTAssertThrowsError(try AgentWriteProtocol.decodeSession(data, now: now + 900))
        XCTAssertThrowsError(try AgentWriteProtocol.decodeSession(data, now: now - 10))
        XCTAssertThrowsError(try AgentWriteProtocol.decodeSession(Data(repeating: 32, count: 1_025), now: now))
    }
    func testRequestExpiryTextLimitAndSessionMismatch() throws {
        let (_, session, request) = fixture()
        XCTAssertThrowsError(try AgentWriteProtocol.prepare(request, session: session, now: now + 120))
        XCTAssertThrowsError(try AgentWriteProtocol.prepare(request, session: session, now: now - 6))
        for text in ["  \n", "a\0b", String(repeating: "é", count: 16_385)] {
            let (_, s, r) = fixture(text: text)
            XCTAssertThrowsError(try AgentWriteProtocol.prepare(r, session: s, now: now))
        }
        let (_, s, r) = fixture(text: String(repeating: "a", count: 32_768))
        XCTAssertNoThrow(try AgentWriteProtocol.prepare(r, session: s, now: now))
        var wrong = request; wrong.sessionID = UUID()
        XCTAssertThrowsError(try AgentWriteProtocol.prepare(wrong, session: session, now: now))
    }
    func testTamperWrongKeyAndCiphertextDirectionRejected() throws {
        let (key, session, request) = fixture()
        let prepared = try AgentWriteProtocol.prepare(request, session: session, now: now)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.data) as? [String: Any])
        var sealed = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(json["sealed"] as? String)))
        sealed[sealed.count - 1] ^= 1; json["sealed"] = sealed.base64EncodedString()
        let damaged = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertThrowsError(try AgentWriteProtocol.open(damaged, session: session, privateKey: key, now: now))
        XCTAssertThrowsError(try AgentWriteProtocol.open(prepared.data, session: session,
            privateKey: Curve25519.KeyAgreement.PrivateKey(), now: now))
        let opened = try AgentWriteProtocol.open(prepared.data, session: session, privateKey: key, now: now)
        let receipt = try AgentWriteProtocol.sealReceipt(status: .saved, opened: opened)
        XCTAssertThrowsError(try AgentWriteProtocol.open(receipt, session: session, privateKey: key, now: now))
        XCTAssertThrowsError(try AgentWriteProtocol.openReceipt(prepared.data, prepared: prepared,
            expectedSessionID: session.sessionID, expectedRequestID: request.requestID))
        XCTAssertThrowsError(try AgentWriteProtocol.openReceipt(receipt, prepared: prepared,
            expectedSessionID: UUID(), expectedRequestID: request.requestID))
    }
    func testReceiptCannotAcknowledgeDifferentPayloadWithSameID() throws {
        let (key, session, request) = fixture()
        let first = try AgentWriteProtocol.prepare(request, session: session, now: now)
        let opened = try AgentWriteProtocol.open(first.data, session: session, privateKey: key, now: now)
        let receipt = try AgentWriteProtocol.sealReceipt(status: .saved, opened: opened)
        var changed = request; changed.text = "A different public note"
        let second = try AgentWriteProtocol.prepare(changed, session: session, now: now)
        XCTAssertThrowsError(try AgentWriteProtocol.openReceipt(receipt, prepared: second,
            expectedSessionID: session.sessionID, expectedRequestID: request.requestID))
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Cliphoard-Agent-Protocol-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testDirectoryExclusivePublicationAndMissingRead() throws {
        let url = try temporaryDirectory(); let directory = try AgentWriteDirectory(url: url)
        let name = UUID().uuidString.lowercased() + ".request"
        XCTAssertNil(try directory.read(name, maxBytes: 32))
        try directory.writeExclusive(name, data: Data("encrypted-fixture".utf8))
        XCTAssertEqual(try directory.read(name, maxBytes: 32), Data("encrypted-fixture".utf8))
        XCTAssertThrowsError(try directory.writeExclusive(name, data: Data("replacement".utf8)))
        XCTAssertEqual(try directory.requestNames(), [name])
        XCTAssertThrowsError(try directory.read(name, maxBytes: 2))
        try directory.remove(name); XCTAssertNil(try directory.read(name, maxBytes: 32))
        XCTAssertThrowsError(try directory.writeExclusive("../outside.request", data: Data()))
    }
    func testDirectoryRejectsSymlinksHardlinksAndPermissions() throws {
        let url = try temporaryDirectory(); let directory = try AgentWriteDirectory(url: url)
        let target = url.appendingPathComponent("target")
        try Data("fixture".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let symlink = UUID().uuidString.lowercased() + ".request"
        try FileManager.default.createSymbolicLink(atPath: url.appendingPathComponent(symlink).path, withDestinationPath: target.path)
        XCTAssertThrowsError(try directory.read(symlink, maxBytes: 32))
        let hardlink = UUID().uuidString.lowercased() + ".request"
        XCTAssertEqual(Darwin.link(target.path, url.appendingPathComponent(hardlink).path), 0)
        XCTAssertThrowsError(try directory.read(hardlink, maxBytes: 32))
        let permissive = UUID().uuidString.lowercased() + ".request"
        try directory.writeExclusive(permissive, data: Data("fixture".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.appendingPathComponent(permissive).path)
        XCTAssertThrowsError(try directory.read(permissive, maxBytes: 32))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        XCTAssertThrowsError(try AgentWriteDirectory(url: url))
    }
    func testDirectoryDescriptorSurvivesPathSubstitution() throws {
        let parent = try temporaryDirectory(); let original = parent.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let directory = try AgentWriteDirectory(url: original)
        let moved = parent.appendingPathComponent("original")
        try FileManager.default.moveItem(at: original, to: moved)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try directory.writeExclusive("session.json", data: Data("original only".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("session.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.appendingPathComponent("session.json").path))
    }
    func testDirectoryQueueBound() throws {
        let directory = try AgentWriteDirectory(url: temporaryDirectory())
        for _ in 0..<3 { try directory.writeExclusive(UUID().uuidString.lowercased() + ".request", data: Data()) }
        XCTAssertThrowsError(try directory.requestNames(limit: 2))
        XCTAssertEqual(try directory.requestNames(limit: 3).count, 3)
    }
}
