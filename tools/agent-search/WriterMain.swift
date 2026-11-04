import AppKit
import Foundation
import Darwin

/// Length-bounded stdin framing with an independent monotonic session deadline.
private final class CommandLines {
    private var buffer = Data()
    func next(deadline: TimeInterval?, validate: () throws -> Void) throws -> Data? {
        while true {
            try validate()
            if let end = buffer.firstIndex(of: 10) {
                guard end <= 262_144 else { throw WriterConnection.Failure.invalid }
                let line = buffer.prefix(upTo: end); buffer.removeSubrange(...end)
                return Data(line)
            }
            guard buffer.count <= 262_144 else { throw WriterConnection.Failure.invalid }
            let remaining = deadline.map { $0 - ProcessInfo.processInfo.systemUptime } ?? 1
            guard remaining > 0 else { return nil }
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let polled = poll(&descriptor, 1, Int32(min(remaining * 1_000, 1_000)))
            if polled < 0 { if errno == EINTR { continue }; throw WriterConnection.Failure.invalid }
            if polled == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 4_096)
            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            if count == 0 { return nil }
            if count < 0 { if errno == EINTR { continue }; throw WriterConnection.Failure.invalid }
            buffer.append(contentsOf: bytes.prefix(count))
        }
    }
}

@main
struct WriterMain {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let chooser = NSOpenPanel()
        chooser.title = "Connect Cliphoard agent saves"
        chooser.message = "In Cliphoard Settings → AI agents, enable agent saves and choose a save permission. Select that session’s folder. Cliphoard applies your chosen permission. Full access stays connected while Cliphoard runs; other connections last up to 15 minutes."
        chooser.prompt = "Connect"
        chooser.canChooseDirectories = true; chooser.canChooseFiles = false
        chooser.allowsMultipleSelection = false; chooser.canCreateDirectories = false
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard chooser.runModal() == .OK, let url = chooser.url else { emit(["status": "cancelled"]); return }
        do {
            let connection = try WriterConnection(url: url)
            defer { connection.disconnect() }
            emit(["status": "ready", "session_id": connection.session.sessionID.uuidString.lowercased(),
                  "expires_at": connection.session.expiresAt as Any? ?? NSNull(),
                  "lifetime": connection.session.lifetime?.rawValue ?? "bounded"])
            let lines = CommandLines()
            while let line = try lines.next(deadline: connection.deadline, validate: connection.validate) {
                do {
                    guard let command = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let action = command["action"] as? String else { throw WriterConnection.Failure.invalid }
                    if action == "disconnect", command.count == 1 { emit(["status": "disconnected"]); return }
                    guard let rawID = command["request_id"] as? String,
                          let id = UUID(uuidString: rawID), id.uuidString.lowercased() == rawID else {
                        throw WriterConnection.Failure.invalid
                    }
                    if action == "write", Set(command.keys) == ["action", "request_id", "text"],
                       let text = command["text"] as? String {
                        emit(try connection.write(id: id, text: text))
                    } else if action == "check", Set(command.keys) == ["action", "request_id"] {
                        emit(try connection.check(id: id))
                    } else { throw WriterConnection.Failure.invalid }
                } catch {
                    // Do not print input, filesystem paths, note text or framework errors.
                    emit(["status": "unknown"])
                }
            }
        } catch { emit(["status": "unavailable"]) }
    }
    private static func emit(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), data.count < 2_048 else { return }
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
    }
}
