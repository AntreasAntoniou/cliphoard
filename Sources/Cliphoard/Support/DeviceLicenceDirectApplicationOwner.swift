#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE && !APP_STORE
import Foundation
import Combine

/// Explicit local application configuration. No endpoint, filesystem or identity
/// namespace can be selected by an imported descriptor. Construction performs no IO.
struct DeviceLicenceDirectApplicationConfiguration: Sendable {
    private let origin: URL, receiptFileURL: URL
    private let expectedDevicePublicKey: Data?
    private let identityKeychainService: String, identityKeychainAccount: String
    private let resourceTimeout: TimeInterval
    init(origin: URL, expectedDevicePublicKey: Data?, receiptFileURL: URL,
         identityKeychainService: String, identityKeychainAccount: String, resourceTimeout: TimeInterval) throws {
        do {
            self.origin = try DeviceLicenceBootstrapRoutingTransport.canonicalOrigin(origin)
            if let expectedDevicePublicKey, DeviceLicenceVerifier.canonicalPublicKey(expectedDevicePublicKey) == nil {
                throw DeviceLicenceDirectApplicationFailure.invalidConfiguration
            }
            _ = try DeviceIdentityKeychainStorage(service: identityKeychainService, account: identityKeychainAccount,
                calls: DeviceIdentitySystemKeychainCalls())
            _ = try DeviceLicenceReceiptRepository(fileURL: receiptFileURL)
            _ = try DeviceLicenceURLSessionTransport(resourceTimeout: resourceTimeout)
            self.expectedDevicePublicKey = expectedDevicePublicKey.map { Data(Array($0)) }
            self.receiptFileURL = receiptFileURL; self.identityKeychainService = identityKeychainService
            self.identityKeychainAccount = identityKeychainAccount; self.resourceTimeout = resourceTimeout
        } catch { throw DeviceLicenceDirectApplicationFailure.invalidConfiguration }
    }
    fileprivate func application(_ bootstrap: VerifiedDeviceLicenceBootstrap) throws -> DeviceLicenceBootstrapApplicationConfiguration {
        try .init(bootstrap: bootstrap, origin: origin, expectedDevicePublicKey: expectedDevicePublicKey,
            receiptFileURL: receiptFileURL, identityKeychainService: identityKeychainService,
            identityKeychainAccount: identityKeychainAccount, resourceTimeout: resourceTimeout)
    }
}
enum DeviceLicenceDirectApplicationFailure: Error, Equatable, Sendable {
    case invalidConfiguration, invalidBootstrap, storageUnavailable, scopeConflict, sessionUnavailable, busy, stopped, cancelled
}
enum DeviceLicenceDirectApplicationState: Equatable, Sendable { case idle, working, ready, stopped }
@MainActor
protocol DeviceLicenceDirectOwnedSession: AnyObject {
    var lifecycle: DeviceLicenceApplicationLifecycle { get }
    @discardableResult func start() -> Task<Void, Never>?
    func stop()
    func openPanel()
    func closePanel()
}
extension DeviceLicenceApplicationSession: DeviceLicenceDirectOwnedSession {}

