#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE && !APP_STORE
import Foundation
import Combine

struct DeviceLicenceApprovalContext: Sendable {
    let issuerKeyID: String
    let issuerPublicKey: Data
    let entitlementID: String
}
enum DeviceLicenceApprovalFlowFailure: Error { case invalidConfiguration }
enum DeviceLicenceApprovalActivity: Equatable, Sendable {
    case restoring, preparingIdentity, requesting, preparingApproval, approving, saving
}
enum DeviceLicenceApprovalPhase: Equatable, Sendable {
    case ready, working(DeviceLicenceApprovalActivity), awaitingCode, retryable, cancelled, recoveryRequired
}
enum DeviceLicenceApprovalNotice: Equatable, Sendable {
    case approvalQueued, invalidCode, challengeExpired, activationRejected, unavailable, outcomeUnknown
    case invalidResponse, identityUnavailable, identityMissing, identityChanged, invalidReceipt
    case savedApprovalMissing, storageUnavailable, savedDataProblem, cancelled, commitUncertain, recovered
}
enum DeviceLicenceApprovalRetry: Equatable, Sendable {
    case sameRequest, prepareCode, saveReceipt, existingIdentity, resumeCode, restore
}
struct DeviceLicenceApprovalState: Equatable, Sendable {
    var phase: DeviceLicenceApprovalPhase = .ready
    var notice: DeviceLicenceApprovalNotice?
    var isApproved = false
    var retry: DeviceLicenceApprovalRetry?
    var canRequest = true
    var canEnterCode = false
    var canUseDifferentCode = false
    var canRestore = true
    var canImport = true
    var canCancel = false
}

@MainActor
final class DeviceLicenceApprovalFlow: ObservableObject {
    @Published private(set) var state = DeviceLicenceApprovalState()
    private(set) var approvedReceipt: DeviceLicenceReceipt?
    private enum Step {
        case identity(Data), begin(DeviceLicenceBeginRequest), code(DeviceLicenceApprovalChallenge)
        case prepare(DeviceLicenceApprovalChallenge, String, Data), approve(DeviceLicenceApprovalRequest)
    }
    private let context: DeviceLicenceApprovalContext
    private let handle: String
    private let identity: DeviceIdentity
    private let storage: any DeviceLicenceReceiptStorage
    private let service: any DeviceLicenceApprovalServing
    private let now: @Sendable () -> UInt64
    private let makeRequestID: @Sendable () -> Data
    private var recovery: DeviceLicenceRecovery?
    private var boundKey: Data?
    // Sensitive commands remain private, in memory only. A retry reuses their bytes.
    private var step: Step?
    // Receipt returned by an approval request, retained for exact local save retry.
    // An unverified manual paste must not take or discard this custody slot.
    private var pendingEnvelope: String?
    private var needsLocalRecheck = false
    private var retryRestore = false
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?

    init(context: DeviceLicenceApprovalContext, entitlementHandle: String,
         identity: DeviceIdentity, storage: any DeviceLicenceReceiptStorage,
         service: any DeviceLicenceApprovalServing,
         now: @escaping @Sendable () -> UInt64, makeRequestID: @escaping @Sendable () -> Data) throws {
        let id = Array(context.issuerKeyID.utf8)
        func alphanumeric(_ byte: UInt8) -> Bool { (97...122).contains(byte) || (48...57).contains(byte) }
        guard (1...32).contains(id.count), id.first.map(alphanumeric) == true,
              id.allSatisfy({ alphanumeric($0) || $0 == 45 || $0 == 95 }),
              Self.canonical(context.entitlementID, count: 16), Self.canonical(entitlementHandle, count: 32),
              DeviceLicenceVerifier.canonicalPublicKey(context.issuerPublicKey) != nil else {
            throw DeviceLicenceApprovalFlowFailure.invalidConfiguration
        }
        self.context = context; self.handle = entitlementHandle; self.identity = identity
        self.storage = storage; self.service = service; self.now = now; self.makeRequestID = makeRequestID
    }

    /// This explicit action is the ONLY path that may create an identity.
    /// Repeating it after an identity-only failure retains that intent's request ID.
    @discardableResult func requestApprovalForThisMac() -> Task<Void, Never>? {
        guard state.canRequest, task == nil, !needsLocalRecheck else { return nil }
        let requestID: Data
        if case .identity(let existing) = step { requestID = existing } else { requestID = makeRequestID() }
        guard requestID.count == 16 else { publish(.ready, .invalidResponse); return nil }
        step = .identity(requestID); retryRestore = false
        return launch(.preparingIdentity) { ticket in await self.beginIntent(requestID, allowCreation: true, ticket: ticket) }
    }

