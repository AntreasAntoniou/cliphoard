import Foundation
import ImageIO
import LiteRTLM

/// CPU-only local multimodal embeddings. Calls are serialized; cancellation discards results
/// but cannot preempt an already executing synchronous native inference call.
actor GemmaMediaEmbedder {
    enum Failure: Error { case notPrepared, busy, invalidInput, invalidEmbedding, runtimeUnavailable, stale }
    static let dimension = 768
    static let maximumTextBytes = 1_024
    static let maximumImageBytes = 8 * 1_024 * 1_024
    static let maximumAudioFrames = 30 * 16_000
    nonisolated let signature = GemmaMediaAssets.signature
    private var engine: EmbeddingEngine?
    private var busy = false
    private var generation: UInt64 = 0

    /// Caller must explicitly prepare/download assets first. This method never accesses the network.
    func prepare(modelURL: URL, cacheURL: URL) async throws {
        guard !busy else { throw Failure.busy }
        guard engine == nil else { return }
        busy = true; defer { busy = false }
        let ticket = generation
        try Task.checkCancellation()
        try GemmaMediaAssets.verify(modelURL)
        try GemmaMediaAssets.validatePath(cacheURL)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let runtime = EmbeddingEngine(config: EmbeddingEngineConfig(
            modelPath: modelURL.path, backend: .cpu(threadCount: 2),
            visionBackend: .cpu(threadCount: 2), audioBackend: .cpu(threadCount: 2),
            cacheDir: cacheURL.path, maxInputLength: 2_048, visionTokensPerImage: 70))
        do {
            try await runtime.initialize()
            try Task.checkCancellation()
            guard generation == ticket else { throw Failure.stale }
            engine = runtime
        } catch {
            await runtime.close()
            if error is CancellationError { throw CancellationError() }
            throw Failure.runtimeUnavailable
        }
    }

    func close() async {
        generation &+= 1
        let previous = engine; engine = nil
        await previous?.close()
    }

    func embedQuery(_ text: String) async throws -> [Float] {
        try Self.validateText(text)
        return try await compute([.text("task: search result | query: " + text)])
    }

    func embedDocument(_ text: String) async throws -> [Float] {
        try Self.validateText(text)
        return try await compute([.text("title: none | text: " + text)])
    }

    /// Encoded PNG/JPEG frame, already bounded by the media decoder. Never accepts file paths.
    func embedImage(_ data: Data) async throws -> [Float] {
        try Self.validateImage(data)
        return try await compute([.text("title: none | text: "), .imageData(data)])
    }

    /// One PCM16 mono16kHz WAV window, maximum30seconds. Video audio uses the same contract.
    func embedAudio(_ wav: Data) async throws -> [Float] {
        try Self.validateAudio(wav)
        return try await compute([.text("title: none | text: "), .audioData(wav)])
    }

    private func compute(_ contents: [Content]) async throws -> [Float] {
        guard let engine else { throw Failure.notPrepared }
        guard !busy else { throw Failure.busy }
        busy = true; defer { busy = false }
        let ticket = generation
        try Task.checkCancellation()
        let response: EmbeddingResponse
        do {
            response = try await engine.computeEmbedding(contents: contents,
                options: EmbeddingOptions(normalize: true, insertSpecialTokens: true,
                                          outputSize: Self.dimension, visionTokensPerImage: 70))
        } catch { throw Failure.runtimeUnavailable }
        try Task.checkCancellation()
        guard ticket == generation else { throw Failure.stale }
        return try Self.normalized(response.embedding)
    }

    static func normalized(_ values: [Float]) throws -> [Float] {
        guard values.count == dimension, values.allSatisfy(\.isFinite) else { throw Failure.invalidEmbedding }
        let norm = sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 1e-12 else { throw Failure.invalidEmbedding }
        return values.map { Float(Double($0) / norm) }
    }

    static func validateText(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= maximumTextBytes, !text.utf8.contains(0) else { throw Failure.invalidInput }
    }

    static func validateImage(_ data: Data) throws {
        guard !data.isEmpty, data.count <= maximumImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?, ["public.png", "public.jpeg"].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4_096, height <= 4_096 else { throw Failure.invalidInput }
    }

    static func validateAudio(_ data: Data) throws {
        // Require standard bounded RIFF/WAVE PCM. Extra chunks are skipped, never interpreted as paths.
        guard data.count >= 44, data.count <= maximumAudioFrames * 2 + 65_536 else { throw Failure.invalidInput }
        let bytes = [UInt8](data)
        func u16(_ n: Int) -> Int { Int(bytes[n]) | Int(bytes[n + 1]) << 8 }
        func u32(_ n: Int) -> Int { u16(n) | u16(n + 2) << 16 }
        func name(_ n: Int) -> String { String(bytes: bytes[n ..< n + 4], encoding: .ascii) ?? "" }
        guard name(0) == "RIFF", name(8) == "WAVE", u32(4) == bytes.count - 8 else { throw Failure.invalidInput }
        var offset = 12, validFormat = false, frames: Int?
        while offset + 8 <= bytes.count {
            let length = u32(offset + 4)
            let start = offset + 8
            guard length <= bytes.count - start else { throw Failure.invalidInput }
            switch name(offset) {
            case "fmt ":
                guard !validFormat, length >= 16, u16(start) == 1, u16(start + 2) == 1,
                      u32(start + 4) == 16_000, u32(start + 8) == 32_000,
                      u16(start + 12) == 2, u16(start + 14) == 16 else { throw Failure.invalidInput }
                validFormat = true
            case "data":
                guard frames == nil, length > 0, length % 2 == 0, length / 2 <= maximumAudioFrames else {
                    throw Failure.invalidInput
                }
                frames = length / 2
            default: break
            }
            offset = start + length + (length % 2)
        }
        guard validFormat, frames != nil, offset == bytes.count else { throw Failure.invalidInput }
    }
}