/// One session owner, with explicit import/restore actions. Ready means a verified
/// saved bootstrap and started session, never Pro, payment or receipt approval.
/// No bearer descriptor or private session object is published to generic UI state.
@MainActor
final class DeviceLicenceDirectApplicationOwner: ObservableObject {
    @Published private(set) var state: DeviceLicenceDirectApplicationState = .idle
    var hasSession: Bool { session != nil }
    private let repository: DeviceLicenceBootstrapRepository
    private let configuration: DeviceLicenceDirectApplicationConfiguration
    private let makeSession: (DeviceLicenceBootstrapApplicationConfiguration) throws -> any DeviceLicenceDirectOwnedSession
    private var session: (any DeviceLicenceDirectOwnedSession)?
    private var saved: StoredDeviceLicenceBootstrap?
    private var generation: UInt64 = 0, operation: UInt64?
    private var closed = false, publishing = false
    init(repository: DeviceLicenceBootstrapRepository, configuration: DeviceLicenceDirectApplicationConfiguration,
         makeSession: @escaping (DeviceLicenceBootstrapApplicationConfiguration) throws -> any DeviceLicenceDirectOwnedSession) {
        self.repository = repository; self.configuration = configuration; self.makeSession = makeSession
    }
    /// Native adapters stay lazy. No native operation occurs until explicit import
    /// or restoration successfully passes secure readback and calls session.start().
    static func native(repository: DeviceLicenceBootstrapRepository,
                       configuration: DeviceLicenceDirectApplicationConfiguration) -> DeviceLicenceDirectApplicationOwner {
        .init(repository: repository, configuration: configuration) {
            try DeviceLicenceBootstrapApplication.native(configuration: $0)
        }
    }
    @discardableResult
    func restoreSavedBootstrap() async throws -> Bool {
        try available()
        if session != nil { return true }
        let ticket = begin()
        do {
            try active(ticket)
            guard let record = try await repository.load() else {
                try active(ticket); finish(ticket); return false
            }
            try active(ticket); try install(record, ticket); return true
        } catch { finish(ticket); throw sanitized(error) }
    }
    func importBootstrap(_ envelope: String) async throws {
        try available()
        if let saved {
            guard saved.matches(envelope) else { throw DeviceLicenceDirectApplicationFailure.scopeConflict }
            return
        }
        let ticket = begin()
        do {
            try active(ticket)
            let record = try await repository.persistIfAbsent(envelope)
            try active(ticket); try install(record, ticket)
        } catch { finish(ticket); throw sanitized(error) }
    }
    func openPanel() { guard !closed, operation == nil else { return }; session?.openPanel() }
    func closePanel() { guard !closed, operation == nil else { return }; session?.closePanel() }
    func stop() {
        guard !closed else { return }
        closed = true; generation &+= 1; operation = nil
        let old = session; session = nil; saved = nil; old?.stop(); publish()
    }
    private func available() throws {
        guard !closed else { throw DeviceLicenceDirectApplicationFailure.stopped }
        guard operation == nil else { throw DeviceLicenceDirectApplicationFailure.busy }
        if Task.isCancelled { throw DeviceLicenceDirectApplicationFailure.cancelled }
    }
    private func begin() -> UInt64 {
        generation &+= 1; let ticket = generation; operation = ticket; publish(); return ticket
    }
    private func active(_ ticket: UInt64) throws {
        guard !closed, operation == ticket, generation == ticket else { throw DeviceLicenceDirectApplicationFailure.stopped }
        if Task.isCancelled { throw DeviceLicenceDirectApplicationFailure.cancelled }
    }
    private func finish(_ ticket: UInt64) {
        guard operation == ticket else { return }; operation = nil
        publish()
    }
    private func install(_ record: StoredDeviceLicenceBootstrap, _ ticket: UInt64) throws {
        try active(ticket)
        let candidate: any DeviceLicenceDirectOwnedSession
        do { candidate = try makeSession(configuration.application(record.verified)) }
        catch { throw DeviceLicenceDirectApplicationFailure.sessionUnavailable }
        do { try active(ticket) }
        catch { candidate.stop(); throw error }
        guard candidate.lifecycle == .idle else { candidate.stop(); throw DeviceLicenceDirectApplicationFailure.sessionUnavailable }
        // The protocol getter may reenter stop before returning its captured value.
        do { try active(ticket) }
        catch { candidate.stop(); throw error }
        session = candidate; saved = record
        _ = candidate.start()
        do {
            try active(ticket)
            guard candidate.lifecycle == .running else { throw DeviceLicenceDirectApplicationFailure.sessionUnavailable }
        } catch {
            if session === candidate { session = nil; saved = nil; candidate.stop() }
            throw error
        }
        finish(ticket)
        if closed { throw DeviceLicenceDirectApplicationFailure.stopped }
    }
    private func projection() -> DeviceLicenceDirectApplicationState {
        if closed { return .stopped }
        if operation != nil { return .working }
        return session == nil ? .idle : .ready
    }
    private func publish() {
        guard !publishing else { return }; publishing = true
        defer { publishing = false }
        // @Published notifies during willSet. Reentrant stop owns private state;
        // reconcile again after the outer setter rather than trusting its value.
        repeat {
            let next = projection()
            if state != next { state = next }
        } while state != projection()
    }
    private func sanitized(_ error: Error) -> DeviceLicenceDirectApplicationFailure {
        if let failure = error as? DeviceLicenceDirectApplicationFailure { return failure }
        if let failure = error as? DeviceLicenceBootstrapRepositoryFailure {
            switch failure {
            case .invalidBootstrap: return .invalidBootstrap
            case .storageUnavailable: return .storageUnavailable
            case .conflict: return .scopeConflict
            case .cancelled: return .cancelled
            }
        }
        return .sessionUnavailable
    }
}
#endif
