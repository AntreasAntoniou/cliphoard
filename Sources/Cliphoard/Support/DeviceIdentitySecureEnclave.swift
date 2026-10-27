#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE
import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// A synchronous Security/CryptoKit call may still block this private queue.
/// Cancellation discards late results; it cannot interrupt an OS call or undo
/// an insertion that already completed. No main-thread startup call is made.
struct DeviceIdentityWorkQueue: Sendable {
    private let queue: DispatchQueue
    init(label: String) { queue = DispatchQueue(label: label, qos: .utility) }
    func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// Optional, disabled native implementation. Constructing it does no hardware or
/// storage work. No fallback to P256.Signing.PrivateKey exists in this adapter.
struct DeviceIdentitySecureEnclave: DeviceIdentityKeyOperations {
    private let work = DeviceIdentityWorkQueue(label: "cliphoard.prototype.identity.enclave")

    func isAvailable() async -> Bool { (try? await work.perform { SecureEnclave.isAvailable }) ?? false }

    func create() async throws -> DeviceIdentityMaterial {
        try await work.perform {
            guard SecureEnclave.isAvailable else { throw DeviceIdentityFailure.unavailable(.secureHardware) }
            guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                              .privateKeyUsage, nil) else {
                throw DeviceIdentityFailure.unavailable(.secureKey)
            }
            do {
                let key = try SecureEnclave.P256.Signing.PrivateKey(compactRepresentable: false, accessControl: access,
                                                                   authenticationContext: Self.context())
                return DeviceIdentityMaterial(publicKeyX963: key.publicKey.x963Representation, wrappedKey: key.dataRepresentation)
            } catch { throw DeviceIdentityFailure.unavailable(.secureKey) }
        }
    }

    func publicKey(for wrappedKey: Data) async throws -> Data {
        try await work.perform { try Self.restore(wrappedKey).publicKey.x963Representation }
    }

    func sign(_ message: Data, using wrappedKey: Data) async throws -> Data {
        try await work.perform {
            do { return try Self.restore(wrappedKey).signature(for: message).rawRepresentation }
            catch let error as DeviceIdentityFailure { throw error }
            catch { throw DeviceIdentityFailure.unavailable(.secureKey) }
        }
    }

    private static func restore(_ wrapped: Data) throws -> SecureEnclave.P256.Signing.PrivateKey {
        guard SecureEnclave.isAvailable else { throw DeviceIdentityFailure.unavailable(.secureHardware) }
        guard (1...DeviceIdentityRecord.maximumWrappedBytes).contains(wrapped.count) else {
            throw DeviceIdentityFailure.invalidRecord
        }
        do { return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: wrapped, authenticationContext: context()) }
        catch { throw DeviceIdentityFailure.unavailable(.secureKey) }
    }

    private static func context() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }
}
#endif
