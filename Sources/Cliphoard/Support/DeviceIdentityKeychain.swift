#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE
import Foundation
import LocalAuthentication
import Security

/// Injectable synchronous native calls, invoked only on the adapter's queue.
protocol DeviceIdentityKeychainCalls: Sendable {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?)
    func add(_ attributes: [String: Any]) -> OSStatus
}

struct DeviceIdentitySystemKeychainCalls: DeviceIdentityKeychainCalls {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }
    func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }
}

/// No default namespace or global instance: an integrating caller must explicitly
/// choose its app/access scope. Existing legacy keychain items are never queried.
struct DeviceIdentityKeychainStorage: DeviceIdentityStorage {
    private let service: String
    private let account: String
    private let calls: any DeviceIdentityKeychainCalls
    private let work = DeviceIdentityWorkQueue(label: "cliphoard.prototype.identity.storage")

    init(service: String, account: String, calls: any DeviceIdentityKeychainCalls) throws {
        func valid(_ value: String) -> Bool {
            (1...128).contains(value.utf8.count) && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
            }
        }
        guard valid(service), valid(account) else { throw DeviceIdentityFailure.invalidRecord }
        self.service = service; self.account = account; self.calls = calls
    }

    func read() async throws -> Data? {
        try await work.perform {
            var query = self.query()
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecReturnData as String] = true
            let (status, value) = calls.copyMatching(query)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw Self.failure(status) }
            guard let data = value as? Data, data.count <= DeviceIdentityRecord.maximumBytes else {
                throw DeviceIdentityFailure.invalidRecord
            }
            return data
        }
    }

    func insertIfAbsent(_ record: Data) async throws -> Bool {
        _ = try DeviceIdentityRecord.decode(record)
        return try await work.perform {
            var attributes = self.query()
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            attributes[kSecValueData as String] = record
            let status = calls.add(attributes)
            if status == errSecDuplicateItem { return false }
            guard status == errSecSuccess else { throw Self.failure(status) }
            return true
        }
    }

    private func query() -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: false, kSecUseDataProtectionKeychain as String: true,
                kSecUseAuthenticationContext as String: context]
    }

    private static func failure(_ status: OSStatus) -> DeviceIdentityFailure {
        if status == errSecInteractionNotAllowed || status == errSecInteractionRequired || status == errSecAuthFailed {
            return .unavailable(.interactionRequired)
        }
        return .unavailable(.storage)
    }
}
#endif
