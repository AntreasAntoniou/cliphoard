import XCTest
@testable import Cliphoard
import Foundation
import CryptoKit

final class AgentWriteControllerTests: XCTestCase {
    @MainActor func testApprovalAndSessionBoundaries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cliphoard-controller-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        func check(_ condition: Bool) { XCTAssertTrue(condition) }
        var time = 1_800_000_000.0; var tick = 1_000.0
        var saves = [(UUID, String)](); var succeed = true; var notices = 0
        let controller = AgentWriteController(save: { id,text in
            if succeed { saves.append((id,text)) }; return succeed
        }, sensitive: { $0.contains("sensitive fixture") }, now: { Date(timeIntervalSince1970: time) }, ticks: { tick })
        controller.onRequest = { notices += 1 }
        func enable() async throws { try await controller.enable(in: root, startTimer: false) }
        func submit(_ text: String = "Public synthetic project note") throws -> (AgentWriteDirectory, AgentWriteProtocol.Session, AgentWriteProtocol.Request, AgentWriteProtocol.Prepared) {
            let directory = try AgentWriteDirectory(url: controller.folder!)
            let session = try AgentWriteProtocol.decodeSession(directory.read("session.json", maxBytes: 1024)!, now: time)
            let request = AgentWriteProtocol.Request(sessionID: session.sessionID, requestID: UUID(), createdAt: time, text: text)
            let prepared = try AgentWriteProtocol.prepare(request, session: session, now: time)
            try directory.writeExclusive(request.requestID.uuidString.lowercased() + ".request", data: prepared.data)
            return (directory, session, request, prepared)
        }
        func receipt(_ f: (AgentWriteDirectory, AgentWriteProtocol.Session, AgentWriteProtocol.Request, AgentWriteProtocol.Prepared)) throws -> AgentWriteProtocol.Receipt {
            try AgentWriteProtocol.openReceipt(f.0.read(f.2.requestID.uuidString.lowercased() + ".reply", maxBytes: 65536)!, prepared: f.3, expectedSessionID: f.1.sessionID, expectedRequestID: f.2.requestID)
        }
        try await enable(); let first = try submit(); await controller.poll()
        XCTAssertTrue(saves.isEmpty && controller.pending?.id == first.2.requestID && notices == 1)
        await controller.approve(); XCTAssertTrue(saves.count == 1 && saves[0].0 == first.2.requestID)
        check(try receipt(first).status == .saved)
        await controller.approve(); await controller.poll(); XCTAssertTrue(saves.count == 1)

        let sensitive = try submit("sensitive fixture"); await controller.poll()
        XCTAssertTrue(controller.pending == nil && notices == 1 && saves.count == 1)
        check(try receipt(sensitive).status == .rejected)
        let declined = try submit(); await controller.poll(); await controller.decline()
        check(try receipt(declined).status == .rejected); XCTAssertTrue(saves.count == 1)
        succeed = false
        let failed = try submit(); await controller.poll(); await controller.approve()
        check(try receipt(failed).status == .unavailable); XCTAssertTrue(saves.count == 1)
        succeed = true
        let cancelled = try submit(); await controller.poll()
        try cancelled.0.remove(cancelled.2.requestID.uuidString.lowercased() + ".request")
        await controller.approve(); XCTAssertTrue(saves.count == 1)
        check(try receipt(cancelled).status == .rejected)
        let expired = try submit(); await controller.poll(); tick += 121; time -= 60
        await controller.approve(); XCTAssertTrue(saves.count == 1)
        check(try receipt(expired).status == .expired)
        controller.disconnect(); time = 1_800_000_000; tick = 1_000
        try await enable(); let end = try submit(); await controller.poll(); tick += 901; time -= 60
        await controller.approve(); check(try receipt(end).status == .expired)
        await controller.poll(); XCTAssertTrue(controller.folder == nil && saves.count == 1)
        time = 1_800_000_000; tick = 1_000; try await enable(); let revoked = try submit(); await controller.poll()
        controller.disconnect(); await controller.approve(); XCTAssertTrue(saves.count == 1 && controller.pending == nil)
        for _ in 0..<100 {
            if try revoked.0.read("session.json", maxBytes: 1024) == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        check(try revoked.0.read("session.json", maxBytes: 1024) == nil)
    }
 @MainActor func testUnconfirmedCommitIsNotReportedAsNoSave() async throws {
  let parent=FileManager.default.temporaryDirectory.appendingPathComponent("cliphoard-unknown-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:false)
  defer { try? FileManager.default.removeItem(at:parent) }
  var committed=false
  let c=AgentWriteController(save:{_,_ in committed=true;return false},sensitive:{_ in false})
  try await c.enable(in:parent,startTimer:false)
  let d=try AgentWriteDirectory(url:c.folder!)
  let s=try AgentWriteProtocol.decodeSession(d.read("session.json",maxBytes:1024)!)
  let r=AgentWriteProtocol.Request(sessionID:s.sessionID,requestID:UUID(),createdAt:Date().timeIntervalSince1970,text:"Synthetic uncertain acknowledgement note")
  let p=try AgentWriteProtocol.prepare(r,session:s)
  try d.writeExclusive(r.requestID.uuidString.lowercased()+".request",data:p.data)
  await c.poll(); await c.approve()
  let receipt=try AgentWriteProtocol.openReceipt(d.read(r.requestID.uuidString.lowercased()+".reply",maxBytes:2048)!,prepared:p,expectedSessionID:s.sessionID,expectedRequestID:r.requestID)
  XCTAssertTrue(committed && receipt.status == .unavailable && c.message.contains("may have completed") && !c.message.contains("Nothing was saved"))
  c.disconnect()
 }
}
