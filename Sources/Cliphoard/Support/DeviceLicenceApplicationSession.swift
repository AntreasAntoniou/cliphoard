#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE && !APP_STORE
import Foundation
import Combine

/// Trusted onboarding inputs, never inferred from a pasted/stored receipt. There
/// is no default endpoint, purchaser, issuer, identity namespace or receipt path.
struct DeviceLicenceApplicationConfiguration: Sendable {
    let origin: URL
    let entitlementID: String
    let entitlementHandle: String
    let issuerKeyID: String
    let issuerPublicKey: Data
    let expectedDevicePublicKey: Data?
    let receiptFileURL: URL
    let identityKeychainService: String
    let identityKeychainAccount: String
    let resourceTimeout: TimeInterval
}
enum DeviceLicenceApplicationFailure: Error, Equatable { case invalidConfiguration }
enum DeviceLicenceApplicationLifecycle: Equatable, Sendable { case idle, running, stopped }
struct DeviceLicenceApplicationState: Equatable, Sendable {
    var lifecycle: DeviceLicenceApplicationLifecycle = .idle
    var isPanelPresented = false
    var isProApproved = false
    var approvedReceipt: DeviceLicenceReceipt?
    var approval = DeviceLicenceApprovalState()
}
/// One owner per application lifetime. Panel values borrow this session; they do
/// not own a flow, create identities, restore storage or choose trusted bindings.
/// Only the sanitized state is observable. Sensitive commands remain in the flow.
@MainActor
final class DeviceLicenceApplicationSession: ObservableObject {
    @Published private(set) var state = DeviceLicenceApplicationState()
    var lifecycle: DeviceLicenceApplicationLifecycle { state.lifecycle }
    var isPanelPresented: Bool { state.isPanelPresented }
    var isProApproved: Bool { state.isProApproved }
    var approvedReceipt: DeviceLicenceReceipt? { state.approvedReceipt }
    var approvalState: DeviceLicenceApprovalState { state.approval }
    private let flow: DeviceLicenceApprovalFlow
    private var observation: AnyCancellable?
    private var pendingUpdate: Task<Void, Never>?
    private var phase: DeviceLicenceApplicationLifecycle = .idle
    private var presented = false
    private var approval = DeviceLicenceApprovalState()
    private var verifiedReceipt: DeviceLicenceReceipt?
    private var forwarding = false, publishing = false, flushing = false
    private var cancellationRequested = false

