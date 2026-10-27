#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE && !APP_STORE
import Foundation
import LocalAuthentication
import Security

/// Insert-only secure storage for the handle-bearing descriptor. The namespace is
/// independently configured; this is not the public approved-receipt repository.
protocol DeviceLicenceBootstrapSecureStorage: Sendable {
    func read() async throws -> Data?
    func insertIfAbsent(_ record: Data) async throws -> Bool
}
enum DeviceLicenceBootstrapRepositoryFailure: Error, Equatable, Sendable {
    case invalidBootstrap, storageUnavailable, conflict, cancelled
}
struct StoredDeviceLicenceBootstrap: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let verified: VerifiedDeviceLicenceBootstrap
    private let envelope: String
    fileprivate init(envelope: String, verified: VerifiedDeviceLicenceBootstrap) {
        self.envelope = envelope; self.verified = verified
    }
    func matches(_ candidate: String) -> Bool { envelope == candidate }
    var description: String { "StoredDeviceLicenceBootstrap" }
    var debugDescription: String { description }
}

/// Verification and readback are mandatory. No replacement, repair, deletion,
/// account switching, discovery or fallback exists. Concurrent insertions rely on
/// the storage capability's insert-if-absent guarantee; their winner is re-read.
actor DeviceLicenceBootstrapRepository {
    private let profile: DeviceLicenceBootstrapTrustProfile
    private let storage: any DeviceLicenceBootstrapSecureStorage
    init(profile: DeviceLicenceBootstrapTrustProfile, storage: any DeviceLicenceBootstrapSecureStorage) {
        self.profile = profile; self.storage = storage
    }
    private func checkCancellation() throws {
        if Task.isCancelled { throw DeviceLicenceBootstrapRepositoryFailure.cancelled }
    }
    private func verified(_ envelope: String) throws -> StoredDeviceLicenceBootstrap {
        do {
            let value = try DeviceLicenceBootstrapVerifier.verify(envelope, profile: profile)
            return .init(envelope: envelope, verified: value)
        } catch {
            if Task.isCancelled { throw DeviceLicenceBootstrapRepositoryFailure.cancelled }
            throw DeviceLicenceBootstrapRepositoryFailure.invalidBootstrap
        }
    }
    func load() async throws -> StoredDeviceLicenceBootstrap? {
        try checkCancellation()
        let bytes: Data?
        do { bytes = try await storage.read() }
        catch { throw DeviceLicenceBootstrapRepositoryFailure.storageUnavailable }
        try checkCancellation()
        guard let bytes else { return nil }
        guard !bytes.isEmpty, bytes.count <= DeviceLicenceBootstrapVerifier.maximumEnvelopeBytes,
              let envelope = String(data: bytes, encoding: .utf8) else {
            throw DeviceLicenceBootstrapRepositoryFailure.invalidBootstrap
        }
        return try verified(envelope)
    }
    func persistIfAbsent(_ envelope: String) async throws -> StoredDeviceLicenceBootstrap {
        try checkCancellation()
        _ = try verified(envelope) // Pure validation precedes every storage effect.
        if let existing = try await load() {
            guard existing.matches(envelope) else { throw DeviceLicenceBootstrapRepositoryFailure.conflict }
            return existing
        }
        try checkCancellation()
        do { _ = try await storage.insertIfAbsent(Data(Array(envelope.utf8))) }
        catch { throw DeviceLicenceBootstrapRepositoryFailure.storageUnavailable }
        try checkCancellation()
        guard let committed = try await load() else { throw DeviceLicenceBootstrapRepositoryFailure.storageUnavailable }
        guard committed.matches(envelope) else { throw DeviceLicenceBootstrapRepositoryFailure.conflict }
        return committed
    }
}

/// Optional native capability, inert on construction. Uses only an explicitly
/// selected nonsynchronizing device-local generic-password item. Never prompts,
/// updates/deletes an item or discovers other namespaces. The integrating caller
/// must keep this explicit bootstrap namespace distinct from device identity.
struct DeviceLicenceBootstrapKeychainStorage: DeviceLicenceBootstrapSecureStorage {
    private let service: String, account: String
    private let calls: any DeviceIdentityKeychainCalls
    private let work = DeviceIdentityWorkQueue(label: "cliphoard.prototype.bootstrap-storage")
    init(service: String, account: String, calls: any DeviceIdentityKeychainCalls) throws {
        func valid(_ value: String) -> Bool {
            (1...128).contains(value.utf8.count) && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
            }
        }
        guard valid(service), valid(account) else { throw DeviceLicenceBootstrapRepositoryFailure.storageUnavailable }
        self.service = service; self.account = account; self.calls = calls
    }
    func read() async throws -> Data? {
        do {
            return try await work.perform {
                var query = self.query(); query[kSecMatchLimit as String] = kSecMatchLimitOne
                query[kSecReturnData as String] = true
                let (status, value) = calls.copyMatching(query)
                if status == errSecItemNotFound { return nil }
                guard status == errSecSuccess, let data = value as? Data, !data.isEmpty,
                      data.count <= DeviceLicenceBootstrapVerifier.maximumEnvelopeBytes else {
                    throw DeviceLicenceBootstrapRepositoryFailure.storageUnavailable
                }
                return Data(Array(data))
            }
        } catch { throw DeviceLicenceBootstrapRepositoryFailure.storageUnavailable }
    }
    func insertIfAbsent(_ record: Data) async throws -> Bool {
        guard !record.isEmpty, record.count <= DeviceLicenceBootstrapVerifier.maximumEnvelopeBytes else {
            throw DeviceLicenceBootstrapRepositoryFailure.storageUnavailable
        }
        let captured = Data(Array(record))
        do {
            return try await work.perform {
                var attributes = self.query()
                attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                attributes[kSecValueData as String] = captured
                let status = calls.add(attributes)
                if status == errSecDuplicateItem { return false }
                guard status == errSecSuccess else { throw DeviceLicenceBootstrapRepositoryFailure.storageUnavailable }
                return true
            }
        } catch { throw DeviceLicenceBootstrapRepositoryFailure.storageUnavailable }
    }
    private func query() -> [String: Any] {
        let context = LAContext(); context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false, kSecUseDataProtectionKeychain as String: true,
            kSecUseAuthenticationContext as String: context]
    }
}
#endif
