import AppKit
import CoreML
import Tokenizers

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
                let inputData = FileHandle.standardInput.readDataToEndOfFile()
                guard inputData.count < 32 * 1024 * 1024 else { exit(2) }
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
                for query in input.queries {
                    let q = try await engine.embedQuery(query)
                    let scores = images.map { ["image": $0.0, "score": MediaSearchController.cosine(q, $0.1)] as [String: Any] }
                    rows.append(["query": query, "scores": scores])
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
