import Foundation

/// A session's response keys stay in this process. No history database or clipboard access.
final class WriterConnection {
    enum Failure: Error { case disconnected, invalid, capacity }
    let session: AgentWriteProtocol.Session
    let deadline: TimeInterval?
    private let directory: AgentWriteDirectory
    private let manifest: Data
    private var prepared: [UUID: AgentWriteProtocol.Prepared] = [:]
    private var created: [UUID: TimeInterval] = [:]
    private var completed: [UUID: [String: String]] = [:]
    private var completionOrder: [UUID] = []
    private var closed = false

    init(url: URL) throws {
        directory = try AgentWriteDirectory(url: url)
        guard let data = try directory.read("session.json", maxBytes: 1_024) else { throw Failure.invalid }
        manifest = data
        session = try AgentWriteProtocol.decodeSession(data)
        deadline = session.expiresAt.map { ProcessInfo.processInfo.systemUptime + min(900, $0 - Date().timeIntervalSince1970) }
        try validate()
    }

    func validate() throws {
        guard !closed, deadline.map({ ProcessInfo.processInfo.systemUptime < $0 }) ?? true,
              try directory.read("session.json", maxBytes: 1_024) == manifest else { throw Failure.disconnected }
        try AgentWriteProtocol.validateSession(session)
        if let host = session.host, !AgentWriteProtocol.hostIsAlive(host) { throw Failure.disconnected }
    }

    func write(id: UUID, text: String) throws -> [String: String] {
        try validate()
        guard prepared[id] == nil, completed[id] == nil else { throw Failure.invalid }
        guard prepared.count < 32 else { throw Failure.capacity }
        let request = AgentWriteProtocol.Request(sessionID: session.sessionID, requestID: id,
            createdAt: Date().timeIntervalSince1970, text: text)
        let value = try AgentWriteProtocol.prepare(request, session: session)
        // Retain before publication: a failed fsync can mean publication already happened.
        prepared[id] = value
        created[id] = ProcessInfo.processInfo.systemUptime
        do {
            try directory.writeExclusive(name(id, ".request"), data: value.data)
            return result("pending", id)
        } catch {
            return result("unknown", id)
        }
    }

    func check(id: UUID) throws -> [String: String] {
        try validate()
        if let response = completed[id] { return response }
        guard let value = prepared[id], let began = created[id] else { throw Failure.invalid }
        guard let data = try directory.read(name(id, ".reply"), maxBytes: 2_048) else {
            return result(ProcessInfo.processInfo.systemUptime - began < 120 ? "pending" : "unknown", id)
        }
        // Receipt verification deliberately does not revalidate request TTL: a late
        // read can reconcile a committed write, but only within the original session.
        let receipt = try AgentWriteProtocol.openReceipt(data, prepared: value,
            expectedSessionID: session.sessionID, expectedRequestID: id)
        var response = result(receipt.status.rawValue, id)
        if let clip = receipt.clipID { response["clip_id"] = clip.uuidString.lowercased() }
        if receipt.status != .unavailable {
            // Only authenticated definite outcomes retire response keys. Unknown
            // persistence remains reconcilable with the original key/request.
            cleanup(id: id, value: value)
            prepared.removeValue(forKey: id); created.removeValue(forKey: id)
            completed[id] = response; completionOrder.append(id)
            while completionOrder.count > 32 { completed.removeValue(forKey: completionOrder.removeFirst()) }
        }
        return response
    }

    private func cleanup(id: UUID, value: AgentWriteProtocol.Prepared) {
        if let data = try? directory.read(name(id, ".request"), maxBytes: AgentWriteProtocol.maximumWireBytes),
           data == value.data { try? directory.remove(name(id, ".request")) }
        if let data = try? directory.read(name(id, ".reply"), maxBytes: 2_048),
           (try? AgentWriteProtocol.openReceipt(data, prepared: value,
                expectedSessionID: session.sessionID, expectedRequestID: id)) != nil {
            try? directory.remove(name(id, ".reply"))
        }
    }

    func disconnect() {
        guard !closed else { return }; closed = true
        for (id, value) in prepared { cleanup(id: id, value: value) }
        prepared.removeAll(); created.removeAll(); completed.removeAll(); completionOrder.removeAll()
    }
    deinit { disconnect() }
    private func name(_ id: UUID, _ suffix: String) -> String { id.uuidString.lowercased() + suffix }
    private func result(_ status: String, _ id: UUID) -> [String: String] {
        ["status": status, "request_id": id.uuidString.lowercased()]
    }
}