    /// All constructors used here validate values only. The physical receipt path
    /// is checked on an explicit storage operation, not repaired or created here.
    init(configuration: DeviceLicenceApplicationConfiguration,
         identityStorage: any DeviceIdentityStorage, identityKeys: any DeviceIdentityKeyOperations,
         transport: any DeviceLicenceApprovalTransport, receiptIO: any DeviceLicenceReceiptFileIO = DeviceLicenceReceiptPOSIXIO(),
         now: @escaping @Sendable () -> UInt64, makeRequestID: @escaping @Sendable () -> Data) throws {
        do {
            // Validate native scope/timeout even when capabilities are injected.
            _ = try DeviceIdentityKeychainStorage(service: configuration.identityKeychainService,
                account: configuration.identityKeychainAccount, calls: DeviceIdentitySystemKeychainCalls())
            _ = try DeviceLicenceURLSessionTransport(resourceTimeout: configuration.resourceTimeout)
            let identity = try DeviceIdentity(storage: identityStorage, keys: identityKeys,
                expectedPublicKey: configuration.expectedDevicePublicKey)
            let repository = try DeviceLicenceReceiptRepository(fileURL: configuration.receiptFileURL, io: receiptIO)
            let client = try DeviceLicenceApprovalClient(origin: configuration.origin,
                expectedEntitlementID: configuration.entitlementID, transport: transport)
            flow = try DeviceLicenceApprovalFlow(context: .init(issuerKeyID: configuration.issuerKeyID,
                issuerPublicKey: configuration.issuerPublicKey, entitlementID: configuration.entitlementID),
                entitlementHandle: configuration.entitlementHandle, identity: identity, storage: repository,
                service: client, now: now, makeRequestID: makeRequestID)
        } catch { throw DeviceLicenceApplicationFailure.invalidConfiguration }
        observation = flow.$state.sink { [weak self] _ in
            guard let self, self.phase != .stopped else { return }
            // @Published emits in willSet. Never expose a callback that can reenter
            // the flow before that setter completes (especially cancel while saving).
            // Coalesce to one UI task and read the latest committed state, not a
            // captured snapshot which could become stale after close/stop/retry.
            if self.pendingUpdate == nil {
                self.pendingUpdate = Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.pendingUpdate = nil
                    guard !Task.isCancelled, self.phase != .stopped else { return }
                    self.flush()
                }
            }
        }
        flush()
    }

    /// Optional concrete native composition, still compile-time disabled. Merely
    /// constructing the adapters performs no Keychain, enclave, file or URLSession
    /// operation. There is no software-key fallback or implicit account discovery.
    static func native(configuration: DeviceLicenceApplicationConfiguration) throws -> DeviceLicenceApplicationSession {
        do {
            return try .init(configuration: configuration,
                identityStorage: DeviceIdentityKeychainStorage(service: configuration.identityKeychainService,
                    account: configuration.identityKeychainAccount, calls: DeviceIdentitySystemKeychainCalls()),
                identityKeys: DeviceIdentitySecureEnclave(),
                transport: DeviceLicenceURLSessionTransport(resourceTimeout: configuration.resourceTimeout),
                now: { UInt64(min(Double(DeviceLicenceVerifier.maximumEpoch), max(1, Date().timeIntervalSince1970))) },
                makeRequestID: {
                    var uuid = UUID().uuid
                    return withUnsafeBytes(of: &uuid) { Data($0) }
                })
        } catch { throw DeviceLicenceApplicationFailure.invalidConfiguration }
    }

    /// Explicit app lifecycle action, once per session. Restore can only load an
    /// existing identity. A failure is recoverable through an explicit panel action.
    @discardableResult func start() -> Task<Void, Never>? {
        guard phase == .idle, !forwarding, !publishing else { return nil }
        phase = .running
        return forward { flow.restoreSavedApproval() }
    }
    /// Reopening retains the same private pending commands; it never retries them.
    func openPanel() {
        guard phase != .stopped else { return }
        presented = true; flush()
    }
    func closePanel() {
        guard phase != .stopped else { return }
        presented = false
        if phase == .running, approval.canCancel { cancellationRequested = true }
        flush()
    }
    /// Terminal fence, including reentrant calls made from a state subscriber.
    /// An already claimed file commit or remote request cannot be rolled back.
    func stop() {
        guard phase != .stopped else { return }
        phase = .stopped; presented = false; cancellationRequested = true
        pendingUpdate?.cancel(); pendingUpdate = nil
        flush()
    }
    @discardableResult func requestApprovalForThisMac() -> Task<Void, Never>? {
        forward { flow.requestApprovalForThisMac() }
    }
    @discardableResult func restoreSavedApproval() -> Task<Void, Never>? {
        forward { flow.restoreSavedApproval() }
    }
    @discardableResult func submitEmailCode(_ token: String) -> Task<Void, Never>? {
        forward { flow.submitEmailCode(token) }
    }
    @discardableResult func importApprovedReceipt(_ envelope: String) -> Task<Void, Never>? {
        forward { flow.importApprovedReceipt(envelope) }
    }
    @discardableResult func retrySameOperation() -> Task<Void, Never>? {
        forward { flow.retrySameOperation() }
    }
    func useDifferentCode() { _ = forward { flow.useDifferentCode(); return nil } }
    func cancelLocalWork() {
        guard phase == .running else { return }
        cancellationRequested = true; flush()
    }

    private func forward(_ action: () -> Task<Void, Never>?) -> Task<Void, Never>? {
        guard phase == .running, !forwarding, !publishing, !flushing else { return nil }
        forwarding = true
        let task = action()
        forwarding = false
        flush()
        guard let task else { return nil }
        // Waiting on the returned action includes the final observable projection.
        // Cancelling this handle cancels only its original underlying flow task.
        return Task { @MainActor [weak self] in
            await withTaskCancellationHandler {
                await task.value
                self?.flush()
            } onCancel: { task.cancel() }
        }
    }
    private func flush() {
        guard !forwarding, !publishing, !flushing else { return }
        flushing = true
        defer { flushing = false }
        // Synchronous observers may stop/close, but cannot start a second operation
        // during the flow's willSet notification. Cancellation waits only for this
        // synchronous call to finish, never for an async dependency to settle.
        repeat {
            if cancellationRequested {
                cancellationRequested = false
                forwarding = true; flow.cancelLocalWork(); forwarding = false
            }
            if phase != .stopped {
                approval = flow.state
                // This receipt is set only after fresh proof + successful local
                // persistence/readback. Remote success alone never publishes Pro.
                if approval.isApproved, let receipt = flow.approvedReceipt { verifiedReceipt = receipt }
            }
            var gated = approval
            if phase != .running {
                gated.canRequest = false; gated.canEnterCode = false; gated.canUseDifferentCode = false
                gated.canRestore = false; gated.canImport = false; gated.canCancel = false; gated.retry = nil
            }
            let next = DeviceLicenceApplicationState(lifecycle: phase, isPanelPresented: presented,
                isProApproved: verifiedReceipt != nil, approvedReceipt: verifiedReceipt, approval: gated)
            if state != next { publishing = true; state = next; publishing = false }
        } while cancellationRequested || state.lifecycle != phase || state.isPanelPresented != presented
    }
}
#endif
