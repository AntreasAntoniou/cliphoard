import Foundation
import WhisperKit

enum MediaSpeechModel: String, Codable, CaseIterable, Sendable, Identifiable {
    case small, largeV3, turbo
    static let defaultModel: Self = .turbo
    var id: String { rawValue }
    var downloadBytes: Int64 { MediaSpeechAssetManifest.totalBytes(for: self) }
    var label: String {
        switch self { case .small: return "Whisper Small"; case .largeV3: return "Whisper Large v3"; case .turbo: return "Whisper Large v3 Turbo" }
    }
    var variant: String {
        switch self {
        case .small: return "openai_whisper-small"
        case .largeV3: return "openai_whisper-large-v3"
        case .turbo: return "openai_whisper-large-v3-v20240930_turbo"
        }
    }
    fileprivate var tokenizerRepository: String { self == .small ? "openai/whisper-small" : "openai/whisper-large-v3" }
    fileprivate var tokenizerRevision: String {
        self == .small ? "973afd24965f72e36ca33b3055d56a652f456b4d" : "06f233fe06e710322aca913c1bc4249a0d71fce1"
    }
}

struct MediaSpeechSegment: Equatable, Sendable {
    let start: Double
    let end: Double
    let text: String
}

protocol MediaSpeechBackend: Sendable {
    func prepare(model: MediaSpeechModel, root: URL, allowDownload: Bool, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws
    func transcribe(samples: [Float], language: String?, shouldContinue: @escaping @Sendable () -> Bool) async throws -> [MediaSpeechSegment]
    func unload() async
}

/// Optional local speech; never implicitly prepares/downloads. Caller owns current Pro/privacy
/// authorization before each await and before displaying/persisting any derived text.
actor MediaSpeechTranscriber {
    enum Failure: Error, Equatable { case notPrepared, busy, invalidInput, invalidOutput, assetsUnavailable, stale }
    private let modelsRoot: URL
    private let backend: any MediaSpeechBackend
    private var prepared: MediaSpeechModel?
    private var busy = false
    private var active: Stop?
    private var generation: UInt64 = 0

    init(modelsRoot: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cliphoard/MediaSpeechModels", isDirectory: true),
         backend: any MediaSpeechBackend = LocalWhisperSpeechBackend()) {
        self.modelsRoot = modelsRoot; self.backend = backend
    }
    func readyModel() -> MediaSpeechModel? { prepared }

    /// Only an explicit allowDownload:true may contact the public model repositories.
    func prepare(model: MediaSpeechModel = .defaultModel, allowDownload: Bool = false,
                 progress: @escaping @Sendable (Int64, Int64) -> Void = { _,_ in }) async throws {
        guard !busy else { throw Failure.busy }
        busy = true; defer { busy = false }
        let ticket = generation
        try Task.checkCancellation()
        prepared = nil
        do {
            try await backend.prepare(model: model, root: modelsRoot, allowDownload: allowDownload, progress: progress)
            try Task.checkCancellation()
            guard ticket == generation else { throw Failure.stale }
            prepared = model
        } catch { await backend.unload(); throw error }
    }
    func cancel() { generation &+= 1; active?.cancel() }
    func unload() async throws {
        guard !busy else { throw Failure.busy }
        prepared = nil; generation &+= 1; await backend.unload()
    }

    /// Full speech is independent of sparse audio sampling. Longer files must be explicitly
    /// refused, never silently represented as a complete transcript with missing gaps.
    nonisolated static func fullTranscriptionPlan(duration: Double) throws -> MediaSamplingPlan {
        guard duration.isFinite, duration > 0, duration <= 3600 else { throw Failure.invalidInput }
        return try MediaSamplingPlan.make(duration: duration, preset: .detailed, modality: .audio)
    }

    func transcribe(wav: Data, start: Double, end: Double, model: MediaSpeechModel = .defaultModel,
                    language: String? = nil, deadlineSeconds: Double = 120) async throws -> [MediaSpeechSegment] {
        guard !busy else { throw Failure.busy }
        guard prepared == model else { throw Failure.notPrepared }
        guard start.isFinite, end.isFinite, start >= 0, end > start, end <= 21600,
              deadlineSeconds.isFinite, deadlineSeconds > 0, deadlineSeconds <= 180,
              language == nil || (language!.count <= 8 && language!.allSatisfy { $0.isASCII && ($0.isLetter || $0 == "-") }) else { throw Failure.invalidInput }
        let samples = try Self.samples(from: wav)
        let duration = Double(samples.count) / 16000
        guard abs((end - start) - duration) <= 1.0 / 16000 else { throw Failure.invalidInput }
        busy = true
        let stop = Stop(seconds: deadlineSeconds); active = stop
        defer { active = nil; busy = false }
        let ticket = generation
        let raw = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await backend.transcribe(samples: samples, language: language,
                                                shouldContinue: { stop.mayContinue })
        }, onCancel: { stop.cancel() })
        try Task.checkCancellation()
        guard stop.mayContinue, ticket == generation else { throw Failure.stale }
        guard raw.count <= 128 else { throw Failure.invalidOutput }
        var output: [MediaSpeechSegment] = []; var textBytes = 0
        for item in raw {
            // Whisper timestamps are on a 20ms grid. Clip a final grid overshoot only;
            // reject unrelated or unbounded timestamps rather than fabricating coverage.
            guard item.start.isFinite, item.end.isFinite, item.start >= -0.02,
                  item.end <= duration + 0.02, item.end >= item.start else { throw Failure.invalidOutput }
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            textBytes += text.utf8.count
            guard textBytes <= 32768 else { throw Failure.invalidOutput }
            let a = max(0, item.start), b = min(duration, item.end)
            guard !text.isEmpty, b > a else { continue }
            let segment = MediaSpeechSegment(start: start + a, end: min(end, start + b), text: text)
            if !output.contains(segment) { output.append(segment) }
        }
        return output.sorted { $0.start < $1.start }
    }

    /// Strict canonical decoder output: RIFF/WAVE, PCM16 little-endian, mono16k, <=30s.
    /// No AVAudioFile or plaintext temporary audio is involved.
    nonisolated static func samples(from wav: Data) throws -> [Float] {
        guard wav.count >= 46, wav.count <= 960044 else { throw Failure.invalidInput }
        let bytes = [UInt8](wav)
        func u16(_ i: Int) -> UInt16 { UInt16(bytes[i]) | UInt16(bytes[i+1]) << 8 }
        func u32(_ i: Int) -> UInt32 { UInt32(bytes[i]) | UInt32(bytes[i+1]) << 8 | UInt32(bytes[i+2]) << 16 | UInt32(bytes[i+3]) << 24 }
        func tag(_ i: Int, _ s: String) -> Bool { Array(bytes[i..<(i+4)]) == Array(s.utf8) }
        guard tag(0,"RIFF"), tag(8,"WAVE"), tag(12,"fmt "), tag(36,"data"),
              u32(4) == bytes.count - 8, u32(16) == 16, u16(20) == 1, u16(22) == 1,
              u32(24) == 16000, u32(28) == 32000, u16(32) == 2, u16(34) == 16,
              u32(40) == bytes.count - 44, (bytes.count - 44) % 2 == 0 else { throw Failure.invalidInput }
        return stride(from: 44, to: bytes.count, by: 2).map { Float(Int16(bitPattern: u16($0))) / 32768 }
    }
    private final class Stop: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        private let expiry: Double
        init(seconds: Double) { expiry = ProcessInfo.processInfo.systemUptime + seconds }
        func cancel() { lock.lock(); stopped = true; lock.unlock() }
        var mayContinue: Bool {
            lock.lock(); defer { lock.unlock() }
            return !stopped && ProcessInfo.processInfo.systemUptime < expiry
        }
    }
}

