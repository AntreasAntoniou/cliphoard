import AppKit

/// Audible feedback when a clip is captured — a subtle tick, like Paste.
@MainActor
enum Feedback {
    static var soundEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "soundEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "soundEnabled") }
    }

    /// Play the capture tick. A fresh `NSSound` each time so rapid copies
    /// don't cut one another off.
    static func playCapture() {
        guard soundEnabled else { return }
        if let sound = NSSound(named: NSSound.Name("Tink")) {
            sound.volume = 0.4
            sound.play()
        } else {
            NSSound.beep()
        }
    }
}

/// Lightweight append-only diagnostics, written next to the history so we can
/// inspect exactly what the pasteboard poll saw for a given copy.
enum DebugLog {
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "debugLog") as? Bool ?? false
    }

    private static let url: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Ditto/debug.log")
    }()

    static func write(_ message: String) {
        guard enabled else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