    @discardableResult func restoreSavedApproval() -> Task<Void, Never>? {
        guard state.canRestore, task == nil else { return nil }
        retryRestore = true
        return launch(.restoring) { ticket in
            do {
                let key = try await self.loadKey(ticket, allowCreation: false)
                let result = try await self.recoveryFor(key).restore()
                try self.check(ticket)
                switch result {
                case .success(let receipt):
                    self.approvedReceipt = receipt
                    self.needsLocalRecheck = false; self.retryRestore = false
                    self.finish(ticket, .ready, .recovered)
                case .failure(.missing):
                    // Recovery read a validated absent snapshot. This is definitive
                    // absence, unlike missing identity, a corrupt record or an IO error.
                    self.needsLocalRecheck = false; self.retryRestore = false
                    self.finish(ticket, .ready, .savedApprovalMissing)
                case .failure(let failure): throw failure
                }
            } catch { self.fail(error, ticket: ticket) }
        }
    }

    @discardableResult func submitEmailCode(_ token: String) -> Task<Void, Never>? {
        guard state.canEnterCode, task == nil, !needsLocalRecheck, case .code(let challenge) = step else { return nil }
        guard Self.canonical(token, count: 32) else { publish(.awaitingCode, .invalidCode); return nil }
        // Expiry constrains only a first approval. An exact already-dispatched retry
        // must still reach the service, which can recover an already-issued receipt.
        guard now() < challenge.expiresAt else { publish(.awaitingCode, .challengeExpired); return nil }
        let id = makeRequestID()
        guard id.count == 16 else { publish(.awaitingCode, .invalidResponse); return nil }
        step = .prepare(challenge, token, id); retryRestore = false
        return launch(.preparingApproval) { ticket in await self.prepare(challenge, token: token, id: id, ticket: ticket) }
    }

    /// An emailed receipt can recover a lost response on this Mac without networking.
    @discardableResult func importApprovedReceipt(_ envelope: String) -> Task<Void, Never>? {
        guard state.canImport, task == nil, !needsLocalRecheck else { return nil }
        guard envelope.utf8.prefix(DeviceLicenceVerifier.maximumEnvelopeBytes + 1).count <= DeviceLicenceVerifier.maximumEnvelopeBytes,
              envelope.hasPrefix(DeviceLicenceVerifier.prefix) else { publish(.ready, .invalidReceipt); return nil }
        retryRestore = false
        // Keep the paste operation-local. Failure before existing-key verification
        // cannot strand first activation or replace an already pending receipt.
        return launch(.preparingIdentity) { ticket in await self.save(envelope, ticket: ticket, manualImport: true) }
    }

    @discardableResult func retrySameOperation() -> Task<Void, Never>? {
        guard task == nil, !needsLocalRecheck, state.retry != nil else { return nil }
        if retryRestore { return restoreSavedApproval() }
        if let pendingEnvelope {
            return launch(.preparingIdentity) { ticket in await self.save(pendingEnvelope, ticket: ticket) }
        }
        switch step {
        case .identity(let id):
            // Retry never creates a second key, including after an uncertain insertion.
            return launch(.preparingIdentity) { ticket in await self.beginIntent(id, allowCreation: false, ticket: ticket) }
        case .begin(let request):
            return launch(.requesting) { ticket in await self.sendBegin(request, ticket: ticket) }
        case .code:
            publish(.awaitingCode, .approvalQueued); return nil
        case .prepare(let challenge, let token, let id):
            return launch(.preparingApproval) { ticket in await self.prepare(challenge, token: token, id: id, ticket: ticket) }
        case .approve(let request):
            return launch(.approving) { ticket in await self.sendApproval(request, ticket: ticket) }
        case nil: return nil
        }
    }

    /// Only a definitive rejection offers editing. An unknown outcome keeps the
    /// exact approval body; replacing its request ID could strand an issued receipt.
    func useDifferentCode() {
        guard task == nil, !needsLocalRecheck, state.canUseDifferentCode, case .approve(let request) = step else { return }
        step = .code(request.challenge); publish(.awaitingCode, nil)
    }

    func cancelLocalWork() { cancel(ticket: generation) }

