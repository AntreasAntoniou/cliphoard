import AppKit
import UniformTypeIdentifiers

/// Polls `NSPasteboard.general` and turns new contents into `ClipItem`s.
@MainActor
final class ClipboardMonitor {
    private let store: ClipStore
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var lastChangeCount: Int
    /// When we write to the pasteboard ourselves (on paste) we bump this so the
    /// next poll doesn't re-capture our own write.
    private var ignoreChangeCount: Int = -1

    init(store: ClipStore) {
        self.store = store
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        // Opt out of App Nap. Without this, macOS suspends a backgrounded
        // accessory app that looks idle and the poll timer stops firing —
        // so new copies are only picked up after a restart. `…AllowingIdleSystemSleep`
        // keeps us awake to poll while still letting the Mac sleep normally.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled],
            reason: "Monitoring the clipboard for new copies")

        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        t.tolerance = 0.1
        // `.common` modes keep polling alive during menu tracking, live
        // scrolling, and window resize — otherwise a `.default`-mode timer
        // silently pauses and clips copied in those moments are missed.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }

    /// Tell the monitor to skip the change we are about to cause ourselves.
    func suppressNextChange() {
        ignoreChangeCount = NSPasteboard.general.changeCount + 1
    }

    private func poll() {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        let typeList = (pb.types ?? []).map { $0.rawValue }.joined(separator: ",")
        DebugLog.write("change #\(count) types=[\(typeList)]")

        if count == ignoreChangeCount {
            DebugLog.write("  → skipped (our own paste)")
            return
        }

        // Respect apps that mark content as transient/concealed (e.g. password managers).
        if let types = pb.types {
            if types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) {
                DebugLog.write("  → skipped (transient)"); return
            }
            if types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) {
                DebugLog.write("  → skipped (concealed)"); return
            }
        }

        guard let item = capture(from: pb) else {
            DebugLog.write("  → skipped (no readable content)")
            return
        }
        item.sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
        DebugLog.write("  → captured \(item.kind.rawValue): \(item.preview.prefix(40))")
        store.add(item)
    }

    private func capture(from pb: NSPasteboard) -> ClipItem? {
        // 1. Files take priority — drag/copy of Finder items.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first, url.isFileURL {
            let item = ClipItem(kind: .file, text: url.path)
            item.filePath = url.path
            return item
        }

        // 2. Images.
        if let image = NSImage(pasteboard: pb), pb.canReadObject(forClasses: [NSImage.self], options: nil) {
            let item = ClipItem(kind: .image, text: "Image \(Int(image.size.width))×\(Int(image.size.height))")
            if let file = persistImage(image, id: item.id) {
                item.payloadFile = file
            }
            return item
        }

        // 3. Text (and styled text).
        if let string = pb.string(forType: .string), !string.isEmpty {
            let kind: ClipKind = Self.detectKind(for: string)
            let item = ClipItem(kind: kind, text: string)
            if kind == .color { item.colorHex = string.trimmingCharacters(in: .whitespaces) }
            if let rtf = pb.data(forType: .rtf) { item.rtf = rtf }
            return item
        }

        return nil
    }

    private func persistImage(_ image: NSImage, id: UUID) -> String? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let name = "\(id.uuidString).png"
        let url = store.storeDirectory.appendingPathComponent(name)
        do { try png.write(to: url); return name } catch { return nil }
    }

    static func detectKind(for string: String) -> ClipKind {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if isColor(trimmed) { return .color }
        if isLink(trimmed) { return .link }
        return .text
    }

    private static func isColor(_ s: String) -> Bool {
        let hex = "^#?([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8}|[0-9A-Fa-f]{3})$"
        return s.range(of: hex, options: .regularExpression) != nil
    }

    private static func isLink(_ s: String) -> Bool {
        guard !s.contains(" "), s.count < 2048 else { return false }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "ftp", "mailto"].contains(scheme) && url.host != nil || scheme == "mailto"
    }
}
