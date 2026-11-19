import Foundation
import CoreML
import Combine
import CryptoKit
import Darwin

/// Explicit acquisition from immutable Hugging Face revisions. Cached archives are
/// independently verified before local compilation; the application bundle is never searched.
enum ModelAssets {
    struct Artifact: Sendable {
        let repository: String?
        let revision: String?
        let path: String
        let bytes: Int64
        let sha256: String
        let models: [String]
        let tokenizer: String
        var url: URL? {
            guard let repository, let revision else { return nil }
            return URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(path)")
        }
    }
    enum Failure: LocalizedError {
        case unknownModel, unpublishedArtifact, missing, corrupt, busy, unpackFailed
        var errorDescription: String? {
            switch self {
            case .unknownModel: return "This model is not in the verified catalog."
            case .unpublishedArtifact: return "This model's Hugging Face download is not yet available. Existing verified archive caches can still be prepared offline."
            case .missing: return "Download and prepare this model before using it offline."
            case .corrupt: return "Model cache verification failed. Existing files were preserved."
            case .busy: return "This model is already being prepared."
            case .unpackFailed: return "The verified model archive could not be unpacked."
            }
        }
    }
    enum AssetSource { case huggingFace(repo: String), unavailable }
    static let catalog: [String: Artifact] = [
        "open-ogma-micro": Artifact(repository: "axiotic/open-ogma-micro", revision: "acb318a6f4411a42085838e674ebc2aed1219310", path: "coreml/open-ogma-micro.zip", bytes: 5_090_189, sha256: "9163037e51596ab6b17c4bc51d7e2b4b4533ca6f205b7988504774e78925ac39", models: ["open-ogma-micro"], tokenizer: "open-ogma-micro"),
        "open-ogma-small": Artifact(repository: "axiotic/open-ogma-small", revision: "3f4cd68f43719ca494772fcc80005c115d8d91ff", path: "coreml/open-ogma-small.zip", bytes: 16_981_733, sha256: "179517c6925914ec37a734c4f0aa2971b9b93ecee9e8d6e98aa4f66a17709135", models: ["open-ogma-small"], tokenizer: "open-ogma-small"),
        // Exact compatible conversions published and independently read back from Hugging Face.
        "all-MiniLM-L6-v2": Artifact(repository: "axiotic/cliphoard-coreml-models", revision: "735cf3ec9bcaff2a46dd0f41997d0ab10bf068b4", path: "coreml/all-MiniLM-L6-v2.zip", bytes: 41_925_567, sha256: "ff202030f35c740193335a2136db6b15df8ef592da92e7dd07e51457dcf81def", models: ["all-MiniLM-L6-v2"], tokenizer: "all-MiniLM-L6-v2"),
        "openvision-tiny-p8": Artifact(repository: "axiotic/cliphoard-coreml-models", revision: "735cf3ec9bcaff2a46dd0f41997d0ab10bf068b4", path: "coreml/openvision-tiny-p8.zip", bytes: 31_726_193, sha256: "c137d2f76e9ed583488cf5e5955f11d173192c05ccae4daa922e8ab6fdfb772a", models: ["openvision-tiny-p8-image", "openvision-tiny-p8-text"], tokenizer: "openvision-tiny-p8-text")
    ]
    static var expectedSHA256: [String: String] { catalog.mapValues(\.sha256) }
    static func source(for name: String) -> AssetSource {
        guard let repo = catalog[name]?.repository else { return .unavailable }
        return .huggingFace(repo: repo)
    }
    static func assetURL(for name: String) -> URL? { catalog[name]?.url }
    static var storeDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ditto/models", isDirectory: true)
    }
    static func archiveURL(_ name: String, root: URL = storeDir) -> URL { root.appendingPathComponent("\(name).zip") }
    /// Presence is not readiness: ensure always hashes the complete pinned archive.
    static func canPrepareLocally(_ name: String, root: URL = storeDir) -> Bool {
        guard let artifact = catalog[name] else { return false }
        let url = archiveURL(name, root: root)
        guard (try? MediaSpeechAssetManifest.safePath(url)) != nil,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return attrs[.type] as? FileAttributeType == .typeRegular && (attrs[.size] as? NSNumber)?.int64Value == artifact.bytes
    }
    static func canPrepareImageModelsLocally() -> Bool { canPrepareLocally("openvision-tiny-p8") }
    struct Located { let compiledModel: URL; let tokenizerFolder: URL }
    private struct CacheReceipt: Codable { let archiveSHA256: String; let platform: String; let models: [String: [String: String]] }
    private struct Prepared { let located: Located; let hashes: [String: String] }
    private static let lock = NSLock()
    private static var prepared: [String: Prepared] = [:]
    private static func snapshot(_ name: String) -> Prepared? { lock.lock(); defer { lock.unlock() }; return prepared[name] }
    private static func publish(_ values: [String: Prepared]) { lock.lock(); defer { lock.unlock() }; prepared.merge(values) { _, new in new } }
    /// Only this process's verified preparation can supply executable model files.
    /// Compare against the in-memory inventory, never a mutable cache receipt.
    static func locate(_ name: String) -> Located? {
        guard let item = snapshot(name), (try? inventory(item.located)) == item.hashes else { return nil }
        return item.located
    }
    static func sha256Hex(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hash = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                if Task.isCancelled { return nil }; hash.update(data: chunk)
            }
        } catch { return nil }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func verifyArchive(_ url: URL, artifact: Artifact) throws {
        try MediaSpeechAssetManifest.safePath(url); try Task.checkCancellation()
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.size] as? NSNumber)?.int64Value == artifact.bytes,
              sha256Hex(ofFileAt: url) == artifact.sha256 else { throw Failure.corrupt }
    }
    private static func inventory(_ located: Located) throws -> [String: String] {
        var result: [String: String] = [:]
        for root in [located.compiledModel, located.tokenizerFolder] {
            try MediaSpeechAssetManifest.safePath(root)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { throw Failure.corrupt }
            for case let url as URL in walker {
                try Task.checkCancellation(); try MediaSpeechAssetManifest.safePath(url)
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                if attrs[.type] as? FileAttributeType == .typeDirectory { continue }
                guard attrs[.type] as? FileAttributeType == .typeRegular, let hash = sha256Hex(ofFileAt: url) else { throw Failure.corrupt }
                result[root.lastPathComponent + "/" + String(url.path.dropFirst(root.path.count + 1))] = hash
            }
        }
        guard !result.isEmpty else { throw Failure.corrupt }; return result
    }
    static func ensure(_ name: String, allowDownload: Bool = true, root: URL = storeDir,
        progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Located {
        try Task.checkCancellation()
        // Asset preparation also serves NSFW analysis. Only the caller owns its
        // UI status; background users must never replace the search model state.
        try await prepare(name, allowDownload: allowDownload, root: root, progress: progress)
        try Task.checkCancellation()
        guard let found = locate(name) else { throw Failure.corrupt }; return found
    }
    /// Both towers become visible together after all compilation and integrity checks.
    static func ensureImageModels(allowDownload: Bool = true, root: URL = storeDir,
        progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try await prepare("openvision-tiny-p8", allowDownload: allowDownload, root: root, progress: progress)
    }
    private static let coordinator = PreparationCoordinator()
    private actor PreparationCoordinator {
        private var active = Set<String>()
        func begin(_ name: String) throws { guard active.insert(name).inserted else { throw Failure.busy } }
        func end(_ name: String) { active.remove(name) }
    }
    private static func prepare(_ name: String, allowDownload: Bool, root: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let artifact = catalog[name] else { throw Failure.unknownModel }
        try Task.checkCancellation()
        let key = root.path + "/" + name
        try await coordinator.begin(key)
        do { try await prepareExclusive(name, artifact: artifact, allowDownload: allowDownload, root: root, progress: progress) }
        catch { await coordinator.end(key); throw error }
        await coordinator.end(key)
    }
    private static func prepareExclusive(_ name: String, artifact: Artifact, allowDownload: Bool, root: URL,
        progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        let deadline = ProcessInfo.processInfo.systemUptime + 600
        try MediaSpeechAssetManifest.safePath(root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let archive = archiveURL(name, root: root)
        if fm.fileExists(atPath: archive.path) { try verifyArchive(archive, artifact: artifact) }
        else {
            guard allowDownload else { throw Failure.missing }
            guard let source = artifact.url else { throw Failure.unpublishedArtifact }
            let staging = root.appendingPathComponent(".download-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: staging) }
            progress(0)
            let transfer = SpeechAssetTransfer(destination: staging, expectedBytes: artifact.bytes, deadline: deadline,
                progress: { progress(Double($0) / Double(artifact.bytes)) })
            try await transfer.start(source)
            try verifyArchive(staging, artifact: artifact)
            try fm.moveItem(at: staging, to: archive)
        }
        try MediaSpeechAssetManifest.check(deadline)
        progress(1)
        let platform = ProcessInfo.processInfo.operatingSystemVersionString + "-" + architecture
        let platformHash = SHA256.hash(data: Data(platform.utf8)).map { String(format: "%02x", $0) }.joined()
        let cache = root.appendingPathComponent("prepared-v1-\(artifact.sha256)-\(platformHash.prefix(16))", isDirectory: true)
        if fm.fileExists(atPath: cache.path) {
            publish(try readCache(cache, artifact: artifact, platform: platform)); return
        }
        let session = root.appendingPathComponent(".prepared-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: session, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var retained = false
        defer { if !retained { try? fm.removeItem(at: session) } }
        let unpack = session.appendingPathComponent("source", isDirectory: true)
        try fm.createDirectory(at: unpack, withIntermediateDirectories: false)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, unpack.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            while process.isRunning { try MediaSpeechAssetManifest.check(deadline); try await Task.sleep(nanoseconds: 20_000_000) }
        } catch {
            if process.isRunning { process.terminate(); try? await Task.sleep(nanoseconds: 100_000_000); if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            throw error
        }
        guard process.terminationStatus == 0 else { throw Failure.unpackFailed }
        let tokenizer = unpack.appendingPathComponent(artifact.tokenizer)
        guard fm.fileExists(atPath: tokenizer.appendingPathComponent("tokenizer.json").path) else { throw Failure.corrupt }
        let savedTokenizer = session.appendingPathComponent(artifact.tokenizer + "-tokenizer")
        try fm.copyItem(at: tokenizer, to: savedTokenizer)
        var values: [String: Prepared] = [:]
        for model in artifact.models {
            try MediaSpeechAssetManifest.check(deadline)
            let compiled = try await MLModel.compileModel(at: unpack.appendingPathComponent("\(model).mlpackage"))
            defer { try? fm.removeItem(at: compiled) }
            try MediaSpeechAssetManifest.check(deadline)
            let destination = session.appendingPathComponent("\(model).mlmodelc")
            try fm.moveItem(at: compiled, to: destination)
            let located = Located(compiledModel: destination, tokenizerFolder: savedTokenizer)
            values[model] = Prepared(located: located, hashes: try inventory(located))
        }
        try Task.checkCancellation()
        try fm.removeItem(at: unpack)
        let receipt = CacheReceipt(archiveSHA256: artifact.sha256, platform: platform, models: values.mapValues(\.hashes))
        try JSONEncoder().encode(receipt).write(to: session.appendingPathComponent("receipt.json"), options: .withoutOverwriting)
        try fm.moveItem(at: session, to: cache)
        retained = true
        publish(try readCache(cache, artifact: artifact, platform: platform))
    }
    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
    /// This local compilation receipt detects cache damage; it is not a signature
    /// against a hostile same-user process able to rewrite the receipt and files.
    private static func readCache(_ root: URL, artifact: Artifact, platform: String) throws -> [String: Prepared] {
        try MediaSpeechAssetManifest.safePath(root)
        let receiptURL = root.appendingPathComponent("receipt.json")
        try MediaSpeechAssetManifest.safePath(receiptURL)
        let attrs = try FileManager.default.attributesOfItem(atPath: receiptURL.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? NSNumber, size.intValue <= 2_000_000 else { throw Failure.corrupt }
        let receipt = try JSONDecoder().decode(CacheReceipt.self, from: Data(contentsOf: receiptURL))
        guard receipt.archiveSHA256 == artifact.sha256, receipt.platform == platform,
              Set(receipt.models.keys) == Set(artifact.models),
              Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == Set(artifact.models.map { $0 + ".mlmodelc" } + [artifact.tokenizer + "-tokenizer", "receipt.json"]) else { throw Failure.corrupt }
        var result: [String: Prepared] = [:]
        for name in artifact.models {
            let located = Located(compiledModel: root.appendingPathComponent(name + ".mlmodelc"),
                tokenizerFolder: root.appendingPathComponent(artifact.tokenizer + "-tokenizer"))
            guard let hashes = receipt.models[name], try inventory(located) == hashes else { throw Failure.corrupt }
            result[name] = Prepared(located: located, hashes: hashes)
        }
        return result
    }

}

@MainActor
final class EmbedderState: ObservableObject {
    static let shared = EmbedderState()
    enum State: Equatable {
        case ready(signature: String), fallback, loading(String), notInstalled(String)
        case downloading(String, progress: Double), installing(String), failed(String, message: String)
    }
    @Published var state: State = .fallback
    private var transfer: UUID?
    func set(_ value: State) { transfer = nil; state = value }
    func beginTransfer(_ name: String) throws -> UUID { try Task.checkCancellation(); let id = UUID(); transfer = id; return id }
    func endTransfer(_ id: UUID) { if transfer == id { transfer = nil } }
    func transferProgress(_ id: UUID, name: String, progress: Double) {
        guard transfer == id else { return }; state = progress >= 1 ? .installing(name) : .downloading(name, progress: progress)
    }
}
