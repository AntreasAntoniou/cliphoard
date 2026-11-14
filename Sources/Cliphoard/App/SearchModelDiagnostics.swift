import AppKit
import CoreML
import Tokenizers
import CryptoKit

/// Explicit local qualification using public fixture bytes on stdin. Never
/// opens ClipStore, reads clipboard/history, acquires models or changes settings.
enum SearchModelDiagnostics {
    struct Input: Decodable {
        struct Picture: Decodable { let name: String; let data: Data }
        let images: [Picture]
        let queries: [String]
    }

    @MainActor static func run() {
        Task { @MainActor in
            do {
                var inputData = Data()
                while let chunk = try FileHandle.standardInput.read(upToCount: 1 << 20), !chunk.isEmpty {
                    inputData.append(chunk)
                    guard inputData.count < 32 * 1024 * 1024 else { exit(2) }
                }
                let input = try JSONDecoder().decode(Input.self, from: inputData)
                guard input.images.count <= 8, input.queries.count <= 16 else { exit(2) }
                let start = Date()
                let found = try await ModelAssets.ensure("all-MiniLM-L6-v2", allowDownload: false)
                let model = try await MLModel.load(contentsOf: found.compiledModel, configuration: MLModelConfiguration())
                let tokenizer = try await AutoTokenizer.from(modelFolder: found.tokenizerFolder)
                let mini = HFEmbedder(modelName: "all-MiniLM-L6-v2", model: model, tokenizer: tokenizer, dimension: 384)
                let vector = mini.embed("the quick brown fox")
                print("MINILM_DIAGNOSTIC seconds=\(Date().timeIntervalSince(start)) dimension=\(vector.count)")
                fflush(stdout)
                guard vector.count == 384 else { exit(3) }
                let assets = GemmaMediaAssets()
                let url = try await assets.verifiedModel()
                let engine = GemmaMediaEmbedder()
                try await engine.prepare(modelURL: url, cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent("Cliphoard-search-diagnostics"))
                var images: [(String, [Float])] = []
                for image in input.images {
                    images.append((image.name, try await engine.embedImage(image.data)))
                }
                var rows: [[String: Any]] = []
                var backgrounds: [[Float]] = []
                for text in GemmaPictureRelevance.backgroundQueries {
                    backgrounds.append(try await engine.embedQuery(text))
                }
                for query in input.queries {
                    let q = try await engine.embedQuery(query)
                    let scores = images.map { ["image": $0.0, "score": MediaSearchController.cosine(q, $0.1)] as [String: Any] }
                    let selected = images.compactMap { name, image -> [String: Any]? in
                        guard let score = GemmaPictureRelevance.score(query: q, image: image, backgrounds: backgrounds) else { return nil }
                        return ["image": name, "specificity": score]
                    }
                    rows.append(["query": query, "scores": scores, "selected": selected])
                }
                await engine.close()
                let data = try JSONSerialization.data(withJSONObject: ["seconds": Date().timeIntervalSince(start), "results": rows], options: [.sortedKeys])
                FileHandle.standardOutput.write(data); print("")
                exit(0)
            } catch {
                print("SEARCH_MODEL_DIAGNOSTIC_FAILED \(type(of: error))")
                exit(1)
            }
        }
        RunLoop.main.run()
    }
}