private actor LocalWhisperSpeechBackend: MediaSpeechBackend {
    private var engine: WhisperKit?
    func prepare(model: MediaSpeechModel, root: URL, allowDownload: Bool, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        await unload()
        let assetRoot = try await MediaSpeechAssetManifest.prepare(model: model, root: root, allowDownload: allowDownload, progress: progress)
        let folder = assetRoot.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(model.variant)")
        let tokenizer = assetRoot.appendingPathComponent("models/\(model.tokenizerRepository)")
        Logging.updateLogLevel(.none)
        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            guard ["\(name).mlmodelc/model.mil", "\(name).mlpackage/Manifest.json"].contains(where: {
                let p = folder.appendingPathComponent($0)
                return ((try? p.resourceValues(forKeys: [.isRegularFileKey,.fileSizeKey])).map { $0.isRegularFile == true && ($0.fileSize ?? 0) > 0 }) == true
            }) else { throw MediaSpeechTranscriber.Failure.assetsUnavailable }
        }
        try Task.checkCancellation()
        let local = try await OfflineWhisper(model: model, config: WhisperKitConfig(modelFolder: folder.path,
            tokenizerFolder: tokenizer,
            computeOptions: ModelComputeOptions(melCompute: .cpuOnly, audioEncoderCompute: .cpuOnly, textDecoderCompute: .cpuOnly),
            verbose: false, prewarm: true, load: true, download: false))
        guard local.modelState == .loaded, local.tokenizer != nil else { throw MediaSpeechTranscriber.Failure.assetsUnavailable }
        try Task.checkCancellation(); engine = local
    }
    func transcribe(samples: [Float], language: String?, shouldContinue: @escaping @Sendable () -> Bool) async throws -> [MediaSpeechSegment] {
        guard let engine else { throw MediaSpeechTranscriber.Failure.notPrepared }
        guard shouldContinue() else { throw CancellationError() }
        let options = DecodingOptions(verbose: false, language: language, temperature: 0,
            temperatureFallbackCount: 2, sampleLength: 224, detectLanguage: language == nil,
            skipSpecialTokens: true, withoutTimestamps: false, wordTimestamps: false,
            suppressBlank: true, concurrentWorkerCount: 1, chunkingStrategy: nil)
        let result = try await engine.transcribe(audioArray: samples, decodeOptions: options,
            callback: { _ in shouldContinue() ? nil : false })
        guard shouldContinue() else { throw CancellationError() }
        return result.flatMap(\.segments).filter { $0.noSpeechProb < 0.6 }.map {
            MediaSpeechSegment(start: Double($0.start), end: Double($0.end), text: $0.text)
        }
    }
    func unload() async { let old = engine; engine = nil; await old?.unloadModels() }

}