    private func launch(_ activity: DeviceLicenceApprovalActivity,
                        operation: @escaping @MainActor (UInt64) async -> Void) -> Task<Void, Never> {
        generation &+= 1
        let ticket = generation
        publish(.working(activity), nil)
        let running = Task { [weak self] in
            guard let self else { return }
            await withTaskCancellationHandler {
                await operation(ticket)
            } onCancel: { [weak self] in
                Task { @MainActor in self?.cancel(ticket: ticket) }
            }
        }
        task = running
        return running
    }

    private func check(_ ticket: UInt64) throws {
        guard ticket == generation, !Task.isCancelled else { throw CancellationError() }
    }
    private func loadKey(_ ticket: UInt64, allowCreation: Bool) async throws -> Data {
        try check(ticket)
        let result = await (allowCreation ? identity.createIfAbsent() : identity.loadExisting())
        try check(ticket)
        let key = try result.get()
        guard boundKey == nil || boundKey == key else { throw DeviceIdentityFailure.identityChanged }
        return key
    }
    private func recoveryFor(_ key: Data) throws -> DeviceLicenceRecovery {
        if let recovery {
            guard boundKey == key else { throw DeviceIdentityFailure.identityChanged }
            return recovery
        }
        let value = try DeviceLicenceRecovery(storage: storage, identity: identity,
            bindings: .init(issuerKeyID: context.issuerKeyID, issuerPublicKey: context.issuerPublicKey,
                            entitlementID: context.entitlementID, devicePublicKey: key))
        boundKey = key; recovery = value
        return value
    }
    private func beginIntent(_ id: Data, allowCreation: Bool, ticket: UInt64) async {
        do {
            let key = try await loadKey(ticket, allowCreation: allowCreation)
            _ = try recoveryFor(key)
            let request = try DeviceLicenceBeginRequest(entitlementHandle: handle, devicePublicKeyX963: key, requestID: id)
            try check(ticket); step = .begin(request)
            await sendBegin(request, ticket: ticket)
        } catch { fail(error, ticket: ticket) }
    }
    private func sendBegin(_ request: DeviceLicenceBeginRequest, ticket: UInt64) async {
        do {
            try check(ticket); publish(.working(.requesting), nil)
            let challenge = try await service.begin(request)
            try check(ticket)
            guard challenge.entitlementID == context.entitlementID,
                  challenge.devicePublicKeyX963 == request.devicePublicKeyX963,
                  challenge.devicePublicKeyX963 == boundKey else { throw DeviceLicenceApprovalClientFailure.invalidResponse }
            step = .code(challenge)
            finish(ticket, .awaitingCode, now() < challenge.expiresAt ? .approvalQueued : .challengeExpired)
        } catch { fail(error, ticket: ticket) }
    }
    private func prepare(_ challenge: DeviceLicenceApprovalChallenge, token: String, id: Data, ticket: UInt64) async {
        do {
            try check(ticket)
            guard now() < challenge.expiresAt else {
                step = .code(challenge); finish(ticket, .awaitingCode, .challengeExpired); return
            }
            let request = try await service.prepareApproval(challenge: challenge, token: token, approvalRequestID: id, using: identity)
            try check(ticket)
            guard request.challenge == challenge, request.approvalRequestID == id else { throw DeviceLicenceApprovalClientFailure.invalidResponse }
            // Cache BEFORE dispatch. No retry regenerates this signature or body.
            step = .approve(request)
            await sendApproval(request, ticket: ticket)
        } catch { fail(error, ticket: ticket) }
    }
    private func sendApproval(_ request: DeviceLicenceApprovalRequest, ticket: UInt64) async {
        do {
            try check(ticket); publish(.working(.approving), nil)
            let result = try await service.approve(request)
            try check(ticket)
            // A service success is not an approved local licence until fresh proof
            // and the existing repository's CAS/commit checks have succeeded.
            pendingEnvelope = result.envelope
            await save(result.envelope, ticket: ticket)
        } catch { fail(error, ticket: ticket) }
    }
    private func save(_ envelope: String, ticket: UInt64, manualImport: Bool = false) async {
        do {
            let key = try await loadKey(ticket, allowCreation: false)
            let recovery = try recoveryFor(key)
            try check(ticket); publish(.working(.saving), nil)
            let result = await recovery.accept(envelope)
            try check(ticket)
            let receipt = try result.get()
            approvedReceipt = receipt
            pendingEnvelope = nil; step = nil; retryRestore = false; needsLocalRecheck = false
            finish(ticket, .ready, nil)
        } catch { fail(error, ticket: ticket, discardRejectedPendingEnvelope: !manualImport) }
    }

