import Foundation
import Darwin

/// Anchors all transport operations to an owner-only directory descriptor. The
/// directory is selected/created by the UI; this type never changes its permissions.
final class AgentWriteDirectory: @unchecked Sendable {
    enum Failure: Error { case invalidName, unsafeDirectory, unsafeFile, io, tooManyRequests, exists }
    private let fd: Int32
    init(url: URL) throws {
        guard url.isFileURL else { throw Failure.unsafeDirectory }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unsafeDirectory }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), (info.st_mode & 0o777) == 0o700 else {
            close(descriptor); throw Failure.unsafeDirectory
        }
        fd = descriptor
    }
    deinit { close(fd) }
    private func valid(_ name: String) -> Bool {
        if name == "session.json" { return true }
        for suffix in [".request", ".reply"] where name.hasSuffix(suffix) {
            let prefix = String(name.dropLast(suffix.count))
            if let id = UUID(uuidString: prefix), id.uuidString.lowercased() == prefix { return true }
        }
        return false
    }
    private func requireName(_ name: String) throws { guard valid(name) else { throw Failure.invalidName } }
    func read(_ name: String, maxBytes: Int) throws -> Data? {
        try requireName(name)
        guard maxBytes > 0, maxBytes <= AgentWriteProtocol.maximumWireBytes else { throw Failure.unsafeFile }
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if file < 0 { if errno == ENOENT { return nil }; throw Failure.unsafeFile }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, (info.st_mode & 0o777) == 0o600,
              info.st_size >= 0, info.st_size <= maxBytes else { throw Failure.unsafeFile }
        var result = Data(); var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let n = Darwin.read(file, &buffer, min(buffer.count, maxBytes - result.count + 1))
            if n < 0 { if errno == EINTR { continue }; throw Failure.io }
            if n == 0 { break }
            guard result.count + n <= maxBytes else { throw Failure.unsafeFile }
            result.append(contentsOf: buffer.prefix(n))
        }
        var after = stat()
        guard fstat(file, &after) == 0, after.st_size == info.st_size, result.count == info.st_size,
              after.st_nlink == 1, after.st_uid == getuid(), (after.st_mode & 0o777) == 0o600 else { throw Failure.unsafeFile }
        return result
    }
    func writeExclusive(_ name: String, data: Data) throws {
        try requireName(name)
        guard data.count <= AgentWriteProtocol.maximumWireBytes else { throw Failure.unsafeFile }
        let temporary = ".agent-\(UUID().uuidString.lowercased()).tmp"
        let file = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw Failure.io }
        defer { close(file); unlinkat(fd, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 { if errno == EINTR { continue }; throw Failure.io }
                guard n > 0 else { throw Failure.io }; offset += n
            }
        }
        guard fsync(file) == 0 else { throw Failure.io }
        // RENAME_EXCL publishes atomically without overwriting or a transient second hard link.
        guard renameatx_np(fd, temporary, fd, name, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw Failure.exists }; throw Failure.io
        }
        guard fsync(fd) == 0 else { throw Failure.io }
    }
    func remove(_ name: String) throws {
        try requireName(name)
        // unlinkat removes only this directory entry, never a symlink target.
        if unlinkat(fd, name, 0) != 0 && errno != ENOENT { throw Failure.io }
    }
    func requestNames(limit: Int = 64) throws -> [String] {
        guard (1...64).contains(limit) else { throw Failure.tooManyRequests }
        // openat(".") creates a fresh enumeration offset without following a path.
        let scanFD = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard scanFD >= 0 else { throw Failure.io }
        guard let directory = fdopendir(scanFD) else { close(scanFD); throw Failure.io }
        defer { closedir(directory) }
        var names: [String] = []; var scanned = 0
        errno = 0
        while let entry = readdir(directory) {
            scanned += 1
            guard scanned <= 256 else { throw Failure.tooManyRequests }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name.hasSuffix(".request") {
                try requireName(name); names.append(name)
                guard names.count <= limit else { throw Failure.tooManyRequests }
            }
            errno = 0
        }
        guard errno == 0 else { throw Failure.io }
        return names.sorted()
    }
}
