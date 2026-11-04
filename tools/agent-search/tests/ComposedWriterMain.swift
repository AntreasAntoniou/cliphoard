import Foundation
import SQLite3

/// Headless synthetic user decisions only. Production writer never approves notes.
@main struct ComposedWriterMain {
    @MainActor static func main() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("cliphoard-composed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: parent) }
        let path = parent.appendingPathComponent("fixture.sqlite").path
        guard let database = Database(path: path) else { fatalError("synthetic database unavailable") }
        let controller = AgentWriteController(save: { id, text in
            await database.saveAgentNoteInBackground(id: id, text: text)
        }, sensitive: { !Database.acceptsAgentNote($0) })
        try await controller.enable(in: parent, startTimer: false)
        let writer = try WriterConnection(url: controller.folder!)
        defer { writer.disconnect(); controller.disconnect() }
        emit(["status": "ready", "session_id": writer.session.sessionID.uuidString.lowercased(),
              "expires_at": writer.session.expiresAt])
        while let line = readLine() {
            let command = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: String]
            guard command["action"] != "disconnect" else { break }
            let id = UUID(uuidString: command["request_id"]!)!
            if command["action"] == "write" {
                if command["text"]!.hasPrefix("commit-failure:") {
                    var handle: OpaquePointer?
                    guard sqlite3_open(path, &handle) == SQLITE_OK else { fatalError("fixture SQL open failed") }
                    defer { sqlite3_close(handle) }
                    let sql = """
                    CREATE TABLE fixture_parent(id TEXT PRIMARY KEY);
                    CREATE TABLE fixture_child(id TEXT REFERENCES fixture_parent(id) DEFERRABLE INITIALLY DEFERRED);
                    CREATE TRIGGER fixture_fail AFTER INSERT ON clips WHEN NEW.id='\(id.uuidString)'
                    BEGIN INSERT INTO fixture_child VALUES('missing'); END;
                    """
                    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { fatalError("fixture trigger failed") }
                }
                emit(try writer.write(id: id, text: command["text"]!))
            } else {
                await controller.poll()
                if controller.pending != nil { await controller.approve() } // synthetic fixture decision
                let response = try writer.check(id: id)
                if response["status"] == "saved" {
                    // A separately opened real SQLite connection must observe the exact row.
                    guard let reopened = Database(path: path), let item = reopened.loadAll().first(where: { $0.id == id }),
                          item.sourceApp == "Cliphoard Agent", item.pinned,
                          item.userTags == ["agent-note", "agent-share"] else { fatalError("durable readback failed") }
                    for suffix in ["", "-wal", "-shm"] {
                        if let bytes = try? Data(contentsOf: URL(fileURLWithPath: path + suffix)),
                           bytes.range(of: Data(item.text.utf8)) != nil { fatalError("plaintext database content") }
                    }
                }
                if response["status"] == "unavailable" {
                    guard let reopened = Database(path: path), !reopened.loadAll().contains(where: { $0.id == id }) else {
                        fatalError("failed commit retained a note")
                    }
                }
                emit(response)
            }
        }
    }
    static func emit(_ value: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
    }
}
