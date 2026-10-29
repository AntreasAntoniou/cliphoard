import AppKit
import Combine
import CryptoKit
import UniformTypeIdentifiers

enum MediaSpeechCoverage: String, CaseIterable, Codable {
    case off, sampled, full
    var title: String {
        switch self { case .off: return "Sounds only"; case .sampled: return "Speech in sampled moments"; case .full: return "Every spoken passage" }
    }
}

/// One owner for the model, indexing queue, encrypted derived data and current search.
/// Every asynchronous result is admitted again against the live clip and entitlement.
@MainActor
final class MediaSearchController: ObservableObject {
    struct SpeechPassage: Codable {
        var start: Double
        var end: Double
        var text: String
        var vector: [Float]
    }
    struct Entry: Codable {
        var clipID: UUID
        var fingerprint: String
        var bookmark: Data
        var path: String
        var modified: Date
        var size: Int
        var stillImage: Bool
        var preset: String
        var speech: String
        var speechModel: String
        var record: MediaSearchCache.Record
        var passages: [SpeechPassage]
    }
    struct Match: Identifiable {
        var id: UUID { clipID }
        var clipID: UUID
        var start: Double
        var end: Double
        var score: Float
        var source: String
        var passage: String?
    }
    enum Failure: Error { case unavailable, changed, tooManyFiles, invalidFile, speechTooLong, unsafeCache }

    @Published private(set) var status = "Prepare the local model to search pictures, video and audio."
    @Published private(set) var busy = false
    @Published private(set) var preparationTitle: String?
    @Published private(set) var preparationProgress: Double?
    @Published private(set) var preparedSpeechModel: MediaSpeechModel?
    @Published private(set) var prepared = false
    @Published private(set) var matches: [Match] = []
    @Published private(set) var indexedCount = 0
    @Published private(set) var accessRevision = 0
    @Published var preset: MediaSamplingPreset {
        didSet { defaults.set(preset.rawValue, forKey: "mediaSamplingPreset"); cancel(); invalidateSearch() }
    }
    @Published var speechCoverage: MediaSpeechCoverage {
        didSet { defaults.set(speechCoverage.rawValue, forKey: "mediaSpeechCoverage"); cancel(); invalidateSearch() }
    }
    @Published var speechModel: MediaSpeechModel {
        didSet { defaults.set(speechModel.rawValue, forKey: "mediaSpeechModel"); cancel(); invalidateSearch() }
    }
    private weak var store: ClipStore?
    private let defaults: UserDefaults
    private let directory: URL
    private let assets = GemmaMediaAssets()
    private let embedder = GemmaMediaEmbedder()
    private let transcriber = MediaSpeechTranscriber()
    private var entries: [UUID: Entry] = [:]
    private var operation: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var decoder: MediaAssetDecoder?
    private var observer: AnyCancellable?
    private var epoch = UUID()
    private var queryEpoch = UUID()
    private var lastQuery: String?
    private var loaded = false
    private var activeIndexID: UUID?

    init(store: ClipStore, defaults: UserDefaults = .standard) {
        self.store = store; self.defaults = defaults
        directory = store.storeDirectory.appendingPathComponent("MediaSearch-v1", isDirectory: true)
        preset = MediaSamplingPreset(rawValue: defaults.string(forKey: "mediaSamplingPreset") ?? "") ?? .balanced
        speechCoverage = MediaSpeechCoverage(rawValue: defaults.string(forKey: "mediaSpeechCoverage") ?? "") ?? .off
        speechModel = MediaSpeechModel(rawValue: defaults.string(forKey: "mediaSpeechModel") ?? "") ?? .turbo
        observer = store.objectWillChange.sink { [weak self] _ in
            // Published sends before assignment. Read authoritative state on the next main turn.
            Task { @MainActor [weak self] in self?.reconcile() }
        }
    }

