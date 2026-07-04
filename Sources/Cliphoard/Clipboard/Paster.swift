import AppKit
import Carbon.HIToolbox

/// Writes a clip back to the system pasteboard and (optionally) issues a paste
/// into whichever app was frontmost before Cliphoard opened.
@MainActor
enum Paster {
    /// Place the clip on the general pasteboard.
    ///
    /// - Parameter plain: when `true`, omit the RTF representation for text
    ///   clips so only the plain string is written ("paste as plain text").
    ///   Image and file clips are unaffected. Defaults to `false`, preserving
    ///   the rich-text behavior.
    static func writeToPasteboard(_ item: ClipItem, store: ClipStore, plain: Bool = false) {
        let pb = NSPasteboard.general
        pb.clearContents()

        switch item.kind {
        case .image:
            // Payloads are encrypted at rest (enc1: marker): read + decrypt.
            if let file = item.payloadFile,
               let stored = try? Data(contentsOf: store.storeDirectory.appendingPathComponent(file)),
               let png = Crypto.open(stored),
               let image = NSImage(data: png) {
                pb.writeObjects([image])
            }
        case .file:
            if let path = item.filePath {
                pb.writeObjects([URL(fileURLWithPath: path) as NSURL])
            }
        default:
            if !plain, let rtf = item.rtf {
                pb.setData(rtf, forType: .rtf)
            }
            pb.setString(item.text, forType: .string)
        }
    }

    /// Activate the previously-frontmost app and simulate ⌘V.
    static func paste(into app: NSRunningApplication?) {
        app?.activate(options: [])
        // Small delay so activation completes before the keystroke lands.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            sendCommandV()
        }
    }

    private static func sendCommandV() {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
        let vKey: CGKeyCode = 0x09 // 'v'
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
