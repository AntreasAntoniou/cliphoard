#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE && !APP_STORE
import Foundation
import Combine

enum DeviceLicenceDirectEntitlements {
    static func resolve(legacy: Entitlement, receipt: DeviceLicenceReceipt?) -> Entitlement {
        // A failed or unavailable device path never removes a valid CLIP1 licence.
        if case .pro = legacy { return legacy }
        if let receipt { return .devicePro(receipt) }
        return legacy
    }
}

/// Explicit app-lifetime bridge. No global factory, production profile, endpoint or
/// trust pin is inferred. A nil owner is inert; configured construction is also inert.
/// The app starts this once and stops it only at actual termination, not a quit request.
@MainActor
final class DeviceLicenceDirectRuntime: ObservableObject {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    private let owner: DeviceLicenceDirectApplicationOwner?
    private var phase: DeviceLicenceApplicationLifecycle = .idle
    private var activeSession: DeviceLicenceApplicationSession?
    private var ownerObservation: AnyCancellable?, sessionObservation: AnyCancellable?
    private var operation: Task<Void, Never>?, update: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var publishReceipt: ((DeviceLicenceReceipt?) -> Void)?
    private var lastReceipt: DeviceLicenceReceipt?
    private var currentFailure: DeviceLicenceDirectApplicationFailure?
    var lifecycle: DeviceLicenceApplicationLifecycle { phase }
    var isConfigured: Bool { owner != nil }
    var isWorking: Bool { operation != nil }
    var session: DeviceLicenceApplicationSession? { phase == .running ? activeSession : nil }
    var failure: DeviceLicenceDirectApplicationFailure? { currentFailure }

    init(owner: DeviceLicenceDirectApplicationOwner?) { self.owner = owner }

    @discardableResult
    func start(publishReceipt: @escaping (DeviceLicenceReceipt?) -> Void) -> Task<Void, Never>? {
        guard phase == .idle else { return nil }
        phase = .running; self.publishReceipt = publishReceipt
        guard let owner else { objectWillChange.send(); return nil }
        ownerObservation = owner.$state.sink { [weak self] _ in self?.scheduleUpdate() }
        return run { _ = try await owner.restoreSavedBootstrap() }
    }

    @discardableResult
    func importBootstrap(_ envelope: String) -> Task<Void, Never>? {
        guard phase == .running, let owner else { return nil }
        return run { try await owner.importBootstrap(envelope) }
    }

    @discardableResult
    func restoreBootstrap() -> Task<Void, Never>? {
        guard phase == .running, let owner else { return nil }
        return run { _ = try await owner.restoreSavedBootstrap() }
    }

    func stop() {
        guard phase != .stopped else { return }
        phase = .stopped; generation &+= 1
        operation?.cancel(); operation = nil; update?.cancel(); update = nil
        ownerObservation = nil; sessionObservation = nil; activeSession = nil
        publishReceipt = nil
        owner?.stop()
        objectWillChange.send()
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) -> Task<Void, Never>? {
        guard phase == .running, operation == nil else { return nil }
        generation &+= 1; let ticket = generation; currentFailure = nil
        // Install the task before notifying observers; no reentrant second action.
        let task = Task { @MainActor [weak self] in
            guard let self, self.phase == .running, self.generation == ticket else { return }
            defer {
                if self.phase == .running, self.generation == ticket {
                    self.operation = nil; self.reconcile()
                }
            }
            guard !Task.isCancelled else { self.currentFailure = .cancelled; return }
            do { try await action() }
            catch {
                guard self.phase == .running, self.generation == ticket else { return }
                self.currentFailure = (error as? DeviceLicenceDirectApplicationFailure) ?? .sessionUnavailable
            }
        }
        operation = task
        objectWillChange.send()
        return task
    }

    private func scheduleUpdate() {
        guard phase == .running, update == nil else { return }
        // Both owner/session @Published streams emit in willSet. Read committed
        // private state on the next actor turn, never trust the emitted snapshot.
        update = Task { @MainActor [weak self] in
            guard let self else { return }
            self.update = nil
            guard self.phase == .running, !Task.isCancelled else { return }
            self.reconcile()
        }
    }

    private func reconcile() {
        guard phase == .running else { return }
        let candidate = owner?.applicationSession
        if activeSession !== candidate {
            sessionObservation = nil; activeSession = candidate
            if let candidate {
                sessionObservation = candidate.$state.sink { [weak self] _ in self?.scheduleUpdate() }
            }
        }
        if let receipt = candidate?.approvedReceipt, receipt != lastReceipt {
            lastReceipt = receipt
            publishReceipt?(receipt)
            guard phase == .running else { return }
        }
        // Notify after the private projection is complete: reentrant stop cannot
        // be overwritten by an outer @Published setter.
        objectWillChange.send()
    }
}
#endif
