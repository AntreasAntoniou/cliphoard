#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE
/// Pure client state. Effects and persistence belong in a future asynchronous adapter.
/// An online failure/hold/refund cannot erase an already approved offline receipt.
struct DeviceLicenceActivation: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case requesting(requestID: String)
        case awaitingEmail(requestID: String)
        case failed(requestID: String, reason: Failure)
    }
    enum Failure: Equatable, Sendable { case unavailable, heldForReview, approvalRejected, invalidReceipt }
    enum Event: Sendable {
        case begin(requestID: String)
        case emailPending(requestID: String)
        case failed(requestID: String, reason: Failure)
        case verified(requestID: String, receipt: DeviceLicenceReceipt)
    }

    private(set) var receipt: DeviceLicenceReceipt?
    private(set) var phase: Phase = .idle

    init(approvedReceipt: DeviceLicenceReceipt? = nil) { receipt = approvedReceipt }

    func reducing(_ event: Event) -> Self {
        var next = self
        switch event {
        case .begin(let requestID):
            next.phase = .requesting(requestID: requestID)
        case .emailPending(let requestID):
            guard phase == .requesting(requestID: requestID) else { return self }
            next.phase = .awaitingEmail(requestID: requestID)
        case .failed(let requestID, let reason):
            guard pendingRequestID == requestID else { return self }
            next.phase = .failed(requestID: requestID, reason: reason)
        case .verified(let requestID, let receipt):
            guard pendingRequestID == requestID else { return self }
            next.receipt = receipt
            next.phase = .idle
        }
        return next
    }

    private var pendingRequestID: String? {
        switch phase {
        case .requesting(let id), .awaitingEmail(let id): return id
        case .idle, .failed: return nil
        }
    }
}
#endif