extension SearchModelDiagnostics {
    /// Separate processes exercise the same immutable local restore/verifiers used at launch.
    /// Does not create ClipStore, migrate settings, read clips, or grant an entitlement.
    @MainActor static func runRestoration() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 180) {
            print("{\"diagnostic\":\"local-model-restoration-v1\",\"error\":\"deadline\"}")
            fflush(stdout); exit(124)
        }
        Task { @MainActor in
            var rows: [[String: Any]] = []
            let defaults = UserDefaults.standard
            let selected = ModelRestorationPreferences.selected(defaults: defaults)
#if APP_STORE
            await StorePurchase.shared.refreshEntitlements()
            let pro = StorePurchase.shared.entitlement.isPro
#else
            let pro = Licence.current.isPro
#endif
            func eligibility(_ requirement: SearchModelRequirement) -> [String: Any] {
                let reason: String
                switch requirement {
                case .text(let level):
                    reason = defaults.string(forKey: "deferredTextModelPreparation") == level.rawValue ? "deferred" : "selected"
                default:
                    reason = !pro ? "pro_unavailable" : (ModelRestorationPreferences.authorized(requirement, defaults: defaults) ? "selected" : "deferred_or_disabled")
                }
                return ["model": requirement.id, "eligible": reason == "selected", "reason": reason]
            }
            let roots = [ModelAssets.storeDir, GemmaMediaAssets.defaultDirectory,
                FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Cliphoard/MediaSpeechModels", isDirectory: true)]
            do {
                let before = try inventory(roots)
                let image = NSImage(size: NSSize(width: 32, height: 32))
                image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 32, height: 32).fill(); image.unlockFocus()
                guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else { exit(2) }
                let wav = silentWAV()
                // Text is free. Its existing deferred setting still takes precedence.
                if let name = DeepSearch.level.modelName, DeepSearch.level != .gemma2,
                   defaults.string(forKey: "deferredTextModelPreparation") != DeepSearch.level.rawValue {
                    do {
                        let found = try ModelAssets.restoreCached(name)
                        let model = try await MLModel.load(contentsOf: found.compiledModel, configuration: MLModelConfiguration())
                        let vector: [Float]
                        if name == "all-MiniLM-L6-v2" {
                            let tokenizer = try await AutoTokenizer.from(modelFolder: found.tokenizerFolder)
                            vector = HFEmbedder(modelName: name, model: model, tokenizer: tokenizer, dimension: 384).embed("a red square")
                        } else {
                            guard let tokenizer = OgmaTokenizer(folder: found.tokenizerFolder) else { throw ModelAssets.Failure.corrupt }
                            vector = OgmaEmbedder(modelName: name, model: model, tokenizer: tokenizer, dimension: DeepSearch.level.dimension, outputName: DeepSearch.detail.outputName).embed("a red square")
                        }
                        rows.append(["model": name, "ready": !vector.isEmpty && vector.allSatisfy(\.isFinite), "dimension": vector.count])
                    } catch { rows.append(["model": name, "ready": false, "reason": "missing_or_invalid_local_cache"]) }
                }
                if pro {
                    if ModelRestorationPreferences.authorized(.pictures, defaults: defaults), ClipStore.imageUnderstandingEnabled {
                        do {
                            try ModelAssets.restoreCached("openvision-tiny-p8")
                            guard let model = CLIPEmbedder.load() else { throw ModelAssets.Failure.corrupt }
                            let a = model.embed(text: "a red square"), b = model.embed(imageData: png)
                            rows.append(["model": "openvision-tiny-p8", "ready": a.count == CLIPEmbedder.dimension && b.count == CLIPEmbedder.dimension && (a + b).allSatisfy(\.isFinite)])
                        } catch { rows.append(["model": "openvision-tiny-p8", "ready": false, "reason": "missing_or_invalid_local_cache"]) }
                    }
                    let gemmaText = DeepSearch.level == .gemma2 && defaults.string(forKey: "deferredTextModelPreparation") != DeepSearch.level.rawValue
                    if (selected.contains(.media) && ModelRestorationPreferences.authorized(.media, defaults: defaults)) || gemmaText {
                        let engine = GemmaMediaEmbedder()
                        do {
                            let url = try await GemmaMediaAssets().verifiedModel()
                            let runtime = FileManager.default.temporaryDirectory.appendingPathComponent("Cliphoard-restore-diagnostic-runtime", isDirectory: true)
                            try await engine.prepare(modelURL: url, cacheURL: runtime)
                            let a = try await engine.embedQuery("a red square")
                            let b = try await engine.embedImage(png)
                            let c = try await engine.embedAudio(wav)
                            rows.append(["model": "embeddinggemma2", "ready": [a,b,c].allSatisfy { $0.count == 768 && $0.allSatisfy(\.isFinite) }])
                        } catch { rows.append(["model": "embeddinggemma2", "ready": false, "reason": "missing_invalid_or_runtime_unavailable"]) }
                        await engine.close()
                    }
                    let speech = MediaSpeechModel(rawValue: defaults.string(forKey: "mediaSpeechModel") ?? "") ?? .turbo
                    if selected.contains(.speech(speech)), ModelRestorationPreferences.authorized(.speech(speech), defaults: defaults) {
                        let transcriber = MediaSpeechTranscriber()
                        do {
                            try await transcriber.prepare(model: speech, allowDownload: false)
                            let result = try await transcriber.transcribe(wav: wav, start: 0, end: 1, model: speech, language: "en", deadlineSeconds: 30)
                            rows.append(["model": "whisper-" + speech.rawValue, "ready": true, "syntheticSegments": result.count])
                        } catch { rows.append(["model": "whisper-" + speech.rawValue, "ready": false, "reason": "missing_invalid_or_runtime_unavailable"]) }
                        try? await transcriber.unload()
                    }
                }
                let after = try inventory(roots)
                let data = try JSONSerialization.data(withJSONObject: ["diagnostic": "local-model-restoration-v1", "pro": pro,
                    "models": rows, "selected": selected.map(\.id),
                    "eligibility": selected.map(eligibility),
                    "immutableAssetsUnchanged": before == after, "assetFileCount": before.count,
                    "inventoryBeforeSHA256": fingerprint(before), "inventoryAfterSHA256": fingerprint(after)], options: [.sortedKeys])
                FileHandle.standardOutput.write(data); print(""); fflush(stdout)
                exit(before == after ? 0 : 3)
            } catch { print("{\"diagnostic\":\"local-model-restoration-v1\",\"error\":\"asset_inventory_failed\"}"); exit(1) }
        }
        RunLoop.main.run()
    }
    /// Secret-free fingerprints retained only in memory; no local paths appear in output.
    private static func inventory(_ roots: [URL]) throws -> [String: String] {
        var result: [String: String] = [:]
        for (i, root) in roots.enumerated() {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            try MediaSpeechAssetManifest.safePath(root)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { throw ModelAssets.Failure.corrupt }
            for case let url as URL in walker {
                try MediaSpeechAssetManifest.safePath(url)
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                if attrs[.type] as? FileAttributeType == .typeDirectory { continue }
                guard attrs[.type] as? FileAttributeType == .typeRegular, let hash = ModelAssets.sha256Hex(ofFileAt: url),
                      let modified = attrs[.modificationDate] as? Date else { throw ModelAssets.Failure.corrupt }
                result["\(i)/" + String(url.path.dropFirst(root.path.count + 1))] = hash + ":" + String(modified.timeIntervalSince1970)
            }
        }
        return result
    }
    private static func fingerprint(_ value: [String: String]) -> String {
        let bytes = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private static func silentWAV() -> Data {
        var data = Data()
        func text(_ s: String) { data.append(contentsOf: s.utf8) }
        func u16(_ n: UInt16) { var n = n.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        func u32(_ n: UInt32) { var n = n.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(32036); text("WAVEfmt "); u32(16); u16(1); u16(1)
        u32(16000); u32(32000); u16(2); u16(16); text("data"); u32(32000); data.append(Data(count: 32000))
        return data
    }
}
