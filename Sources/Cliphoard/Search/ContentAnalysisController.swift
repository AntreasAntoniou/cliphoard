import AppKit
import AppIntents
import Combine
import UniformTypeIdentifiers
import CoreML
import Tokenizers

protocol ContentModelEvaluating: Actor {
    func text(_ text: String) async throws -> Bool
    func image(_ data: Data) async throws -> Bool
    func media(_ url: URL, video: Bool, audio: Bool, cache: URL,
               admit: @escaping @Sendable () async -> Bool) async throws -> Bool
    func reset() async
}

/// A serial, local-only queue for optional document extraction and NSFW screening.
/// Rechecks live membership, preferences, Focus and entitlement after every await.
@MainActor
final class ContentAnalysisController: ObservableObject {
    @Published private(set) var status = "NSFW checks use explicit labels and downloaded local models."
    @Published private(set) var busy = false
    @Published private(set) var modelStatus = "No model download is automatic."
    private weak var store: ClipStore?
    private var operation: Task<Void, Never>?
    private var focusTask: Task<Void, Never>?
    private var observer: AnyCancellable?
    private var settingsObserver: AnyCancellable?
    private var processed: [UUID: String] = [:]
    private var generation = UUID()
    private let evaluator: any ContentModelEvaluating
    private var documentConfiguration = [ContentAnalysisPreferences.documentText, ContentAnalysisPreferences.enabled("documentPDFEnabled"), ContentAnalysisPreferences.enabled("documentRichTextEnabled")]

