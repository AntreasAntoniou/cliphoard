import SwiftUI
import AVKit

struct MediaSearchSettingsView: View {
    @ObservedObject var controller: MediaSearchController
    @ObservedObject var store: ClipStore
    var showPro: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Find a scene, a sound or a spoken passage. Videos are searched through both their picture and audio tracks. Files and transcripts stay on this Mac.")
            if !store.entitlement.isPro {
                Button("Get Pro for media search", action: showPro)
            } else {
                Picker("Sampling", selection: $controller.preset) {
                    Text("Lightweight").tag(MediaSamplingPreset.lightweight)
                    Text("Balanced (recommended)").tag(MediaSamplingPreset.balanced)
                    Text("Detailed").tag(MediaSamplingPreset.detailed)
                }.disabled(controller.busy)
                Text(samplingExplanation).font(.caption).foregroundStyle(.secondary)
                Picker("Audio search", selection: $controller.speechCoverage) {
                    ForEach(MediaSpeechCoverage.allCases, id: \.self) { Text($0.title).tag($0) }
                }.disabled(controller.busy)
                if controller.speechCoverage != .off {
                    Picker("Speech model", selection: $controller.speechModel) {
                        Text("Whisper Large v3 Turbo · 1.64 GB").tag(MediaSpeechModel.turbo)
                        Text("Whisper Small · 489 MB").tag(MediaSpeechModel.small)
                        Text("Whisper Large v3 · 3.09 GB").tag(MediaSpeechModel.largeV3)
                    }.disabled(controller.busy)
                    Button("Download / prepare speech model") { controller.prepareSpeech() }
                        .disabled(controller.busy || !controller.allowed)
                    Text("Speech models are separate, optional downloads. Every spoken passage covers continuous audio up to 60 minutes; sampled speech can miss sentences. Re-index files after changing these choices.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Download media model · 485 MB") { controller.prepare(download: true) }
                    Button("Use installed model") { controller.prepare(download: false) }
                }.disabled(controller.busy || !controller.allowed)
                HStack {
                    Button("Choose pictures, video or audio…") { controller.chooseFiles() }
                        .disabled(!controller.prepared || controller.busy || !controller.allowed)
                    if controller.busy { Button("Stop indexing / preparation") { controller.cancel() } }
                    Button("Forget media indexes") { controller.forget() }
                        .disabled(controller.busy || controller.indexedCount == 0 || !controller.allowed)
                }
                Text(controller.status).font(.caption)
                Text("\(controller.indexedCount) indexed files. Original files remain where they are. Up to 10 files per batch, 100 indexed files, 2 GB per video/audio file, 6 hours and 4K; pictures up to 8 MB. Long media is sampled across its full duration, with at most 120 windows per track. Sampling can miss brief events. Results rank the closest moments; they are not guaranteed matches.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var samplingExplanation: String {
        switch controller.preset {
        case .lightweight: return "Video: 2 frames around 2 seconds each minute. Audio: 3 seconds each minute."
        case .balanced: return "Video: 3 frames across 3 seconds every 30 seconds. Audio: 10 seconds every 30 seconds."
        case .detailed: return "Video: 3 frames across 3 seconds every 10 seconds. Audio: 30-second windows."
        }
    }
}

struct MediaSearchResultsView: View {
    @ObservedObject var controller: MediaSearchController
    @ObservedObject var model: PanelViewModel
    @ObservedObject private var sensitiveReveal = SensitiveClipReveal.shared
    @State private var playback: MediaPlayback?
    @State private var message: String?
    @State private var openTask: Task<Void, Never>?
    @State private var openTicket = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(controller.busy ? controller.status : "Media · matching moments").font(.caption)
                Spacer()
                Button("Media options") {
                    model.requestedSettingsSection = "cliphoard-media"
                    model.settingsFocusRequest = UUID()
                    model.showSettings = true
                }
            }
            if !controller.prepared {
                Text("Prepare the media model and choose files in Settings → Video, audio & pictures.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        ForEach(model.results) { item in
                            if controller.visibleClip(item.id) != nil,
                               let match = controller.matches.first(where: { $0.clipID == item.id }) {
                                HStack(alignment: .top) {
                                    Image(systemName: "play.rectangle")
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.text).lineLimit(1)
                                        Text("\(match.source) · \(Self.timestamp(match.start))").font(.caption).foregroundStyle(.secondary)
                                        Text(controller.coverageDescription(item.id)).font(.caption2).foregroundStyle(.secondary)
                                        if let passage = match.passage { Text(passage).font(.caption).lineLimit(2) }
                                    }
                                    Spacer()
                                    Button("Open moment") { open(match) }
                                }
                            }
                        }
                    }
                }
                if controller.matches.isEmpty && !controller.busy {
                    Text("Choose files to index, then describe what you want to find.").foregroundStyle(.secondary)
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 18)
        .task { if controller.allowed && !controller.prepared && !controller.busy { controller.prepare(download: false) } }
        .task(id: model.query) { controller.search(WhenToken.parse(model.query).rest) }
        .onChange(of: controller.busy) { busy in if !busy { controller.search(WhenToken.parse(model.query).rest) } }
        .onChange(of: controller.prepared) { _ in controller.search(WhenToken.parse(model.query).rest) }
        .sheet(item: $playback) { item in MediaPlaybackView(playback: item) }
        .onDisappear { close() }
        .onChange(of: controller.accessRevision) { _ in close() }
        .onChange(of: sensitiveReveal.revision) { _ in close() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in close() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in close() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in close() }
    }
    private func open(_ match: MediaSearchController.Match) {
        close(); let ticket = openTicket
        openTask = Task {
            do {
                let (url, scoped, image) = try await controller.playback(match)
                guard !Task.isCancelled, ticket == openTicket else { if scoped { url.stopAccessingSecurityScopedResource() }; return }
                playback?.close()
                playback = MediaPlayback(url: url, scoped: scoped, image: image, start: match.start)
            } catch { message = "This file changed or is unavailable. Choose it again to refresh its index." }
        }
    }
    private func close() { openTicket = UUID(); openTask?.cancel(); openTask = nil; playback?.close(); playback = nil }
    static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < 1_000_000 else { return "—" }
        let value = Int(seconds)
        return String(format: "%d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60)
    }
}

@MainActor
final class MediaPlayback: Identifiable {
    let id = UUID()
    let url: URL
    let image: Data?
    let player: AVPlayer?
    private var scoped: Bool
    init(url: URL, scoped: Bool, image: Data?, start: Double) {
        self.url = url; self.scoped = scoped; self.image = image
        let asset = AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue), AVURLAssetShouldSupportAliasDataReferencesKey: false])
        player = image != nil ? nil : AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player?.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func close() { player?.pause(); player?.replaceCurrentItem(with: nil); if scoped { url.stopAccessingSecurityScopedResource(); scoped = false } }
}

struct MediaPlaybackView: View {
    let playback: MediaPlayback
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack {
            if let bytes = playback.image, let image = NSImage(data: bytes) {
                Image(nsImage: image).resizable().scaledToFit()
            } else if let player = playback.player { VideoPlayer(player: player) }
            Button("Close") { playback.close(); dismiss() }
        }.padding().frame(minWidth: 600, minHeight: 360)
            .onDisappear { playback.close() }
    }
}
