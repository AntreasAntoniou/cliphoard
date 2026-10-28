#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE && !APP_STORE
import Foundation
import Darwin

/// Staged production configuration. The additional compile guard is deliberately
/// absent from default builds. Construction never reads Keychain or creates paths.
@MainActor
enum DeviceLicenceReleaseConfiguration {
    static func makeRuntime(bundleIdentifier: String?, applicationSupport: URL,
                            keychain: any DeviceIdentityKeychainCalls = DeviceIdentitySystemKeychainCalls()) -> DeviceLicenceDirectRuntime? {
#if CLIPHOARD_DEVICE_LICENSING_CONFIGURED
        guard bundleIdentifier == "ai.a2-labs.cliphoard" else { return nil }
        do {
            let location = try DeviceLicenceReleaseDirectory(applicationSupport: applicationSupport)
            func publicKey(_ value: String) throws -> Data {
                let base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                guard let data = Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)),
                      DeviceLicenceVerifier.canonicalPublicKey(data) != nil else {
                    throw DeviceLicenceDirectApplicationFailure.invalidConfiguration
                }
                return data
            }
            let profile = try DeviceLicenceBootstrapTrustProfile(profileID: "cliphoard-direct-v1",
                bootstrapKeyID: "clipb1-prod-20261027",
                bootstrapPublicKey: publicKey("BCbYmUTFXajEkdEn_OLQHeCQucuzQzNo9YsZS9PW6V0ZjTLtPXoyvuSpssUPTfsnm2INZ_2bh4HIWucOniNMgGw"),
                receiptIssuers: ["clipd1-prod-20261027": publicKey("BAyb6dQQVz7p-xtjWx5RZaCWdrimdH_z6-Q39ru_zCUivuMZS3MQVvRuVULfwEeEn6IkhUq30qPkXDTQv3nBBc0")])
            let storage = try DeviceLicenceBootstrapKeychainStorage(service: "ai.a2-labs.cliphoard.direct.bootstrap.v1",
                account: "cliphoard-direct-v1", calls: keychain)
            let repository = DeviceLicenceBootstrapRepository(profile: profile,
                storage: DeviceLicenceReleaseBootstrapStorage(base: storage, location: location))
            let configuration = try DeviceLicenceDirectApplicationConfiguration(
                origin: URL(string: "https://purchase.cliphoard.dev")!, expectedDevicePublicKey: nil,
                receiptFileURL: location.receiptURL,
                identityKeychainService: "ai.a2-labs.cliphoard.direct.device.v1", identityKeychainAccount: "cliphoard-direct-v1",
                resourceTimeout: 30)
            return DeviceLicenceDirectRuntime(owner: .native(repository: repository, configuration: configuration))
        } catch { return nil }
#else
        return nil
#endif
    }
}

private struct DeviceLicenceReleaseBootstrapStorage: DeviceLicenceBootstrapSecureStorage {
    let base: DeviceLicenceBootstrapKeychainStorage
    let location: DeviceLicenceReleaseDirectory
    func read() async throws -> Data? {
        let record = try await base.read()
        if record != nil { try Task.checkCancellation(); try location.prepare() }
        return record
    }
    func insertIfAbsent(_ record: Data) async throws -> Bool {
        try Task.checkCancellation(); try location.prepare()
        return try await base.insertIfAbsent(record)
    }
}

/// Only the dedicated leaf can be created. Existing paths are never chmod'ed,
/// replaced or migrated. Receipt storage independently rechecks the path on IO.
struct DeviceLicenceReleaseDirectory: Sendable {
    private let parents: [String]
    private let leaf = "ai.a2-labs.cliphoard.direct-licensing-v1"
    let receiptURL: URL
    init(applicationSupport: URL) throws {
        let path = applicationSupport.path, parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard applicationSupport.isFileURL, applicationSupport.host == nil || applicationSupport.host == "",
              applicationSupport.query == nil, applicationSupport.fragment == nil,
              path.hasPrefix("/"), path.utf8.count < Int(PATH_MAX) - 100, !path.utf8.contains(0), parts.count > 2,
              parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DeviceLicenceReceiptStorageFailure.invalidPath
        }
        parents = parts.dropFirst().map(String.init)
        receiptURL = applicationSupport.appendingPathComponent(leaf, isDirectory: true).appendingPathComponent("approved-receipt-v1")
    }
    func prepare() throws {
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw DeviceLicenceReceiptStorageFailure.insecurePath }
        defer { close(parent) }
        for component in parents {
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw DeviceLicenceReceiptStorageFailure.insecurePath }
            close(parent); parent = next
            var status = stat()
            guard fstat(parent, &status) == 0, status.st_uid == geteuid() || status.st_uid == 0,
                  status.st_mode & 0o022 == 0 || (status.st_uid == 0 && status.st_mode & 0o1000 != 0) else {
                throw DeviceLicenceReceiptStorageFailure.insecurePath
            }
        }
        var parentStatus = stat(), volume = statfs()
        guard fstat(parent, &parentStatus) == 0, parentStatus.st_uid == geteuid(),
              fstatfs(parent, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0 else {
            throw DeviceLicenceReceiptStorageFailure.insecurePath
        }
        let created = mkdirat(parent, leaf, 0o700) == 0
        guard created || errno == EEXIST else { throw DeviceLicenceReceiptStorageFailure.insecurePath }
        let directory = openat(parent, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw DeviceLicenceReceiptStorageFailure.insecurePath }
        defer { close(directory) }
        var status = stat()
        guard fstat(directory, &status) == 0, status.st_uid == geteuid(), status.st_mode & 0o777 == 0o700 else {
            throw DeviceLicenceReceiptStorageFailure.insecurePath
        }
        if let acl = acl_get_fd_np(directory, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var entry: acl_entry_t?
            guard acl_valid(acl) == 0, acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1, errno == EINVAL else {
                throw DeviceLicenceReceiptStorageFailure.insecurePath
            }
        } else if errno != ENOENT { throw DeviceLicenceReceiptStorageFailure.insecurePath }
        if created {
            guard fsync(directory) == 0, fsync(parent) == 0 else { throw DeviceLicenceReceiptStorageFailure.io }
        }
    }
}
#endif
