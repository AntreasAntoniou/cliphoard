import SwiftUI
import AppKit
import ImageIO

/// Read and downsample inspector pictures after the window has been laid out.
/// Each view owns only its display-sized image, released when it disappears.
@MainActor
struct InspectorPayloadImage: View {
    let item: ClipItem
    let directory: URL
    let maxPixelSize: Int
    var contentMode: ContentMode = .fit
    @ObservedObject private var reveal = SensitiveClipReveal.shared
    @State private var image: NSImage?
    @State private var loadedRequest: Request?

    private var request: Request {
        Request(id: item.id, file: item.payloadFile, revealRevision: reveal.revision)
    }

    var body: some View {
        Group {
            if reveal.isConcealed(item) {
                Image(systemName: "lock.fill")
            } else if loadedRequest == request, let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .task(id: request) {
            let loadingRequest = request
            loadedRequest = nil
            image = nil
            guard !reveal.isConcealed(item), let file = item.payloadFile else { return }
            let url = directory.appendingPathComponent(file)
            let stored = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
            guard !Task.isCancelled, !reveal.isConcealed(item), let stored,
                  let data = Crypto.open(stored) else { return }
            let size = maxPixelSize
            let decoded = await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil as CGImage? }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: size,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary)
            }.value
            guard !Task.isCancelled, !reveal.isConcealed(item), let decoded else { return }
            guard request == loadingRequest else { return }
            image = NSImage(cgImage: decoded, size: .zero)
            loadedRequest = loadingRequest
        }
        .onDisappear { image = nil }
    }

    private struct Request: Equatable {
        let id: UUID
        let file: String?
        let revealRevision: Int
    }
}
