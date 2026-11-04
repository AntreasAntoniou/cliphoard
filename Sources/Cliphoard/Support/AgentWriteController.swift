import Foundation
import Combine
import CryptoKit

/// An explicitly enabled, temporary inbox. No live-history read or arbitrary mutation API.
@MainActor
final class AgentWriteController: ObservableObject {
    struct Pending {
        let opened: AgentWriteProtocol.Opened
        let bytes: Data
        let deadline: Double
        var text: String { opened.request.text }
        var id: UUID { opened.request.requestID }
    }
    private final class Context: @unchecked Sendable {
        let session: AgentWriteProtocol.Session
        let key: Curve25519.KeyAgreement.PrivateKey
        let directory: AgentWriteDirectory
        let parent: URL
        let scoped: Bool
        let deadline: Double
        init(session: AgentWriteProtocol.Session, key: Curve25519.KeyAgreement.PrivateKey,
             directory: AgentWriteDirectory, parent: URL, scoped: Bool, deadline: Double) {
            self.session = session; self.key = key; self.directory = directory
            self.parent = parent; self.scoped = scoped; self.deadline = deadline
        }
        deinit { if scoped { parent.stopAccessingSecurityScopedResource() } }
    }
    @Published private(set) var folder: URL?
    @Published private(set) var expiresAt: Date?
    @Published private(set) var pending: Pending?
    @Published private(set) var isWorking = false
    @Published private(set) var message = "Agent saves are off. Your history is not shared automatically."
    var onRequest: (() -> Void)?
    private let save: (UUID, String) async -> Bool
    private let sensitive: (String) -> Bool
    private let now: () -> Date
    private let ticks: () -> Double
    private var context: Context?
    private var timer: Timer?
    private var generation = UUID()
    private var polling = false
    private var handled = Set<UUID>()

    init(save: @escaping (UUID, String) async -> Bool, sensitive: @escaping (String) -> Bool,
         now: @escaping () -> Date = Date.init,
         ticks: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.save = save; self.sensitive = sensitive; self.now = now; self.ticks = ticks
    }

