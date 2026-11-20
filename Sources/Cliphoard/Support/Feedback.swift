import AppKit

/// Audible feedback for clipboard actions.
@MainActor
enum Feedback {
    private static let defaultPasteSound = "Pop"

    static var soundEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "soundEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "soundEnabled") }
    }

    /// Name of the chosen capture sound (a built-in macOS system sound).
    static var soundName: String {
        get { UserDefaults.standard.string(forKey: "soundName") ?? "Frog" }
        set { UserDefaults.standard.set(newValue, forKey: "soundName") }
    }

    static var pasteSoundEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "pasteSoundEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "pasteSoundEnabled") }
    }

    static var pasteSoundName: String {
        get { UserDefaults.standard.string(forKey: "pasteSoundName") ?? defaultPasteSound }
        set { UserDefaults.standard.set(newValue, forKey: "pasteSoundName") }
    }

    /// The built-in system sounds available to pick from.
    static let availableSounds = [
        "Tink", "Pop", "Glass", "Morse", "Ping", "Bottle", "Frog",
        "Funk", "Hero", "Purr", "Submarine", "Sosumi", "Blow", "Basso"
    ]

    /// Play a specific sound once, including for previews.
    static func play(named name: String) {
        if let sound = NSSound(named: NSSound.Name(name)) {
            sound.volume = 0.4
            sound.play()
        } else {
            NSSound.beep()
        }
    }

    /// Play the capture tick. A fresh `NSSound` each time so rapid copies
    /// don't cut one another off.
    static func playCapture() {
        guard soundEnabled else { return }
        play(named: soundName)
    }

    static func playPaste() {
        guard let name = pasteSoundToPlay(in: .standard) else { return }
        play(named: name)
    }

    static func pasteSoundToPlay(in defaults: UserDefaults) -> String? {
        guard defaults.bool(forKey: "pasteSoundEnabled") else { return nil }
        return defaults.string(forKey: "pasteSoundName") ?? defaultPasteSound
    }

    /// A failed pick. The system beep deliberately, NOT `soundName` — the capture tick is
    /// the sound of success, and a failure that sounds identical to a success is how a
    /// silent no-op passes for a working paste.
    static func playFailure() {
        guard soundEnabled else { return }
        NSSound.beep()
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
        let dir = support.appendingPathComponent("Cliphoard")
        // The directory was never created, so every write silently failed and the debug
        // log wrote nowhere — a diagnostic channel that quietly does nothing is worse than
        // no channel, because it makes absence of evidence look like evidence of absence.
        // 0700 to match the store directory: this file records what the app was doing.
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("debug.log")
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
