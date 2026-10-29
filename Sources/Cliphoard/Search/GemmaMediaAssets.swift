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
    let bundleDirectory: URL?
    private var downloading = false

    init(directory: URL = GemmaMediaAssets.defaultDirectory,
         bundleDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent("EmbeddingGemma2", isDirectory: true)) {
        self.directory = directory
        self.bundleDirectory = bundleDirectory
    }

    private func verifiedBundledModel() throws -> URL? {
        guard let bundleDirectory else { return nil }
        let url = bundleDirectory.appendingPathComponent(Self.filename)
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil else { return nil }
        try Self.verify(url)
        return url
    }

    /// Full SHA256 verification is performed before each engine construction, never inferred from a filename.
    func verifiedModel() throws -> URL {
        if let bundled = try verifiedBundledModel() { return bundled }
        try Self.checkDirectory(directory)
        let url = directory.appendingPathComponent(Self.filename)
        try Self.verify(url)
        return url
    }

    /// Only invoke following the user's explicit model preparation action.
    func download() async throws -> URL {
        guard !downloading else { throw Failure.alreadyDownloading }
        downloading = true
        defer { downloading = false }
        try Task.checkCancellation()
        if let bundled = try verifiedBundledModel() { return bundled }
        try Self.validatePath(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try Self.checkDirectory(directory)
        let destination = directory.appendingPathComponent(Self.filename)
        if FileManager.default.fileExists(atPath: destination.path) {
            try Self.verify(destination)
            return destination
        }
        let staging = directory.appendingPathComponent(".download-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        let transfer = GemmaModelDownload(destination: staging, maximumBytes: Self.byteCount)
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
        guard url.isFileURL else { throw Failure.unsafePath }
        var component = url.standardizedFileURL
        while component.path != "/" {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: component.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw Failure.unsafePath
            }
            component.deleteLastPathComponent()
        }
    }

    private static func checkDirectory(_ url: URL) throws {
        try validatePath(url)
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw Failure.unsafePath
        }
    }
}

/// Per-transfer ephemeral session; cancels oversized downloads and refuses non-HTTPS redirects.
private final class GemmaModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let maximumBytes: Int64
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var cancelled = false
    private var saved = false
    private var failure: Error?

    init(destination: URL, maximumBytes: Int64) {
        self.destination = destination
        self.maximumBytes = maximumBytes
    }

    func start(_ url: URL) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                config.httpCookieStorage = nil
                config.httpShouldSetCookies = false
                config.urlCredentialStorage = nil
                config.requestCachePolicy = .reloadIgnoringLocalCacheData
                config.timeoutIntervalForRequest = 60
                config.timeoutIntervalForResource = 600
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
                self.session = session
                session.downloadTask(with: url).resume()
                lock.unlock()
            }
        } onCancel: {
            self.lock.lock(); self.cancelled = true; let session = self.session; self.lock.unlock()
            session?.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let host = request.url?.host?.lowercased() ?? ""
        let approved = host == "huggingface.co" || host.hasSuffix(".huggingface.co") || host.hasSuffix(".hf.co")
        guard request.url?.scheme == "https", request.url?.user == nil, request.url?.password == nil, approved else {
            failure = GemmaMediaAssets.Failure.downloadRefused
            completionHandler(nil); task.cancel(); return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes {
            failure = GemmaMediaAssets.Failure.invalidModel
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
                  (try location.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(maximumBytes) else {
                throw GemmaMediaAssets.Failure.downloadRefused
            }
            try FileManager.default.moveItem(at: location, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            saved = true
        } catch { failure = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation; self.continuation = nil
        let wasCancelled = cancelled; self.session = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        if wasCancelled { continuation?.resume(throwing: CancellationError()) }
        else if let error = failure ?? error { continuation?.resume(throwing: error) }
        else if saved { continuation?.resume() }
        else { continuation?.resume(throwing: GemmaMediaAssets.Failure.downloadRefused) }
    }
}
