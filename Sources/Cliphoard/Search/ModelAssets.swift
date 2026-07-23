import Foundation
import CoreML

/// Locates — and when necessary AUTO-INSTALLS — the on-device embedding models.
///
/// Resolution order for a model `name`:
///  1. The app bundle (`<name>.mlmodelc` + `<name>-tokenizer/`) — present when
///     the build bundled that tier.
///  2. The local model store (`~/Library/Application Support/Ditto/models/`) —
///     populated by a previous auto-download.
///  3. Auto-download: fetch `<name>.zip` (the `.mlpackage` + tokenizer folder)
///     from the GitHub model release, unpack, compile on-device with
///     `MLModel.compileModel`, and cache. The user never installs anything by
///     hand — selecting a tier is the install action.
///
/// Progress/state is published through `EmbedderState` so Settings can show
/// "Downloading… 42%" instead of a misleading "not installed".
enum ModelAssets {
    /// Release that hosts the downloadable model zips.
    static let releaseBase = URL(string:
        "https://github.com/AntreasAntoniou/cliphoard/releases/download/models-v1/")!

    struct Located {
        let compiledModel: URL      // .mlmodelc, ready for MLModel(contentsOf:)
        let tokenizerFolder: URL
    }

    static var storeDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ditto/models", isDirectory: true)
    }

    /// Bundle → local store. `nil` means "needs download".
    static func locate(_ name: String) -> Located? {
        if let m = Bundle.main.url(forResource: name, withExtension: "mlmodelc"),
           let t = Bundle.main.url(forResource: "\(name)-tokenizer", withExtension: nil) {
            return Located(compiledModel: m, tokenizerFolder: t)
        }
        let m = storeDir.appendingPathComponent("\(name).mlmodelc")
        let t = storeDir.appendingPathComponent("\(name)-tokenizer")
        if FileManager.default.fileExists(atPath: m.path),
           FileManager.default.fileExists(atPath: t.appendingPathComponent("tokenizer.json").path) {
            return Located(compiledModel: m, tokenizerFolder: t)
        }
        return nil
    }

    /// Locate, downloading + compiling first if the model isn't present.
    /// Reports progress through `EmbedderState.shared`.
    static func ensure(_ name: String) async throws -> Located {
        if let found = locate(name) { return found }
        let fm = FileManager.default
        try fm.createDirectory(at: storeDir, withIntermediateDirectories: true)

        // 1. Download the zip (mlpackage + tokenizer folder).
        let url = releaseBase.appendingPathComponent("\(name).zip")
        await EmbedderState.shared.set(.downloading(name, progress: 0))
        let (tmp, response) = try await download(url: url) { progress in
            Task { @MainActor in EmbedderState.shared.state = .downloading(name, progress: progress) }
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "model download failed (\(url.lastPathComponent))"])
        }

        // 2. Unpack next to the store (ditto preserves the package structure).
        await EmbedderState.shared.set(.installing(name))
        let unpack = storeDir.appendingPathComponent("unpack-\(name)", isDirectory: true)
        try? fm.removeItem(at: unpack)
        try fm.createDirectory(at: unpack, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: unpack) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", tmp.path, unpack.path]
        try p.run(); p.waitUntilExit()
        try? fm.removeItem(at: tmp)
        guard p.terminationStatus == 0 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "model unpack failed (\(name))"])
        }

        // 3. Compile the mlpackage on-device (OS-version-proof), install both
        //    artifacts into the store atomically-ish, clean the intermediates.
        let pkg = unpack.appendingPathComponent("\(name).mlpackage")
        let tokSrc = unpack.appendingPathComponent(name)
        guard fm.fileExists(atPath: pkg.path),
              fm.fileExists(atPath: tokSrc.appendingPathComponent("tokenizer.json").path) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "model zip missing expected contents (\(name))"])
        }
        let compiled = try await MLModel.compileModel(at: pkg)
        let mDst = storeDir.appendingPathComponent("\(name).mlmodelc")
        let tDst = storeDir.appendingPathComponent("\(name)-tokenizer")
        try? fm.removeItem(at: mDst); try? fm.removeItem(at: tDst)
        try fm.moveItem(at: compiled, to: mDst)
        try fm.copyItem(at: tokSrc, to: tDst)
        return Located(compiledModel: mDst, tokenizerFolder: tDst)
    }

    /// Download with byte-level progress (URLSession.download has no callback
    /// without a delegate; stream to disk in chunks instead).
    private static func download(url: URL,
                                 progress: @escaping (Double) -> Void) async throws -> (URL, URLResponse) {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        let total = response.expectedContentLength
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliphoard-\(UUID().uuidString).zip")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)
        defer { try? handle.close() }
        var buffer = Data(); buffer.reserveCapacity(1 << 20)
        var written: Int64 = 0
        var lastReport = 0.0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= (1 << 20) {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
                if total > 0 {
                    let f = Double(written) / Double(total)
                    if f - lastReport >= 0.01 { lastReport = f; progress(f) }
                }
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        return (tmp, response)
    }
}

/// Observable embedder lifecycle, driven by `EmbedderProvider` and rendered by
/// Settings — so "loading" and "downloading 42%" are never conflated with
/// "not installed".
@MainActor
final class EmbedderState: ObservableObject {
    static let shared = EmbedderState()

    enum State: Equatable {
        case ready(signature: String)
        case fallback                       // hashing — no model for this tier
        case loading(String)                // model found, loading into CoreML
        case downloading(String, progress: Double)
        case installing(String)             // unpack + on-device compile
        case failed(String, message: String)
    }

    @Published var state: State = .fallback

    func set(_ s: State) { state = s }
}
