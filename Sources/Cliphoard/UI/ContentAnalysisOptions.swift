import SwiftUI

@MainActor
struct ContentAnalysisOptions: View {
    @ObservedObject var analysis: ContentAnalysisController
    let isPro: Bool
    @AppStorage("nsfwEnabled") private var enabled = true
    @AppStorage("nsfwFocusOnly") private var focusOnly = false
    @AppStorage("nsfwImagesEnabled") private var images = true
    @AppStorage("nsfwAudioEnabled") private var audio = true
    @AppStorage("nsfwVideoEnabled") private var video = true
    @AppStorage("documentTextEnabled") private var documents = false
    @AppStorage("documentPDFEnabled") private var pdf = true
    @AppStorage("documentRichTextEnabled") private var richText = true
    @AppStorage("documentTagsEnabled") private var tags = true

    private var configuration: [Bool] { [enabled, focusOnly, images, audio, video, documents, pdf, richText, tags] }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sensitive content · NSFW").font(.headline)
            Toggle("Protect possible NSFW content", isOn: $enabled)
            Text("Enabled by default. Conceals possible matches until you authenticate with macOS. Turning this off disables NSFW screening and concealment; other sensitive-content protections remain active.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Activate only in configured Focus modes", isOn: $focusOnly).disabled(!enabled)
            if focusOnly {
                Text("In System Settings → Focus → Work, Do Not Disturb, or another Focus → Add Filter → Cliphoard, turn on Protect NSFW content. Only those configured modes activate protection. If Focus status cannot be read, protection stays on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Screen images · Free", isOn: $images).disabled(!enabled)
            Toggle("Screen audio samples · Pro", isOn: $audio).disabled(!enabled || !isPro)
            Toggle("Screen video frames · Pro", isOn: $video).disabled(!enabled || !isPro)
            Text("Text, filenames and full paths are checked in Free, including paths to audio and video. Text screening uses the downloaded MiniLM sentence model; image screening uses OpenVision. Pro samples audio/video with the downloaded multimodal model. No content is uploaded. Models can misclassify content or miss it between samples; no match does not mean safe. Add an NSFW user tag to classify an item yourself.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Prepare text & image screening models (74 MB)") { analysis.prepareImages() }.disabled(!enabled || analysis.busy)
            Text(analysis.modelStatus).font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Search inside files").font(.headline)
            Toggle("Extract text from readable files", isOn: $documents)
            Toggle("Include embedded PDF text", isOn: $pdf).disabled(!documents)
            Toggle("Include rich text (RTF)", isOn: $richText).disabled(!documents)
            Toggle("Use extracted file text for model tags", isOn: $tags).disabled(!documents)
            Text("Optional extra work on this Mac: reading files, parsing PDFs and embedding text use CPU, memory and battery. Audio/video screening costs more because it decodes samples and runs a multimodal model. Extraction supports UTF-8/UTF-16 text and source files, RTF, and PDFs with embedded text; HTML is indexed as source. Scanned PDFs need OCR and are not handled here. Limits: 16 MB per file, 100 PDF pages and 200,000 characters. Password-protected, inaccessible and unsupported files are skipped.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Extracted text appears in Inspect and feeds search and optional tags. It is an encrypted snapshot: refresh after changing a file. Turning extraction off stops new work and excludes snapshots from search/tags; the saved text remains visible in Inspect. Originals are never changed. Credential-like extracted text is withheld.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Refresh file text and NSFW checks") { analysis.refresh() }.disabled(analysis.busy)
            Text(analysis.status).font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: configuration) { _ in
            NotificationCenter.default.post(name: ContentAnalysisPreferences.changed, object: nil)
        }
    }
}
