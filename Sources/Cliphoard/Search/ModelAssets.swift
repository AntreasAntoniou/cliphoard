import Foundation
import CoreML
import CryptoKit

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

    /// Where each tier's artifact is hosted.
    ///
    /// The two ogma models are OURS, published at `axiotic/open-ogma-*`, and they are served from
    /// HuggingFace so that their download statistics reflect actual Cliphoard usage. Serving
    /// them from a GitHub release instead would make real adoption of an open model we
    /// released invisible on the platform people look at to judge whether a model is used.
    ///
    /// MiniLM stays on the GitHub release: the CoreML conversion is ours, but
    /// `sentence-transformers/all-MiniLM-L6-v2` is not our repository to publish into, and
    /// attributing our conversion's downloads to their model would misreport THEIR numbers
    /// to fix ours.
    enum AssetSource {
        case huggingFace(repo: String)
        case githubRelease
    }

    /// The MIT repos, and this mapping is load-bearing rather than cosmetic.
    ///
    /// These tiers used to be fetched from `axiotic/ogma-micro` / `axiotic/ogma-small`, which
    /// DECLARE **CC-BY-NC-4.0**. Every document said MIT.
    ///
    /// Be precise about what was wrong, because the first version of this comment was not:
    /// the ARTIFACT in those repos was already the permissive model — its `config.json` says
    /// `"model_type": "ogma-libre"` and its weights are byte-identical to a fresh conversion
    /// of the MIT checkpoint. So the app was never shipping NonCommercial *weights*. It was
    /// fetching permissive weights from a repo whose declared licence said NonCommercial,
    /// which is a redistribution and provenance problem, not a model problem. Smaller than it
    /// first looked, and still not something an MIT app should do: what a downloader is
    /// entitled to rely on is the licence the source repo declares.
    ///
    /// The fix was to publish the same build to the repos that declare MIT and point here.
    /// Nothing about search quality changed, and nothing could have — same weights.
    ///
    /// If you ever repoint these, check the target repo's declared licence FIRST.
    static let sources: [String: AssetSource] = [
        "open-ogma-micro": .huggingFace(repo: "axiotic/open-ogma-micro"),
        "open-ogma-small": .huggingFace(repo: "axiotic/open-ogma-small"),
    ]

    static func source(for name: String) -> AssetSource { sources[name] ?? .githubRelease }

    static func assetURL(for name: String) -> URL {
        switch source(for: name) {
        case .huggingFace(let repo):
            return URL(string: "https://huggingface.co/\(repo)/resolve/main/coreml/\(name).zip")!
        case .githubRelease:
            return releaseBase.appendingPathComponent("\(name).zip")
        }
    }

    /// Ask HuggingFace for the model's `config.json` immediately before fetching the weights.
    ///
    /// THIS IS NOT DEAD CODE AND MUST NOT BE TIDIED AWAY. HuggingFace does not count
    /// downloads by counting file requests — it counts requests to a specific "query file",
    /// which for a repository with no declared library is `config.json`. A request for our
    /// `coreml/<name>.zip` registers as ZERO downloads, so without this call an install that
    /// genuinely pulls the model would leave no trace on the model's page, and the published
    /// number would understate real usage indefinitely.
    ///
    /// One request per actual install, made only on the path that is already downloading the
    /// model anyway. It carries no user data — it is a plain GET for a public file — and it
    /// is deliberately best-effort: a failure here must never block an install, because the
    /// statistic is our concern and the model is the user's.
    private static func recordDownload(repo: String) async {
        var request = URLRequest(url: URL(string:
            "https://huggingface.co/\(repo)/resolve/main/config.json")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Pinned SHA-256 of each hosted `<name>.zip` on the `models-v1` release.
    /// GitHub-over-TLS authenticates the transport; this rejects a corrupted or
    /// tampered zip before it is unpacked and compiled on-device (defense-in-depth).
    /// Values are GitHub's server-computed asset digests. A tier not listed here
    /// skips the check (logged) rather than failing — add its digest when you add
    /// a new model to the release.
    static let expectedSHA256: [String: String] = [
        // No embeddinggemma-300m entry: that tier was retired on licensing grounds,
        // and its asset must also be removed from the models-v1 release — hosting it
        // is the redistribution, so dropping it from the app alone would not help.
        "all-MiniLM-L6-v2":    "ff202030f35c740193335a2136db6b15df8ef592da92e7dd07e51457dcf81def",
        // The MIT-repo CoreML builds, recomputed from the published files after upload.
        // Same weights as the artifacts they replace — only the toolchain metadata and one
        // config field differ — so these digests change while behaviour does not.
        // These MUST move together with `sources` above: a digest that still describes the
        // old NonCommercial artifact fails closed, so every install would refuse the model.
        "open-ogma-micro":     "9163037e51596ab6b17c4bc51d7e2b4b4533ca6f205b7988504774e78925ac39",
        "open-ogma-small":     "179517c6925914ec37a734c4f0aa2971b9b93ecee9e8d6e98aa4f66a17709135",
    ]

    /// Streaming SHA-256 of a file (1 MiB chunks) so a ~300 MB model zip is never
    /// loaded into memory whole. Lowercase hex, matching GitHub's digest format.
    static func sha256Hex(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while case let chunk = handle.readData(ofLength: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

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
        if case .huggingFace(let repo) = source(for: name) { await recordDownload(repo: repo) }
        let url = assetURL(for: name)
        await EmbedderState.shared.set(.downloading(name, progress: 0))
        let (tmp, response) = try await download(url: url) { progress in
            Task { @MainActor in EmbedderState.shared.state = .downloading(name, progress: progress) }
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "model download failed (\(url.lastPathComponent))"])
        }

        // 1b. Verify the download against the pinned SHA-256 before unpacking or
        // compiling it. Rejects a corrupted or tampered zip at rest; unknown tiers
        // (not yet pinned) are logged and allowed through.
        if let want = expectedSHA256[name] {
            guard let got = sha256Hex(ofFileAt: tmp), got == want else {
                try? fm.removeItem(at: tmp)
                throw CocoaError(.fileReadCorruptFile, userInfo: [
                    NSLocalizedDescriptionKey: "model checksum mismatch (\(name)) — refusing to install"])
            }
        } else {
            // FAIL CLOSED. This used to log and install anyway, which meant an unpinned tier
            // silently accepted whatever bytes the network returned — the integrity guarantee
            // the pin exists to provide, quietly voided by the branch that handles its own
            // absence. Every name that can reach here is pinned today
            // (`DeepSearchLevel.allCases`, checked by `OgmaLicenceSourceTests.testEveryReachableTierIsPinned` in AssetSourceTests.swift), so this is
            // behaviour-preserving; it stays that way because adding a tier without a pin now
            // fails loudly instead of downgrading everyone who installs it.
            try? fm.removeItem(at: tmp)
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "no pinned checksum for \(name) — refusing to install"])
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
