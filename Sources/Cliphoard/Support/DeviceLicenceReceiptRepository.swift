#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE
import Foundation
import CryptoKit
import Darwin

enum DeviceLicenceReceiptStorageFailure: Error, Equatable, Sendable {
    case invalidPath, insecurePath, busy, corrupt, io, conflict, cancelled, commitUncertain
}
struct DeviceLicenceReceiptSnapshot: Equatable, Sendable {
    let envelope: String?
    let revision: Data?
}
final class DeviceLicenceReceiptPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var claimed = false
    func cancel() { lock.lock(); defer { lock.unlock() }; if !claimed { cancelled = true } }
    /// Linearization boundary for cancellation. The native adapter immediately
    /// calls rename without an await. Cancellation cannot undo a claimed commit.
    fileprivate func claim() throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, !claimed else { throw DeviceLicenceReceiptStorageFailure.cancelled }
        claimed = true
    }
}
protocol DeviceLicenceReceiptStorage: Sendable {
    func read() async throws -> DeviceLicenceReceiptSnapshot
    func replace(_ envelope: String, expectedRevision: Data?, permit: DeviceLicenceReceiptPermit)
        async throws -> DeviceLicenceReceiptSnapshot
}
/// File operations are injectable for fault testing; native implementations operate
/// only on descriptors opened and checked by the repository. They never log data.
protocol DeviceLicenceReceiptFileIO: Sendable {
    func read(_ fd: Int32, maximum: Int) throws -> Data
    func write(_ bytes: Data, to fd: Int32) throws
    func synchronize(_ fd: Int32, full: Bool) throws
    func rename(in directory: Int32, from: String, to: String) throws
}
struct DeviceLicenceReceiptPOSIXIO: DeviceLicenceReceiptFileIO {
    func read(_ fd: Int32, maximum: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maximum + 1), count = 0
        while count < buffer.count {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: count), $0.count - count) }
            if n < 0 { if errno == EINTR { continue }; throw DeviceLicenceReceiptStorageFailure.io }
            if n == 0 { break }; count += n
        }
        guard count <= maximum else { throw DeviceLicenceReceiptStorageFailure.corrupt }
        return Data(buffer.prefix(count))
    }
    func write(_ bytes: Data, to fd: Int32) throws {
        try bytes.withUnsafeBytes { buffer in
            var count = 0
            while count < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: count), buffer.count - count)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw DeviceLicenceReceiptStorageFailure.io }; count += n
            }
        }
    }
    func synchronize(_ fd: Int32, full: Bool) throws {
        let result = full ? fcntl(fd, F_FULLFSYNC) : fsync(fd)
        guard result == 0 else { throw DeviceLicenceReceiptStorageFailure.io }
    }
    func rename(in directory: Int32, from: String, to: String) throws {
        guard renameat(directory, from, directory, to) == 0 else { throw DeviceLicenceReceiptStorageFailure.io }
    }
}

/// Explicit private directory; no default path, directory creation or repair.
/// A persistent sibling flock serializes cooperating processes on a local volume.
/// The lock is never unlinked; arbitrary same-user writers are outside this contract.
final class DeviceLicenceReceiptRepository: DeviceLicenceReceiptStorage, @unchecked Sendable {
    private static let prefix = "cliphoard.approved-envelope\n1\n"
    private static let maximum = 1200
    private let components: [String]
    private let name: String
    private let io: any DeviceLicenceReceiptFileIO
    private let queue = DispatchQueue(label: "cliphoard.prototype.receipt-storage", qos: .utility)