    private func finish(_ ticket: UInt64, _ phase: DeviceLicenceApprovalPhase, _ notice: DeviceLicenceApprovalNotice?) {
        guard ticket == generation else { return }
        if Task.isCancelled { cancel(ticket: ticket); return }
        task = nil; publish(phase, notice)
    }
    private func cancel(ticket: UInt64) {
        guard ticket == generation else { return }
        // Saving may have crossed the repository's commit point already. Cancelling
        // its Task cancels only its own permit, never a later recovery operation.
        if state.phase == .working(.saving) { needsLocalRecheck = true }
        generation &+= 1
        let old = task; task = nil; old?.cancel()
        publish(needsLocalRecheck ? .recoveryRequired : .cancelled,
                needsLocalRecheck ? .commitUncertain : .cancelled)
    }
    private func fail(_ error: Error, ticket: UInt64, discardRejectedPendingEnvelope: Bool = true) {
        guard ticket == generation else { return }
        if Task.isCancelled || error is CancellationError || error as? DeviceLicenceApprovalClientFailure == .cancelled {
            cancel(ticket: ticket); return
        }
        let notice: DeviceLicenceApprovalNotice
        if let failure = error as? DeviceLicenceRecoveryFailure {
            switch failure {
            case .storage(.commitUncertain): needsLocalRecheck = true; notice = .commitUncertain
            case .storage(.corrupt), .storage(.insecurePath), .storage(.invalidPath): notice = .savedDataProblem
            case .storage: notice = .storageUnavailable
            case .identity(let identityFailure): notice = identityNotice(identityFailure)
            case .verification, .bindingMismatch, .invalidBindings:
                if discardRejectedPendingEnvelope { pendingEnvelope = nil }
                notice = .invalidReceipt
            case .missing: notice = .savedApprovalMissing
            case .cancelled, .superseded: cancel(ticket: ticket); return
            }
        } else if let failure = error as? DeviceIdentityFailure {
            notice = identityNotice(failure)
        } else if let failure = error as? DeviceLicenceApprovalClientFailure {
            switch failure {
            case .activationRejected: notice = .activationRejected
            case .transportUncertain: notice = .outcomeUnknown
            case .unavailable: notice = .unavailable
            case .keyUnavailable: notice = .identityUnavailable
            case .invalidConfiguration, .invalidRequest, .invalidResponse, .invalidProof: notice = .invalidResponse
            case .cancelled: cancel(ticket: ticket); return
            }
        } else { notice = .unavailable }
        finish(ticket, needsLocalRecheck ? .recoveryRequired : .retryable, notice)
    }
    private func identityNotice(_ failure: DeviceIdentityFailure) -> DeviceLicenceApprovalNotice {
        switch failure {
        case .missing: return .identityMissing
        case .identityChanged, .invalidRecord: return .identityChanged
        default: return .identityUnavailable
        }
    }
    private func publish(_ phase: DeviceLicenceApprovalPhase, _ notice: DeviceLicenceApprovalNotice?) {
        let busy: Bool
        if case .working = phase { busy = true } else { busy = false }
        var value = DeviceLicenceApprovalState(phase: phase, notice: notice, isApproved: approvedReceipt != nil)
        value.canRestore = !busy
        value.canImport = !busy && !needsLocalRecheck
        value.canCancel = busy || (step != nil && phase != .cancelled && phase != .recoveryRequired)
        value.canRequest = false
        if !busy && !needsLocalRecheck {
            if retryRestore { value.retry = .restore }
            else if pendingEnvelope != nil { value.retry = .saveReceipt }
            else {
                switch step {
                case .identity: value.retry = .existingIdentity
                case .begin, .approve: value.retry = .sameRequest
                case .prepare: value.retry = .prepareCode
                case .code: if phase == .cancelled { value.retry = .resumeCode }
                case nil: break
                }
            }
            if case .code = step { value.canEnterCode = phase != .cancelled && notice != .challengeExpired }
            if case .approve = step { value.canUseDifferentCode = notice == .activationRejected }
            if approvedReceipt == nil && pendingEnvelope == nil {
                switch step {
                case nil, .identity: value.canRequest = true
                case .code: value.canRequest = notice == .challengeExpired
                default: break
                }
            }
        }
        state = value
    }
    private static func canonical(_ value: String, count: Int) -> Bool {
        guard value.utf8.prefix((count * 8 + 5) / 6 + 1).count == (count * 8 + 5) / 6,
              value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return false }
        var encoded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.utf8.count % 4) % 4)
        guard let bytes = Data(base64Encoded: encoded) else { return false }
        return bytes.count == count && DeviceLicenceVerifier.encode(bytes) == value
    }
}
#endif
