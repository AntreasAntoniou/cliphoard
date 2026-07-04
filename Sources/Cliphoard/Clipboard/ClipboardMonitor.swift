import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// The minimal set of pasteboard reads `capture()` performs. `NSPasteboard`
/// satisfies this as-is; tests provide a fake so capture can run headless
/// without touching the system pasteboard. Production behaviour is unchanged —
/// `poll()` still hands `NSPasteboard.general` straight through.
@MainActor
protocol PasteboardReading: AnyObject {
    func readObjects(forClasses classes: [AnyClass], options: [NSPasteboard.ReadingOptionKey: Any]?) -> [Any]?
    func canReadObject(forClasses classes: [AnyClass], options: [NSPasteboard.ReadingOptionKey: Any]?) -> Bool
    func string(forType type: NSPasteboard.PasteboardType) -> String?
    func data(forType type: NSPasteboard.PasteboardType) -> Data?
    /// The image on the pasteboard, if any. On `NSPasteboard` this is
    /// `NSImage(pasteboard:)`; a fake returns a directly-supplied image.
    func readImage() -> NSImage?
}

extension NSPasteboard: PasteboardReading {
    func readImage() -> NSImage? { NSImage(pasteboard: self) }
}

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

        if DebugLog.enabled {
            let typeList = (pb.types ?? []).map { $0.rawValue }.joined(separator: ",")
            DebugLog.write("change #\(count) types=[\(typeList)]")
        }

        if count == ignoreChangeCount {
            DebugLog.write("  → skipped (our own paste)")
            return
        }

        // Respect apps that mark content as transient/concealed/auto-generated
        // (e.g. password managers) and any bundle IDs the user has excluded.
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let types = (pb.types ?? []).map { $0.rawValue }
        let excluded = UserDefaults.standard.stringArray(forKey: "excludedBundleIDs") ?? []
        if Self.shouldSkip(frontmostBundleID: frontmostBundleID, types: types, excluded: excluded) {
            DebugLog.write("  → skipped (excluded app or private pasteboard)")
            return
        }

        guard let item = capture(from: pb) else {
            DebugLog.write("  → skipped (no readable content)")
            return
        }
        item.sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
        DebugLog.write("  → captured \(item.kind.rawValue)")
        store.add(item)
    }

    /// Pure decision for whether a poll should drop the current pasteboard
    /// contents without capturing. Skips when the frontmost app is on the
    /// user denylist, or when the pasteboard declares a private/auto-generated
    /// type (transient, concealed, or auto-generated).
    nonisolated static func shouldSkip(frontmostBundleID: String?, types: [String], excluded: [String]) -> Bool {
        if let id = frontmostBundleID, excluded.contains(id) { return true }
        let privateTypes: Set<String> = [
            "org.nspasteboard.TransientType",
            "org.nspasteboard.ConcealedType",
            "org.nspasteboard.AutoGeneratedType",
        ]
        return types.contains(where: privateTypes.contains)
    }

    /// Turn the current pasteboard contents into a `ClipItem`, prioritising
    /// file > image > text. Parameterised over `PasteboardReading` so tests can
    /// exercise it against a fake; production passes `NSPasteboard.general`.
    /// `internal` (not `private`) so `@testable` capture tests can drive it.
    func capture(from pb: PasteboardReading) -> ClipItem? {
        // 1. Files take priority — drag/copy of Finder items.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first, url.isFileURL {
            let item = ClipItem(kind: .file, text: url.path)
            item.filePath = url.path
            return item
        }

        // 2. Images.
        if let image = pb.readImage(), pb.canReadObject(forClasses: [NSImage.self], options: nil) {
            let item = ClipItem(kind: .image, text: "Image \(Int(image.size.width))×\(Int(image.size.height))")
            // If we can't persist the image, the clip would be unpastable — drop it.
            guard let persisted = persistImage(image) else { return nil }
            item.payloadFile = persisted.file
            item.imageHash = persisted.hash
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

    /// Persist the image as a SEALED (`enc1:`-marked AES-GCM) PNG named
    /// deterministically from the SHA-256 of its PLAINTEXT bytes (`<hash>.png`),
    /// returning the relative filename and the hex hash. The hash is taken over
    /// the plaintext png BEFORE sealing, so T2's content-addressed dedup is
    /// unchanged by encryption. When a payload for that hash already exists it is
    /// reused as-is. Returns `nil` on encode/seal/write failure.
    private func persistImage(_ image: NSImage) -> (file: String, hash: String)? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        // Hash the PLAINTEXT png; encryption layers on top of this seam (hash,
        // THEN seal) so dedup is identical to the pre-encryption build.
        let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let name = "\(hash).png"
        let url = store.storeDirectory.appendingPathComponent(name)
        // Reuse an existing payload for this content rather than rewriting it.
        if FileManager.default.fileExists(atPath: url.path) { return (name, hash) }
        // Encrypt at rest: seal the PNG bytes so the on-disk file starts with the
        // `enc1:` marker, not PNG magic. Read sites (Paster / ClipCardView /
        // ContentView preview) decrypt via Crypto.open.
        guard let sealed = Crypto.seal(png), Crypto.isSealed(sealed) else { return nil }
        // Atomic write (temp-then-rename): an interrupted capture can never leave a
        // torn payload that is neither valid PNG nor a complete `enc1:` ciphertext.
        do { try sealed.write(to: url, options: .atomic) } catch { return nil }
        // Owner-only (0600): even sealed, these payloads (possibly screenshots of
        // password vaults / 2FA) must not be group/other-readable.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
        // Best-effort: also write a downsampled thumbnail next to the original so
        // the SwiftUI card body decodes a small image instead of the full-res PNG
        // on every re-evaluation (audit BL-09/H8). The full-res PNG above is kept
        // for paste; if thumbnailing fails we simply skip it and the card falls
        // back to the original. Thumbnail stem matches the payload so
        // cachedImage's `<stem>-thumb.png` convention still resolves.
        Self.writeThumbnail(from: png, to: store.storeDirectory.appendingPathComponent("\(hash)-thumb.png"))
        return (name, hash)
    }

    /// Downsample `pngData` to a thumbnail no larger than `maxPixelSize` on its
    /// longest edge, SEAL it (`enc1:` marker), and write the ciphertext to `url`.
    /// Best-effort: any failure is silently ignored.
    private static func writeThumbnail(from pngData: Data, to url: URL, maxPixelSize: Int = 512) {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil) else { return }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        // Render the thumbnail into in-memory PNG bytes first so we can seal it
        // before it hits disk (a URL-based destination would write plaintext).
        let buffer = NSMutableData()
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let dest = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, thumb, nil)
        guard CGImageDestinationFinalize(dest),
              let sealed = Crypto.seal(buffer as Data), Crypto.isSealed(sealed),
              (try? sealed.write(to: url, options: .atomic)) != nil else { return }
        // Owner-only (0600): the thumbnail is an (encrypted) derivative of the clip.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func detectKind(for string: String) -> ClipKind {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if isColor(trimmed) { return .color }
        if isLink(trimmed) { return .link }
        return .text
    }

    private static func isColor(_ s: String) -> Bool {
        // With a `#` it's unambiguously a colour.
        if s.range(of: "^#([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$", options: .regularExpression) != nil {
            return true
        }
        // Bare hex only if 6/8 chars AND it contains a digit — otherwise letter-only
        // words that happen to be valid hex ("decade", "facade", "deadbeef") would
        // wrongly classify as colours.
        if s.range(of: "^([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$", options: .regularExpression) != nil {
            return s.rangeOfCharacter(from: .decimalDigits) != nil
        }
        return false
    }

    /// True when the whole string is a single link/email. Uses `NSDataDetector`
    /// so bare domains (`github.com`, `www.apple.com`) and emails count, while a
    /// note that merely *contains* a link stays text.
    private static func isLink(_ s: String) -> Bool {
        guard !s.isEmpty, s.count < 2048 else { return false }
        if s.lowercased().hasPrefix("mailto:") { return true }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return false
        }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let match = detector.firstMatch(in: s, options: [], range: range), match.range.location == 0 else {
            return false
        }
        // Must span essentially the entire string (tolerate one trailing char).
        return match.range.length >= range.length - 1
    }
}