    func enable(in parent: URL, startTimer: Bool = true) async throws {
        disconnect()
        let capturedGeneration = generation
        isWorking = true
        let scoped = parent.startAccessingSecurityScopedResource()
        let time = now().timeIntervalSince1970
        let deadline = ticks() + 900
        do {
            let (created, url) = try await Task.detached(priority: .utility) {
                do {
                    let id = UUID()
                    let url = parent.appendingPathComponent("Cliphoard-Agent-" + id.uuidString.lowercased(), isDirectory: true)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                            attributes: [.posixPermissions: 0o700])
                    let directory = try AgentWriteDirectory(url: url)
                    let key = Curve25519.KeyAgreement.PrivateKey()
                    let session = AgentWriteProtocol.Session(sessionID: id, expiresAt: time + 900,
                                                              publicKey: key.publicKey.rawRepresentation)
                    try directory.writeExclusive("session.json", data: AgentWriteProtocol.encodeSession(session, now: time))
                    return (Context(session: session, key: key, directory: directory, parent: parent,
                                    scoped: scoped, deadline: deadline), url)
                } catch {
                    if scoped { parent.stopAccessingSecurityScopedResource() }
                    throw error
                }
            }.value
            guard generation == capturedGeneration, now().timeIntervalSince1970 < created.session.expiresAt,
                  ticks() < created.deadline else {
                await Task.detached(priority: .utility) { try? created.directory.remove("session.json") }.value
                if generation == capturedGeneration { isWorking = false }
                return
            }
            context = created; folder = url; expiresAt = Date(timeIntervalSince1970: created.session.expiresAt)
            isWorking = false
            message = "Choose this session folder in your agent’s connect_writer tool. Every note needs your approval here."
            if startTimer {
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor in await self?.poll() }
                }
            }
        } catch {
            if generation == capturedGeneration {
                isWorking = false
                message = "Could not create a private agent session folder. Choose another local folder."
            }
            throw error
        }
    }

    func disconnect() {
        generation = UUID(); timer?.invalidate(); timer = nil
        if let old = context {
            Task.detached(priority: .utility) { try? old.directory.remove("session.json") }
        }
        pending = nil; context = nil; folder = nil; expiresAt = nil; handled.removeAll()
        isWorking = false
        message = "Agent saves are off. Previously saved notes stay in your history."
    }

    private func active(_ current: Context, generation expected: UUID) -> Bool {
        generation == expected && context === current && now().timeIntervalSince1970 < current.session.expiresAt && ticks() < current.deadline
    }
    private func unexpired(_ note: Pending) -> Bool {
        now().timeIntervalSince1970 < note.opened.request.createdAt + 120 && ticks() < note.deadline
    }

    func poll() async {
        guard !polling, !isWorking, let current = context else { return }
        guard now().timeIntervalSince1970 < current.session.expiresAt, ticks() < current.deadline else { disconnect(); return }
        polling = true
        defer { polling = false }
        let capturedGeneration = generation
        if let note = pending {
            if !unexpired(note) { await finish(note, status: .expired, context: current); return }
            let bytes = await Task.detached(priority: .utility) {
                try? current.directory.read(note.id.uuidString.lowercased() + ".request", maxBytes: 65536)
            }.value
            guard active(current, generation: capturedGeneration), !isWorking, pending?.id == note.id else { return }
            if !unexpired(note) { await finish(note, status: .expired, context: current) }
            else if bytes != note.bytes {
                pending = nil; message = "The agent cancelled or changed its request. Nothing was saved."
            }
            return
        }
        guard handled.count < 64 else { disconnect(); return }
        let time = now().timeIntervalSince1970
        let tick = ticks()
        let alreadyHandled = handled
        let detector = sensitive
        let found: (Pending, Bool)? = await Task.detached(priority: .utility) {
            guard let names = try? current.directory.requestNames(limit: 64) else { return nil }
            for name in names {
                guard let id = UUID(uuidString: String(name.dropLast(8))), !alreadyHandled.contains(id),
                      let data = try? current.directory.read(name, maxBytes: 65536),
                      let opened = try? AgentWriteProtocol.open(data, session: current.session, privateKey: current.key, now: time),
                      opened.request.requestID == id else { continue }
                let note = Pending(opened: opened, bytes: data, deadline: tick + min(120, max(0, opened.request.createdAt + 120 - time)))
                return (note, detector(note.text))
            }
            return nil
        }.value
        guard active(current, generation: capturedGeneration), !isWorking, let (found, flagged) = found,
              unexpired(found) else { return }
        if flagged {
            await finish(found, status: .rejected, context: current)
            if active(current, generation: capturedGeneration) { message = "A note flagged as sensitive was declined without being shown or saved." }
            return
        }
        pending = found
        message = "An agent wants to save a note. Review it below."
        onRequest?()
    }

    func approve() async {
        guard !isWorking, let current = context, let note = pending else { return }
        let capturedGeneration = generation
        guard active(current, generation: capturedGeneration), unexpired(note) else {
            await finish(note, status: .expired, context: current); return
        }
        isWorking = true
        let detector = sensitive
        let valid = await Task.detached(priority: .utility) {
            (try? current.directory.read(note.id.uuidString.lowercased() + ".request", maxBytes: 65536)) == note.bytes && !detector(note.text)
        }.value
        guard generation == capturedGeneration, context === current else { return }
        guard active(current, generation: capturedGeneration), unexpired(note) else {
            await finish(note, status: .expired, context: current); return
        }
        guard valid else { await finish(note, status: .rejected, context: current); return }
        // Approval authorizes this one durable save. Disconnecting during a commit
        // cannot undo it; the storage result remains the only source of a saved ACK.
        let stored = await save(note.id, note.text)
        await finish(note, status: stored ? .saved : .unavailable, context: current, generation: capturedGeneration)
    }

    func decline() async {
        guard !isWorking, let current = context, let note = pending else { return }
        await finish(note, status: .rejected, context: current)
    }

    private func finish(_ note: Pending, status: AgentWriteProtocol.Status, context current: Context,
                        generation expected: UUID? = nil) async {
        let capturedGeneration = expected ?? generation
        if generation == capturedGeneration, context === current {
            handled.insert(note.id); pending = nil; isWorking = true
        }
        let confirmed = await Task.detached(priority: .utility) {
            do {
                let reply = try AgentWriteProtocol.sealReceipt(status: status, opened: note.opened)
                try current.directory.writeExclusive(note.id.uuidString.lowercased() + ".reply", data: reply)
                try? current.directory.remove(note.id.uuidString.lowercased() + ".request")
                return true
            } catch { return false }
        }.value
        guard generation == capturedGeneration, context === current else { return }
        isWorking = false
        if status == .unavailable {
            message = "The save could not be confirmed and may have completed. Check this note in your history before trying again; do not send it as a new note."
        } else if confirmed {
            message = status == .saved ? "Saved and pinned. Your agent can now retrieve this note." : "Nothing was saved. The agent has been notified."
        } else {
            message = status == .saved ? "Saved locally, but the agent’s confirmation could not be written. Do not send it again as a new note." : "Nothing was saved. The agent’s confirmation is unavailable."
        }
    }
}