    init(store: ClipStore, evaluator: any ContentModelEvaluating = NSFWModelEvaluator(), monitorFocus: Bool = true) {
        self.store = store
        self.evaluator = evaluator
        observer = store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.schedule() }
        }
        settingsObserver = NotificationCenter.default.publisher(for: ContentAnalysisPreferences.changed).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        guard monitorFocus else { return }
        focusTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                let value: Bool?
                do { value = try await NSFWFocusFilter.current.protectNSFW }
                catch SetFocusFilterIntentError.notFound { value = false }
                catch { value = nil }
                if value != FocusProtectionState.active {
                    FocusProtectionState.set(value)
                    self?.refresh()
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
    deinit { operation?.cancel(); focusTask?.cancel() }

    func refresh() {
        generation = UUID(); operation?.cancel(); processed.removeAll()
        SensitiveClipReveal.shared.lock()
        let documentConfiguration = [ContentAnalysisPreferences.documentText, ContentAnalysisPreferences.enabled("documentPDFEnabled"), ContentAnalysisPreferences.enabled("documentRichTextEnabled")]
        if documentConfiguration != self.documentConfiguration {
            self.documentConfiguration = documentConfiguration
            store?.invalidateDocumentTextIndex()
        }
        store?.rebuildTagIndex()
        store?.objectWillChange.send()
        // The cancelled task owns operation until its defer; it restarts the queue.
        if operation == nil { schedule() }
    }
    func prepareImages() {
        modelStatus = "Preparing existing text and image models for Free NSFW checks…"
        Task {
            do {
                _ = try await ModelAssets.ensure("all-MiniLM-L6-v2", allowDownload: true)
                try await ModelAssets.ensureImageModels(allowDownload: true)
                modelStatus = "MiniLM and OpenVision ready. Local heuristics; matches can be wrong."
                await evaluator.reset()
                refresh()
            } catch { modelStatus = "Could not prepare all models. Explicit text/path labels still work." }
        }
    }
    func schedule() {
        guard operation == nil, let store, !store.safeMode, store.storageComplete else { return }
        guard ContentAnalysisPreferences.documentText || ContentAnalysisPreferences.nsfwActive else {
            status = ContentAnalysisPreferences.nsfwEnabled ? "NSFW protection is waiting for a configured Focus." : "NSFW protection is off."
            return
        }
        let ticket = generation
        guard store.items.contains(where: { processed[$0.id] != fingerprint($0, store: store) }) else { return }
        busy = true
        operation = Task { [weak self] in
            guard let self else { return }
            defer {
                self.busy = false; self.operation = nil
                if self.generation != ticket { self.schedule() }
            }
            while !Task.isCancelled, ticket == self.generation,
                  let store = self.store, !store.safeMode, store.storageComplete,
                  let item = store.items.first(where: { self.processed[$0.id] != self.fingerprint($0, store: store) }) {
                self.processed[item.id] = self.fingerprint(item, store: store)
                let before = SensitiveClipPolicy.fingerprint(item)
                guard !item.isIndexVetoed, !SensitiveClipPolicy.requiresCoreAuthentication(item) else { continue }
                let path = item.filePath
                if item.kind == .file, ContentAnalysisPreferences.fileTextAllowed(item), let path {
                    let url = URL(fileURLWithPath: path)
                    if DocumentTextExtractor.supports(url) {
                        self.status = "Reading file text locally…"
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let pdf = ContentAnalysisPreferences.enabled("documentPDFEnabled")
                        let rich = ContentAnalysisPreferences.enabled("documentRichTextEnabled")
                        do {
                            let result = try await Task.detached(priority: .utility) {
                                try DocumentTextExtractor.extract(url, pdf: pdf, richText: rich)
                            }.value
                            guard self.admits(item, fingerprint: before, ticket: ticket),
                                  ContentAnalysisPreferences.documentText,
                                  (try? DocumentTextExtractor.stamp(url)) == result.stamp else { continue }
                            store.applyDocumentText(result.text, to: item)
                            self.status = result.truncated ? "File text extracted with the size/page limit applied." : "File text extracted locally."
                        } catch { self.status = "A file could not be read, is unsupported, or exceeds the 16 MB limit. Original retained." }
                    }
                }
                let scannedFingerprint = SensitiveClipPolicy.fingerprint(item)
                guard self.admits(item, fingerprint: scannedFingerprint, ticket: ticket), ContentAnalysisPreferences.nsfwActive else { continue }
                // Other protected content never reaches a semantic model.
                guard !NSFWDetection.exempt(item), !SensitiveClipPolicy.requiresCoreAuthentication(item) else { continue }
                if NSFWDetection.labelled(item) {
                    store.setNSFW(true, on: item)
                } else {
                    do {
                        var match = false
                        let text = String(([item.text, item.filePath ?? "", item.ocrText ?? ""] + item.userTags).joined(separator: "\n").prefix(4096))
                        let textMatch = try? await evaluator.text(text)
                        match = textMatch ?? false
                        guard self.admits(item, fingerprint: scannedFingerprint, ticket: ticket), ContentAnalysisPreferences.nsfwActive else { continue }
                        if !match, item.kind == .image, ContentAnalysisPreferences.enabled("nsfwImagesEnabled"), let data = store.decryptedPayload(item) {
                            match = try await evaluator.image(data)
                        }
                        if !match, item.kind == .file, let path {
                            let url = URL(fileURLWithPath: path)
                            let type = UTType(filenameExtension: url.pathExtension)
                            let access = url.startAccessingSecurityScopedResource()
                            defer { if access { url.stopAccessingSecurityScopedResource() } }
                            if type?.conforms(to: .image) == true, ContentAnalysisPreferences.enabled("nsfwImagesEnabled") {
                                let stamp = try DocumentTextExtractor.stamp(url)
                                let data = try MediaSearchController.boundedFile(url, maximumBytes: GemmaMediaEmbedder.maximumImageBytes)
                                match = try await evaluator.image(data)
                                guard (try? DocumentTextExtractor.stamp(url)) == stamp else { continue }
                            } else if (type?.conforms(to: .movie) == true || type?.conforms(to: .audio) == true), NSFWDetection.permitsMedia(isVideoOrAudio: true, isPro: store.entitlement.isPro, active: ContentAnalysisPreferences.nsfwActive) {
                                let video = ContentAnalysisPreferences.enabled("nsfwVideoEnabled")
                                let audio = ContentAnalysisPreferences.enabled("nsfwAudioEnabled")
                                if video || audio {
                                    let stamp = try DocumentTextExtractor.stamp(url, maximumBytes: Int(MediaAssetDecoder.Limits().maximumFileBytes))
                                    match = try await evaluator.media(url, video: video, audio: audio,
                                        cache: store.storeDirectory.appendingPathComponent("NSFW-model-cache"), admit: { [weak self, weak item] in
                                            await MainActor.run {
                                                guard let self, let item, let store = self.store else { return false }
                                                return self.admits(item, fingerprint: scannedFingerprint, ticket: ticket)
                                                    && store.entitlement.isPro && ContentAnalysisPreferences.nsfwActive
                                            }
                                        })
                                    guard (try? DocumentTextExtractor.stamp(url, maximumBytes: Int(MediaAssetDecoder.Limits().maximumFileBytes))) == stamp else { continue }
                                }
                            }
                        }
                        guard self.admits(item, fingerprint: scannedFingerprint, ticket: ticket), ContentAnalysisPreferences.nsfwActive else { continue }
                        if match { store.setNSFW(true, on: item) }
                        self.status = textMatch == nil ? "Text model unavailable; explicit labels were checked. Other enabled media checks ran when available." : "Local checks finished. Text and media are sampled; no match is not a safety guarantee."
                    } catch NSFWModelEvaluator.Failure.unavailable {
                        self.status = "A required local model is not ready. Explicit NSFW labels and paths are still checked."
                    } catch { self.status = "Some content could not be screened. No safety verdict was recorded." }
                }
                self.processed[item.id] = self.fingerprint(item, store: store)
                await Task.yield()
            }
        }
    }
    private func fingerprint(_ item: ClipItem, store: ClipStore) -> String {
        SensitiveClipPolicy.fingerprint(item) + (store.entitlement.isPro ? "pro" : "free")
    }
    private func admits(_ item: ClipItem, fingerprint: String, ticket: UUID) -> Bool {
        guard !Task.isCancelled, ticket == generation, let store, !store.safeMode, store.storageComplete,
              store.items.contains(where: { $0 === item }), !item.isIndexVetoed else { return false }
        return SensitiveClipPolicy.fingerprint(item) == fingerprint
    }
}