    init(fileURL: URL, io: any DeviceLicenceReceiptFileIO = DeviceLicenceReceiptPOSIXIO()) throws {
        let path = fileURL.path, parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard fileURL.isFileURL, fileURL.host == nil || fileURL.host == "",
              fileURL.query == nil, fileURL.fragment == nil, path.hasPrefix("/"),
              path.utf8.count < Int(PATH_MAX), !path.utf8.contains(0), parts.count > 2,
              parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              let leaf = parts.last, (1...100).contains(leaf.utf8.count),
              leaf.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || $0 == 45 || $0 == 46 || $0 == 95 }) else {
            throw DeviceLicenceReceiptStorageFailure.invalidPath
        }
        components = parts.dropFirst().dropLast().map(String.init); name = String(leaf); self.io = io
    }

    func read() async throws -> DeviceLicenceReceiptSnapshot {
        try await perform { try self.withLock { try self.readSnapshot(in: $0) } }
    }
    func replace(_ envelope: String, expectedRevision: Data?, permit: DeviceLicenceReceiptPermit)
        async throws -> DeviceLicenceReceiptSnapshot {
        let bytes = try Self.encode(envelope)
        return try await withTaskCancellationHandler {
            guard !Task.isCancelled else { throw DeviceLicenceReceiptStorageFailure.cancelled }
            return try await perform {
                try self.withLock { directory in
                    let prior = try self.readSnapshot(in: directory)
                    guard prior.revision == expectedRevision else { throw DeviceLicenceReceiptStorageFailure.conflict }
                    let temporary = "." + self.name + "." + UUID().uuidString.lowercased() + ".tmp"
                    let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    guard fd >= 0 else { throw DeviceLicenceReceiptStorageFailure.io }
                    var renamed = false
                    defer { close(fd); if !renamed { _ = unlinkat(directory, temporary, 0) } }
                    try Self.checkFile(fd)
                    try self.io.write(bytes, to: fd)
                    try self.io.synchronize(fd, full: true)
                    try permit.claim()
                    // Any failure from this point is uncertain. Never roll back or
                    // automatically retry a rename that may already have succeeded.
                    do {
                        try self.io.rename(in: directory, from: temporary, to: self.name)
                        renamed = true
                        try self.io.synchronize(directory, full: false)
                        let observed = try self.readSnapshot(in: directory)
                        guard observed.revision == Data(SHA256.hash(data: bytes)), observed.envelope == envelope else {
                            throw DeviceLicenceReceiptStorageFailure.commitUncertain
                        }
                        return observed
                    } catch { throw DeviceLicenceReceiptStorageFailure.commitUncertain }
                }
            }
        } onCancel: { permit.cancel() }
    }

    private func perform<T: Sendable>(_ action: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try action() }) }
        }
    }

    private func withLock<T>(_ action: (Int32) throws -> T) throws -> T {
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw DeviceLicenceReceiptStorageFailure.insecurePath }
        defer { close(directory) }
        for part in components {
            let next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw DeviceLicenceReceiptStorageFailure.insecurePath }
            close(directory); directory = next
            var status = stat()
            guard fstat(directory, &status) == 0,
                  status.st_uid == geteuid() || status.st_uid == 0,
                  status.st_mode & 0o022 == 0 || (status.st_uid == 0 && status.st_mode & 0o1000 != 0) else {
                throw DeviceLicenceReceiptStorageFailure.insecurePath
            }
        }
        var status = stat(), volume = statfs()
        guard fstat(directory, &status) == 0, status.st_uid == geteuid(), status.st_mode & 0o077 == 0,
              fstatfs(directory, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0 else {
            throw DeviceLicenceReceiptStorageFailure.insecurePath
        }
        try Self.noACL(directory)
        let lockName = "." + name + ".lock", flags = O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        var lock = openat(directory, lockName, flags)
        if lock < 0, errno == ENOENT {
            lock = openat(directory, lockName, flags | O_CREAT | O_EXCL, 0o600)
            if lock < 0, errno == EEXIST { throw DeviceLicenceReceiptStorageFailure.busy }
        }
        guard lock >= 0 else { throw DeviceLicenceReceiptStorageFailure.insecurePath }
        defer { close(lock) }
        try Self.checkFile(lock)
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw DeviceLicenceReceiptStorageFailure.busy }
        defer { _ = flock(lock, LOCK_UN) }
        return try action(directory)
    }

    private static func noACL(_ fd: Int32) throws {
        // On macOS an absent extended ACL returns NULL/ENOENT on a valid open
        // descriptor (rather than an allocated empty ACL). Other errors fail closed.
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return }
            throw DeviceLicenceReceiptStorageFailure.insecurePath
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        guard acl_valid(acl) == 0, acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1, errno == EINVAL else {
            throw DeviceLicenceReceiptStorageFailure.insecurePath
        }
    }
    private static func checkFile(_ fd: Int32) throws {
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(), status.st_nlink == 1, status.st_mode & 0o077 == 0 else {
            throw DeviceLicenceReceiptStorageFailure.insecurePath
        }
        try noACL(fd)
    }
    private func readSnapshot(in directory: Int32) throws -> DeviceLicenceReceiptSnapshot {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return .init(envelope: nil, revision: nil) }
            throw DeviceLicenceReceiptStorageFailure.insecurePath
        }
        defer { close(fd) }
        try Self.checkFile(fd)
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_size <= Self.maximum else { throw DeviceLicenceReceiptStorageFailure.corrupt }
        let bytes = try io.read(fd, maximum: Self.maximum)
        guard bytes.count <= Self.maximum, let text = String(data: bytes, encoding: .ascii), text.hasPrefix(Self.prefix) else {
            throw DeviceLicenceReceiptStorageFailure.corrupt
        }
        let fields = text.dropFirst(Self.prefix.count).split(separator: "\n", omittingEmptySubsequences: false)
        guard fields.count == 2, let revision = UUID(uuidString: String(fields[0])),
              revision.uuidString.lowercased() == fields[0], Self.validEnvelope(String(fields[1])) else {
            throw DeviceLicenceReceiptStorageFailure.corrupt
        }
        return .init(envelope: String(fields[1]), revision: Data(SHA256.hash(data: bytes)))
    }
    private static func validEnvelope(_ envelope: String) -> Bool {
        guard (1...DeviceLicenceVerifier.maximumEnvelopeBytes).contains(envelope.utf8.prefix(1025).count),
              envelope.hasPrefix("CLIPD1.") else { return false }
        let parts = envelope.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.dropFirst().allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        } }
    }
    private static func encode(_ envelope: String) throws -> Data {
        guard validEnvelope(envelope) else { throw DeviceLicenceReceiptStorageFailure.corrupt }
        return Data((prefix + UUID().uuidString.lowercased() + "\n" + envelope).utf8)
    }
}
#endif
