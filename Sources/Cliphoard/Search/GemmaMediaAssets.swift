import Foundation
import CryptoKit

/// Explicit opt-in acquisition of one immutable, publicly hosted model. No load path downloads.
actor GemmaMediaAssets {
    static let revision = "94408f31843f8bd0adb11c262292627287f5fda4"
    static let sha256 = "e7a8a2204b91e0f96e92960e84a09a89212e1633dcb7575a9bf3378b4df77f4c"
    static let byteCount: Int64 = 484_622_336
    static let filename = "embeddinggemma-2-740m.litertlm"
    static let source = URL(string: "https://huggingface.co/litert-community/embeddinggemma-2-740m-litert-lm/resolve/\(revision)/\(filename)")!
    static let signature = "embeddinggemma2-litert0181-\(sha256.prefix(16))-768-retrieval-v1"
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cliphoard/Models/EmbeddingGemma2", isDirectory: true)
    }
    enum Failure: Error { case unsafePath, missing, invalidModel, downloadRefused, alreadyDownloading }
    let directory: URL
    private var downloading = false

    init(directory: URL = GemmaMediaAssets.defaultDirectory) { self.directory = directory }

    /// A cheap UI hint only; verifiedModel still hashes every byte before use.
    nonisolated static func localCandidateExists(directory: URL = defaultDirectory) -> Bool {
        let url = directory.appendingPathComponent(filename)
        guard (try? validatePath(url)) != nil,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return attrs[.type] as? FileAttributeType == .typeRegular && (attrs[.size] as? NSNumber)?.int64Value == byteCount
    }

    /// Full SHA256 verification is performed before each engine construction, never inferred from a filename.
    func verifiedModel() throws -> URL {
        try Self.checkDirectory(directory)
        let url = directory.appendingPathComponent(Self.filename)
        try Self.verify(url)
        return url
    }

    /// Only invoke following the user's explicit model preparation action.
    func download(progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws -> URL {
        guard !downloading else { throw Failure.alreadyDownloading }
        downloading = true
        defer { downloading = false }
        try Task.checkCancellation()
        try Self.validatePath(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try Self.checkDirectory(directory)
        let destination = directory.appendingPathComponent(Self.filename)
        if FileManager.default.fileExists(atPath: destination.path) {
            try Self.verify(destination)
            progress(Self.byteCount, Self.byteCount)
            return destination
        }
        let staging = directory.appendingPathComponent(".download-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        progress(0, Self.byteCount)
        let transfer = SpeechAssetTransfer(destination: staging, expectedBytes: Self.byteCount,
            deadline: ProcessInfo.processInfo.systemUptime + 600,
            progress: { progress($0, Self.byteCount) })
        try await transfer.start(Self.source)
        try Task.checkCancellation()
        try Self.verify(staging)
        // moveItem refuses an existing destination. No invalid previous model is silently replaced.
        try FileManager.default.moveItem(at: staging, to: destination)
        return destination
    }

    static func verify(_ url: URL) throws {
        try validatePath(url)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              Int64(values.fileSize ?? -1) == byteCount else { throw Failure.invalidModel }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256()
        var count: Int64 = 0
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            count += Int64(chunk.count)
            guard count <= byteCount else { throw Failure.invalidModel }
            digest.update(data: chunk)
        }
        guard count == byteCount, digest.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw Failure.invalidModel
        }
    }

    /// Walk existing ancestors before creating any missing suffix; resolving a nonexistent
    /// full path alone does not reliably reveal an ancestor symlink on macOS.
    static func validatePath(_ url: URL) throws {
        try MediaSpeechAssetManifest.safePath(url)
    }

    private static func checkDirectory(_ url: URL) throws {
        try validatePath(url)
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw Failure.unsafePath
        }
    }
}