/// Model work is serialized away from the main actor. Nothing downloads here.
actor NSFWModelEvaluator: ContentModelEvaluating {
    enum Failure: Error { case unavailable, stale }
    private let imageRoot: URL
    private let mediaDirectory: URL
    init(imageRoot: URL = ModelAssets.storeDir, mediaDirectory: URL = GemmaMediaAssets.defaultDirectory) {
        self.imageRoot = imageRoot; self.mediaDirectory = mediaDirectory
    }
    private var textModel: HFEmbedder?
    private var textPrompts: (positive: [[Float]], negative: [[Float]])?
    private var clip: CLIPEmbedder?
    private var prompts: (positive: [[Float]], negative: [[Float]])?
    private let gemma = GemmaMediaEmbedder()
    private var mediaPrompts: (positive: [[Float]], negative: [[Float]])?
    func reset() async { clip = nil; prompts = nil; textModel = nil; textPrompts = nil; mediaPrompts = nil; await gemma.close() }
    private func prepare() async throws -> CLIPEmbedder {
        if let clip { return clip }
        guard ModelAssets.canPrepareLocally("openvision-tiny-p8", root: imageRoot) else { throw Failure.unavailable }
        _ = try await ModelAssets.ensureImageModels(allowDownload: false, root: imageRoot)
        guard let model = CLIPEmbedder.load() else { throw Failure.unavailable }
        clip = model
        prompts = (NSFWDetection.positivePrompts.map { CLIPEmbedder.centred(model.embed(text: $0), by: CLIPTextMean.vector) },
                   NSFWDetection.negativePrompts.map { CLIPEmbedder.centred(model.embed(text: $0), by: CLIPTextMean.vector) })
        return model
    }
    func text(_ text: String) async throws -> Bool {
        // Use the existing sentence model for language. OpenVision's text tower is
        // aligned to images; calibration found unrelated text false positives there.
        if textModel == nil {
            guard ModelAssets.canPrepareLocally("all-MiniLM-L6-v2", root: imageRoot) else { throw Failure.unavailable }
            let found = try await ModelAssets.ensure("all-MiniLM-L6-v2", allowDownload: false, root: imageRoot)
            let model = try await MLModel.load(contentsOf: found.compiledModel, configuration: MLModelConfiguration())
            let tokenizer = try await AutoTokenizer.from(modelFolder: found.tokenizerFolder)
            let encoder = HFEmbedder(modelName: "all-MiniLM-L6-v2", model: model, tokenizer: tokenizer, dimension: 384)
            textModel = encoder
            textPrompts = (NSFWDetection.positivePrompts.map { encoder.embed($0) },
                           NSFWDetection.negativePrompts.map { encoder.embed($0) })
        }
        guard let model = textModel, let prompts = textPrompts else { throw Failure.unavailable }
        let chars = Array(text.prefix(4096))
        for offset in stride(from: 0, to: chars.count, by: 160) {
            try Task.checkCancellation()
            let vector = model.embed(String(chars[offset..<min(offset + 200, chars.count)]))
            guard vector.count == 384, vector.allSatisfy(\.isFinite), vector.contains(where: { $0 != 0 }) else { throw Failure.unavailable }
            if NSFWDetection.possibleMatch(vector: vector, positive: prompts.positive, negative: prompts.negative) { return true }
        }
        return false
    }
    func image(_ data: Data) async throws -> Bool {
        let model = try await prepare()
        guard let prompts else { throw Failure.unavailable }
        let vector = model.embed(imageData: data)
        guard vector.count == CLIPEmbedder.dimension, vector.allSatisfy(\.isFinite), vector.contains(where: { $0 != 0 }) else { throw Failure.unavailable }
        return NSFWDetection.possibleMatch(vector: vector, positive: prompts.positive, negative: prompts.negative)
    }
    func media(_ url: URL, video: Bool, audio: Bool, cache: URL,
               admit: @escaping @Sendable () async -> Bool) async throws -> Bool {
        guard await admit() else { throw Failure.stale }
        guard GemmaMediaAssets.localCandidateExists(directory: mediaDirectory) else { throw Failure.unavailable }
        let model = try await GemmaMediaAssets(directory: mediaDirectory).verifiedModel()
        try await gemma.prepare(modelURL: model, cacheURL: cache)
        if mediaPrompts == nil {
            var positive: [[Float]] = [], negative: [[Float]] = []
            for prompt in NSFWDetection.positivePrompts { positive.append(try await gemma.embedQuery(prompt)) }
            for prompt in NSFWDetection.negativePrompts { negative.append(try await gemma.embedQuery(prompt)) }
            mediaPrompts = (positive, negative)
        }
        guard let prompts = mediaPrompts, await admit() else { throw Failure.stale }
        let decoder = try await MediaAssetDecoder(url: url)
        defer { decoder.cancel() }
        var found = false
        if video && decoder.metadata.hasVideo {
            let plan = try MediaSamplingPlan.make(duration: decoder.metadata.duration, preset: .lightweight, modality: .video)
            try await decoder.frames(plan: plan) { frame in
                guard await admit() else { throw Failure.stale }
                guard !found else { return }
                let vector = try await gemma.embedImage(frame.jpeg)
                found = NSFWDetection.possibleMatch(vector: vector, positive: prompts.positive, negative: prompts.negative)
            }
        }
        if audio && decoder.metadata.hasAudio && !found {
            let plan = try MediaSamplingPlan.make(duration: decoder.metadata.duration, preset: .lightweight, modality: .audio)
            try await decoder.audio(plan: plan) { window in
                guard await admit() else { throw Failure.stale }
                guard !found else { return }
                let vector = try await gemma.embedAudio(window.wav)
                found = NSFWDetection.possibleMatch(vector: vector, positive: prompts.positive, negative: prompts.negative)
            }
        }
        guard await admit() else { throw Failure.stale }
        return found
    }
}