    var mediaDownloaded: Bool { GemmaMediaAssets.localCandidateExists() }
    var speechDownloaded: Bool { MediaSpeechTranscriber.localCandidateExists(model: speechModel) }
    var allowed: Bool { store.map { $0.entitlement.isPro && !$0.safeMode && $0.storageComplete } ?? false }
    func visibleClip(_ id: UUID) -> ClipItem? {
        guard allowed, let item = store?.items.first(where: { $0.id == id }),
              !SensitiveClipPolicy.requiresAuthentication(item), !item.isIndexVetoed else { return nil }
        return item
    }
    private func clip(_ id: UUID) -> ClipItem? { visibleClip(id) }
    private func admit(_ ticket: UUID, id: UUID? = nil, fingerprint: String? = nil) throws {
        try Task.checkCancellation()
        guard ticket == epoch, allowed else { throw Failure.unavailable }
        if let id {
            guard let item = clip(id), fingerprint == SensitiveClipPolicy.fingerprint(item) else { throw Failure.changed }
        }
    }
    func cancel() {
        epoch = UUID(); operation?.cancel(); decoder?.cancel(); decoder = nil
        searchTask?.cancel(); queryEpoch = UUID(); matches = []; lastQuery = nil
        accessRevision &+= 1
        Task { await transcriber.cancel() }
        // Keep busy until owned work has settled; native inference is not preemptible.
    }
    private func invalidateSearch() { lastQuery = nil; matches = [] }
    private func reconcile() {
        guard allowed else {
            cancel(); entries = [:]; indexedCount = 0; loaded = false; prepared = false; preparedSpeechModel = nil
            Task { await embedder.close() }
            return
        }
        let invalid = entries.values.filter { entry in
            guard let item = clip(entry.clipID) else { return true }
            return SensitiveClipPolicy.fingerprint(item) != entry.fingerprint
        }.map(\.clipID)
        for id in invalid { entries[id] = nil; try? FileManager.default.removeItem(at: cacheURL(id)) }
        if !invalid.isEmpty { cancel(); indexedCount = entries.count }
    }
    private func cacheURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".sealed") }
    private func ensureDirectory() throws {
        try Self.checkAncestors(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    static func checkAncestors(_ directory: URL) throws {
        guard directory.isFileURL else { throw Failure.unsafeCache }
        var cursor = directory.standardizedFileURL
        while cursor.path != "/" {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: cursor.path),
               attrs[.type] as? FileAttributeType != .typeDirectory { throw Failure.unsafeCache }
            cursor.deleteLastPathComponent()
        }
    }
    private func loadEntries() throws {
        guard !loaded else { return }; try ensureDirectory()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        guard files.filter({ $0.pathExtension == "sealed" }).count <= 100 else { throw Failure.tooManyFiles }
        for file in files where file.pathExtension == "sealed" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
            guard let item = clip(id) else { try? FileManager.default.removeItem(at: file); continue }
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard file.standardizedFileURL == file.resolvingSymlinksInPath().standardizedFileURL,
                  values.isRegularFile == true, (values.fileSize ?? Int.max) <= 8 * 1024 * 1024 else { continue }
            let data = try Self.boundedFile(file, maximumBytes: 8 * 1024 * 1024)
            guard data.starts(with: Data("enc1:".utf8)), let plain = Crypto.open(data), plain != data,
                  let entry = try? JSONDecoder().decode(Entry.self, from: plain), entry.clipID == id,
                  entry.fingerprint == SensitiveClipPolicy.fingerprint(item),
                  (try? Self.validate(entry)) != nil else { continue }
            entries[id] = entry
        }
        loaded = true; indexedCount = entries.count
    }
    private func persist(_ entry: Entry, ticket: UUID) throws {
        try admit(ticket, id: entry.clipID, fingerprint: entry.fingerprint)
        try Self.validate(entry)
        try ensureDirectory()
        let data = try JSONEncoder().encode(entry)
        guard data.count <= 8 * 1024 * 1024, let sealed = Crypto.sealStrict(data), sealed != data,
              sealed.starts(with: Data("enc1:".utf8)) else { throw Failure.unsafeCache }
        try admit(ticket, id: entry.clipID, fingerprint: entry.fingerprint)
        try sealed.write(to: cacheURL(entry.clipID), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL(entry.clipID).path)
        entries[entry.clipID] = entry; indexedCount = entries.count; invalidateSearch()
    }
    static func validate(_ entry: Entry) throws {
        try MediaSearchCache().validate(entry.record)
        guard let preset = MediaSamplingPreset(rawValue: entry.preset),
              MediaSpeechCoverage(rawValue: entry.speech) != nil,
              MediaSpeechModel(rawValue: entry.speechModel) != nil,
              entry.record.identity.modelRevision == GemmaMediaAssets.signature,
              entry.record.identity.preprocessingRevision == "jpeg1024-pcm16mono16k-v1",
              entry.record.identity.samplingRevision == "v1-\(preset.rawValue)",
              entry.bookmark.count <= 64 * 1024, !entry.bookmark.isEmpty,
              entry.size > 0, entry.size <= 2 * 1024 * 1024 * 1024,
              entry.path.hasPrefix("/"), entry.path.utf8.count <= 16_384,
              entry.passages.count <= 1000,
              entry.record.vectors.allSatisfy({ validVector($0.vector) }),
              entry.passages.allSatisfy({ passage in
                  passage.start.isFinite && passage.end.isFinite && passage.start >= 0 && passage.end >= passage.start
                  && passage.end <= entry.record.duration && !passage.text.isEmpty && passage.text.utf8.count <= 1000
                  && validVector(passage.vector)
                  && !SensitiveClipPolicy.requiresAuthentication(flags: Detectors.scan(text: passage.text, kind: .text, sourceApp: nil).flags)
              }) else { throw Failure.invalidFile }
    }
    static func validVector(_ vector: [Float]) -> Bool {
        guard vector.count == 768, vector.allSatisfy(\.isFinite) else { return false }
        let square = vector.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (0.99...1.01).contains(square)
    }
    static func boundedImage(_ url: URL) throws -> Data {
        try boundedFile(url, maximumBytes: GemmaMediaEmbedder.maximumImageBytes)
    }
    static func boundedFile(_ url: URL, maximumBytes: Int) throws -> Data {
        guard maximumBytes > 0, maximumBytes <= 8 * 1024 * 1024 else { throw Failure.invalidFile }
        guard url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL,
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw Failure.invalidFile }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var bytes = Data()
        while let chunk = try file.read(upToCount: min(1_048_576, maximumBytes + 1 - bytes.count)), !chunk.isEmpty {
            try Task.checkCancellation(); bytes.append(chunk)
            guard bytes.count <= maximumBytes else { throw Failure.invalidFile }
        }
        return bytes
    }
    private func transferProgress(_ done: Int64, _ total: Int64, ticket: UUID, title: String) {
        guard ticket == epoch, allowed, busy, total > 0 else { return }
        preparationProgress = min(1, max(0, Double(done) / Double(total)))
        preparationTitle = done >= total ? "Checking files and preparing on this Mac…" : title
    }
    func prepare(download: Bool) {
        guard allowed, !busy else { return }
        busy = true; preparationProgress = nil
        preparationTitle = download ? "Connecting to Hugging Face…" : "Checking downloaded media model…"
        status = "Preparing media search on this Mac…"
        let ticket = epoch
        operation = Task {
            defer { busy = false; operation = nil; preparationTitle = nil; preparationProgress = nil }
            do {
                try admit(ticket)
                let url: URL
                if download {
                    url = try await assets.download { [weak self] done, total in
                        Task { @MainActor [weak self] in self?.transferProgress(done, total, ticket: ticket, title: "Downloading media model…") }
                    }
                } else { url = try await assets.verifiedModel() }
                try admit(ticket)
                preparationTitle = "Preparing media search on this Mac…"; preparationProgress = nil
                try await embedder.prepare(modelURL: url, cacheURL: directory.appendingPathComponent("Runtime", isDirectory: true))
                try admit(ticket)
                try loadEntries(); prepared = true; status = "Ready offline. Choose files to index on this Mac."
            } catch {
                guard ticket == epoch, !Task.isCancelled else { status = "Preparation stopped. You can try again when ready."; return }
                status = download ? "Couldn’t prepare the media model. Check your connection and free space, then retry." : "Download the media model to get started."
            }
        }
    }
    func prepareSpeech() {
        guard allowed, !busy else { return }; busy = true
        let ticket = epoch, selected = speechModel
        preparedSpeechModel = nil; preparationProgress = nil
        preparationTitle = "Preparing \(selected.label)…"
        status = "Checking downloaded speech files…"
        operation = Task {
            defer { busy = false; operation = nil; preparationTitle = nil; preparationProgress = nil }
            do {
                try admit(ticket)
                try await transcriber.prepare(model: selected, allowDownload: true) { [weak self] done, total in
                    Task { @MainActor [weak self] in self?.transferProgress(done, total, ticket: ticket, title: "Downloading \(selected.label)…") }
                }
                try admit(ticket); preparedSpeechModel = selected
                status = "Speech model ready offline. Re-index files to include spoken words."
            } catch {
                guard ticket == epoch, !Task.isCancelled else { status = "Speech preparation stopped. Completed downloads are kept."; return }
                status = "Couldn’t prepare the speech model. Check your connection and free space, then retry."
            }
        }
    }
    func chooseFiles() {
        guard allowed, prepared, !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .audio, .image]; panel.prompt = "Index on this Mac"
        guard panel.runModal() == .OK else { return }
        index(urls: panel.urls)
    }
    func index(urls: [URL]) {
        guard allowed, prepared, !busy, !urls.isEmpty else { return }
        guard urls.count <= 10, entries.count + urls.count <= 100 else { status = "Choose up to 10 files at a time (100 indexed files maximum)."; return }
        busy = true; searchTask?.cancel(); queryEpoch = UUID(); matches = []; lastQuery = nil
        let ticket = epoch, selectedPreset = preset, coverage = speechCoverage, selectedModel = speechModel
        operation = Task {
            defer { decoder?.cancel(); decoder = nil; busy = false; operation = nil }
            var completed = 0
            for url in urls {
                do {
                    try admit(ticket)
                    status = "Indexing file \(completed + 1) of \(urls.count)…"
                    try await indexOne(url, ticket: ticket, preset: selectedPreset, coverage: coverage, model: selectedModel)
                    completed += 1
                } catch {
                    if ticket != epoch || Task.isCancelled { status = "Indexing stopped. Completed files are kept."; return }
                    status = "A file could not be indexed. Check access, model preparation and the displayed limits."
                    return
                }
            }
            status = "Indexed \(completed) file\(completed == 1 ? "" : "s"). Search Media to find matching moments."
        }
    }
    private func indexOne(_ url: URL, ticket: UUID, preset: MediaSamplingPreset,
                          coverage: MediaSpeechCoverage, model: MediaSpeechModel) async throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try admit(ticket)
        guard url.isFileURL, url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL else { throw Failure.invalidFile }
        let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0,
              let modified = values.contentModificationDate else { throw Failure.invalidFile }
        guard let store else { throw Failure.unavailable }
        let draft = ClipItem(kind: .file, text: url.lastPathComponent); draft.filePath = url.path
        guard !SensitiveClipPolicy.requiresAuthentication(draft) else { throw Failure.unavailable }
        let item: ClipItem
        if let existing = store.items.first(where: { $0.kind == .file && $0.filePath == url.path }) { item = existing }
        else { store.add(draft); item = draft }
        let id = item.id, fingerprint = SensitiveClipPolicy.fingerprint(item)
        activeIndexID = id
        defer { activeIndexID = nil }
        try admit(ticket, id: id, fingerprint: fingerprint)
        let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        var vectors: [MediaSearchCache.TimedVector] = [], passages: [SpeechPassage] = []
        let still = values.contentType?.conforms(to: .image) == true
        var duration = 1.0, digest: String
        if still {
            guard size <= GemmaMediaEmbedder.maximumImageBytes else { throw Failure.invalidFile }
            let bytes = try Self.boundedImage(url); digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            try admit(ticket, id: id, fingerprint: fingerprint)
            let vector = try await embedder.embedImage(bytes)
            try admit(ticket, id: id, fingerprint: fingerprint)
            vectors.append(.init(modality: .video, start: 0, end: 0, vector: vector))
        } else {
            var limits = MediaAssetDecoder.Limits(); limits.deadlineSeconds = 1800
            let reader = try await MediaAssetDecoder(url: url, limits: limits); decoder = reader
            defer { reader.cancel() }
            try admit(ticket, id: id, fingerprint: fingerprint)
            duration = reader.metadata.duration; digest = reader.metadata.contentSHA256
            if coverage == .full && duration > 3600 { throw Failure.speechTooLong }
            if reader.metadata.hasVideo {
                let plan = try MediaSamplingPlan.make(duration: duration, preset: preset, modality: .video)
                try await reader.frames(plan: plan) { [self] frame in
                    try await admit(ticket, id: id, fingerprint: fingerprint)
                    let vector = try await embedder.embedImage(frame.jpeg)
                    try await admit(ticket, id: id, fingerprint: fingerprint)
                    vectors.append(.init(modality: .video, start: frame.actualTimestamp, end: frame.actualTimestamp, vector: vector))
                }
            }
            if reader.metadata.hasAudio {
                let plan = try MediaSamplingPlan.make(duration: duration, preset: preset, modality: .audio)
                try await reader.audio(plan: plan) { [self] window in
                    try await admit(ticket, id: id, fingerprint: fingerprint)
                    let vector = try await embedder.embedAudio(window.wav)
                    try await admit(ticket, id: id, fingerprint: fingerprint)
                    vectors.append(.init(modality: .audio, start: window.start, end: window.end, vector: vector))
                    if coverage == .sampled {
                        passages += try await speech(window.wav, start: window.start, end: window.end, model: model, ticket: ticket, id: id, fingerprint: fingerprint)
                        guard passages.count <= 1000 else { throw Failure.invalidFile }
                    }
                }
                if coverage == .full {
                    reader.cancel()
                    limits.maximumOutputBytes = 128 * 1024 * 1024
                    let speechReader = try await MediaAssetDecoder(url: url, limits: limits); decoder = speechReader
                    defer { speechReader.cancel() }
                    guard speechReader.metadata.contentSHA256 == digest else { throw Failure.changed }
                    let full = try MediaSamplingPlan.make(duration: duration, preset: .detailed, modality: .audio)
                    try await speechReader.audio(plan: full) { [self] window in
                        try await admit(ticket, id: id, fingerprint: fingerprint)
                        passages += try await speech(window.wav, start: window.start, end: window.end, model: model, ticket: ticket, id: id, fingerprint: fingerprint)
                        guard passages.count <= 1000 else { throw Failure.invalidFile }
                    }
                }
            }
        }
        try admit(ticket, id: id, fingerprint: fingerprint)
        let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard after.fileSize == size, after.contentModificationDate == modified else { throw Failure.changed }
        let identity = MediaSearchCache.Identity(contentSHA256: digest, modelRevision: GemmaMediaAssets.signature,
            preprocessingRevision: "jpeg1024-pcm16mono16k-v1", samplingRevision: "v1-\(preset.rawValue)")
        let record = MediaSearchCache.Record(identity: identity, duration: duration, vectors: vectors)
        try MediaSearchCache().validate(record)
        try persist(Entry(clipID: id, fingerprint: fingerprint, bookmark: bookmark, path: url.path, modified: modified, size: size,
            stillImage: still, preset: preset.rawValue, speech: coverage.rawValue, speechModel: model.rawValue,
            record: record, passages: passages), ticket: ticket)
    }
    private func speech(_ wav: Data, start: Double, end: Double, model: MediaSpeechModel,
                        ticket: UUID, id: UUID, fingerprint: String) async throws -> [SpeechPassage] {
        try admit(ticket, id: id, fingerprint: fingerprint)
        let segments = try await transcriber.transcribe(wav: wav, start: start, end: end, model: model)
        try admit(ticket, id: id, fingerprint: fingerprint)
        var result: [SpeechPassage] = []
        for segment in segments {
            // Transcript privacy admission happens before embedding or persistence.
            guard !SensitiveClipPolicy.requiresAuthentication(flags: Detectors.scan(text: segment.text, kind: .text, sourceApp: nil).flags) else { continue }
            for chunk in Self.textChunks(segment.text) {
                try admit(ticket, id: id, fingerprint: fingerprint)
                let vector = try await embedder.embedDocument(chunk)
                try admit(ticket, id: id, fingerprint: fingerprint)
                result.append(SpeechPassage(start: segment.start, end: segment.end, text: chunk, vector: vector))
                guard result.count <= 1000 else { throw Failure.invalidFile }
            }
        }
        return result
    }
    static func textChunks(_ text: String) -> [String] {
        var chunks: [String] = [], current = "", count = 0
        for character in text {
            let part = String(character), bytes = part.utf8.count
            if count + bytes > 1000 { if !current.isEmpty { chunks.append(current) }; current = ""; count = 0 }
            guard bytes <= 1000 else { continue }
            current += part; count += bytes
        }
        if !current.isEmpty { chunks.append(current) }; return chunks
    }
    private func current(_ entry: Entry) -> Bool {
        guard let item = clip(entry.clipID), SensitiveClipPolicy.fingerprint(item) == entry.fingerprint,
              entry.record.identity.modelRevision == GemmaMediaAssets.signature else { return false }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: entry.bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale), !stale else { return false }
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard url.path == entry.path, let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]) else { return false }
        return values.isRegularFile == true && values.fileSize == entry.size && values.contentModificationDate == entry.modified
    }
    func search(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard allowed, prepared, !busy else { matches = []; return }
        guard q != lastQuery else { return }; lastQuery = q
        searchTask?.cancel(); queryEpoch = UUID(); let token = queryEpoch, ticket = epoch
        matches = []
        searchTask = Task {
            do {
                try await Task.sleep(nanoseconds: 250_000_000); try admit(ticket)
                let eligible = entries.values.filter(current)
                if q.isEmpty {
                    guard token == queryEpoch else { return }
                    matches = eligible.map { Match(clipID: $0.clipID, start: 0, end: 0, score: 0, source: $0.stillImage ? "Picture" : "Media", passage: nil) }
                    return
                }
                guard q.utf8.count <= 1024 else { status = "Use a search description shorter than 1,024 bytes."; return }
                let vector = try await embedder.embedQuery(q); try admit(ticket)
                guard token == queryEpoch else { return }
                var found: [Match] = []
                for entry in eligible where current(entry) {
                    var best: Match?
                    for moment in entry.record.vectors {
                        let score = Self.cosine(vector, moment.vector)
                        if best == nil || score > best!.score { best = Match(clipID: entry.clipID, start: moment.start, end: moment.end, score: score, source: moment.modality == .video ? (entry.stillImage ? "Picture" : "Video frame") : "Audio", passage: nil) }
                    }
                    for passage in entry.passages {
                        guard !SensitiveClipPolicy.requiresAuthentication(flags: Detectors.scan(text: passage.text, kind: .text, sourceApp: nil).flags) else { continue }
                        let score = Self.cosine(vector, passage.vector)
                        if best == nil || score > best!.score { best = Match(clipID: entry.clipID, start: passage.start, end: passage.end, score: score, source: "Speech", passage: passage.text) }
                    }
                    if let best { found.append(best) }
                }
                matches = found.sorted { $0.score > $1.score }
            } catch { if token == queryEpoch { status = "Search is unavailable. Prepare the model and try again." } }
        }
    }
    static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -.infinity }
        return zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 }
    }
    func forget() {
        guard allowed, !busy else { return }
        cancel()
        for id in entries.keys { try? FileManager.default.removeItem(at: cacheURL(id)) }
        entries = [:]; indexedCount = 0; status = "Media indexes removed. Original files and clips are kept."
    }
    /// Called by the store's existing deletion/retention path, even before model preparation.
    func discard(_ id: UUID) {
        // No model, cache-directory creation or secret read is needed to forget derived data.
        guard (try? Self.checkAncestors(directory)) != nil else { return }
        if activeIndexID == id { cancel() }
        accessRevision &+= 1
        entries[id] = nil
        try? FileManager.default.removeItem(at: cacheURL(id))
        matches.removeAll { $0.clipID == id }; indexedCount = entries.count
    }
    func coverageDescription(_ id: UUID) -> String {
        guard let entry = entries[id], let preset = MediaSamplingPreset(rawValue: entry.preset) else { return "" }
        if entry.stillImage { return "Picture indexed locally" }
        let video = try? MediaSamplingPlan.make(duration: entry.record.duration, preset: preset, modality: .video)
        var parts = ["Indexed: \(preset.rawValue)"]
        if entry.record.vectors.contains(where: { $0.modality == .video }), let video {
            parts.append("\(video.segments.reduce(0) { $0 + $1.frameTimestamps.count }) frames, every \(Int(video.effectiveInterval.rounded()))s")
        }
        if entry.record.vectors.contains(where: { $0.modality == .audio }) {
            let actual = entry.record.vectors.filter { $0.modality == .audio }.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
            parts.append("audio sampled \(Int((min(1, actual / entry.record.duration) * 100).rounded()))% of the file")
        }
        if entry.speech != MediaSpeechCoverage.off.rawValue && entry.record.vectors.contains(where: { $0.modality == .audio }) {
            parts.append(entry.speech == MediaSpeechCoverage.full.rawValue ? "continuous speech" : "sampled speech")
        }
        return parts.joined(separator: " · ")
    }
    /// Caller owns the returned scope until its player closes. Revalidate source identity
    /// before playback, not just the stored filename.
    func playback(_ match: Match) async throws -> (URL, Bool, Data?) {
        guard let entry = entries[match.clipID], current(entry),
              match.start.isFinite, match.end.isFinite, match.start >= 0, match.end >= match.start,
              match.end <= entry.record.duration,
              matches.contains(where: { $0.clipID == match.clipID && $0.start == match.start && $0.end == match.end && $0.source == match.source }) else { throw Failure.changed }
        let ticket = epoch; try admit(ticket, id: match.clipID, fingerprint: entry.fingerprint)
        let searchTicket = queryEpoch
        var stale = false
        let url = try URL(resolvingBookmarkData: entry.bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            var imageSnapshot: Data?
            guard !stale else { throw Failure.changed }
            if !entry.stillImage {
                let readback = try await MediaAssetDecoder(url: url)
                defer { readback.cancel() }
                guard readback.metadata.contentSHA256 == entry.record.identity.contentSHA256 else { throw Failure.changed }
            } else {
                let bytes = try Self.boundedImage(url)
                guard bytes.count <= GemmaMediaEmbedder.maximumImageBytes,
                      SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == entry.record.identity.contentSHA256 else { throw Failure.changed }
                try GemmaMediaEmbedder.validateImage(bytes)
                imageSnapshot = bytes
            }
            try admit(ticket, id: match.clipID, fingerprint: entry.fingerprint)
            guard searchTicket == queryEpoch else { throw Failure.changed }
            return (url, scoped, imageSnapshot)
        } catch { if scoped { url.stopAccessingSecurityScopedResource() }; throw error }
    }
}
