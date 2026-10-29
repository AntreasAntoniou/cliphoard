import Foundation

/// Ephemeral, single-clip authority. A late successful OS prompt cannot revive a
/// closed presentation, authorize replacement content, or unlock another clip.
struct SensitiveRevealState {
    struct Request: Equatable {
        let nonce: UUID
        let id: UUID
        let fingerprint: String
    }
    private(set) var pending: Request?
    private var grant: Request?
    private var expiresAt = 0.0

    mutating func begin(id: UUID, fingerprint: String) -> Request {
        lock()
        let request = Request(nonce: UUID(), id: id, fingerprint: fingerprint)
        pending = request
        return request
    }
    mutating func complete(_ request: Request, success: Bool, fingerprint: String, now: Double) {
        guard pending == request else { return }
        pending = nil
        guard success, request.fingerprint == fingerprint, now.isFinite else { return }
        grant = request
        expiresAt = now + 60
    }
    func permits(id: UUID, fingerprint: String, now: Double) -> Bool {
        guard let grant else { return false }
        return now.isFinite && now < expiresAt && now >= expiresAt - 60
            && grant.id == id && grant.fingerprint == fingerprint
    }
    mutating func lock() {
        pending = nil
        grant = nil
        expiresAt = 0
    }
}