/// Upstream download:false does not disable tokenizer fallback. Override only that hook:
/// load directly from local JSON, never call its remote-capable ModelUtilities loader.
private final class OfflineWhisper: WhisperKit {
    private let expectedModel: MediaSpeechModel
    init(model: MediaSpeechModel, config: WhisperKitConfig) async throws { expectedModel = model; try await super.init(config) }
    override func loadTokenizerIfNeeded() async throws {
        guard tokenizer == nil else { return }
        guard let folder = tokenizerFolder, let logits = textDecoder.logitsSize,
              let encoder = audioEncoder.embedSize else { throw MediaSpeechTranscriber.Failure.assetsUnavailable }
        guard logits == (expectedModel == .small ? 51865 : 51866),
              encoder == (expectedModel == .small ? 768 : 1280) else { throw MediaSpeechTranscriber.Failure.assetsUnavailable }
        textDecoder.isModelMultilingual = true
        // modelVariant is private(set) upstream; its diagnostic label remains the default.
        // Actual tokenizer selection is pinned by the explicit model, not that label.
        let local = try await AutoTokenizerWrapper.from(modelFolder: folder,
            hubApi: HubApiWrapper(downloadBase: folder, hfToken: ""))
        tokenizer = try LocalSpeechTokenizer(local)
    }
}

/// Segment timestamps are used; word alignment is deliberately disabled. This adapter
/// supplies the public tokenizer protocol without upstream's internal remote wrapper.
private struct LocalSpeechTokenizer: WhisperTokenizer {
    let base: TokenizerWrapper
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>
    init(_ base: TokenizerWrapper) throws {
        self.base = base
        func token(_ text: String) throws -> Int {
            guard let id = base.convertTokenToId(text) else { throw MediaSpeechTranscriber.Failure.assetsUnavailable }; return id
        }
        specialTokens = try SpecialTokens(endToken: token("<|endoftext|>"), englishToken: token("<|en|>"),
            noSpeechToken: token("<|nospeech|>"), noTimestampsToken: token("<|notimestamps|>"),
            specialTokenBegin: token("<|endoftext|>"), startOfPreviousToken: token("<|startofprev|>"),
            startOfTranscriptToken: token("<|startoftranscript|>"), timeTokenBegin: token("<|0.00|>"),
            transcribeToken: token("<|transcribe|>"), translateToken: token("<|translate|>"),
            whitespaceToken: base.encode(text: " ", addSpecialTokens: false).first ?? 220)
        let first = try token("<|startoftranscript|>") + 1
        let last = try token("<|translate|>")
        guard first < last, last - first <= 128 else { throw MediaSpeechTranscriber.Failure.assetsUnavailable }
        allLanguageTokens = Set(first..<last)
    }
    func encode(text: String) -> [Int] { base.encode(text: text) }
    func decode(tokens: [Int]) -> String { base.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }
    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        // Not used with wordTimestamps:false; preserve all tokens if called defensively.
        return tokenIds.isEmpty ? ([], []) : ([decode(tokens: tokenIds)], [tokenIds])
    }
}
