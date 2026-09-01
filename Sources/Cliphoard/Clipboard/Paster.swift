import AppKit
import Carbon.HIToolbox

/// Writes a clip back to the system pasteboard and (optionally) issues a paste
/// into whichever app was frontmost before Cliphoard opened.
@MainActor
enum Paster {
    /// What `writeToPasteboard` actually did.
    ///
    /// A `Bool` could not carry the distinction the user-facing message depends on. AppKit
    /// requires `clearContents()` before a type can be declared, so a write that fails at
    /// the PASTEBOARD has already emptied it, while one that fails while LOADING the payload
    /// never touched it. Telling the user "your clipboard is unchanged" is true in the
    /// second case and a lie in the first.
    enum WriteOutcome: Equatable {
        /// The clip is on the pasteboard.
        case wrote
        /// The payload could not be read or decrypted. The pasteboard was never touched.
        case payloadUnreadable
        /// The payload was fine but the pasteboard refused the write. It has been cleared.
        case pasteboardRefused

        var succeeded: Bool { self == .wrote }
    }

    /// Place the clip on the pasteboard. Returns whether anything was actually written.
    ///
    /// **Build first, clear last.** This used to open with `clearContents()` and only then
    /// try to load the payload — filename, file read, decrypt, `NSImage(data:)` — any link
    /// of which can fail. On failure it wrote nothing, so picking a clip whose payload had
    /// gone missing or become undecryptable destroyed whatever the user had on the
    /// clipboard and put nothing back. Not a failed paste: a silent theft of unrelated
    /// content. `AUDIT.md:164` named it ("a silent no-op paste") and it outlived the audit
    /// that named it, because nothing executable pinned it. `PasterSafetyTests` does now.
    ///
    /// The realistic trigger is a payload sealed under a key this process can no longer
    /// reach — the clip still lists and still looks pastable.
    ///
    /// The outcome is not decoration: `AppDelegate` arms `suppressOwnWrite()` and
    /// `markUsed` off it, and decides whether to keep the panel open. Arming on a write that
    /// never happened leaves the mark to be matched by the user's NEXT real copy, which
    /// `poll()` then discards as our own paste.
    ///
    /// - Parameters:
    ///   - plain: when `true`, omit the RTF representation for text clips so only the plain
    ///     string is written ("paste as plain text"). Image and file clips are unaffected.
    ///   - pb: the destination pasteboard. Defaults to `.general`; tests pass a named one so
    ///     a test run never clobbers the developer's own clipboard.
    @discardableResult
    static func writeToPasteboard(_ item: ClipItem, store: ClipStore,
                                  plain: Bool = false,
                                  to pb: NSPasteboard = .general) -> WriteOutcome {
        // Everything below is prepared BEFORE the pasteboard is touched.
        switch item.kind {
        case .image:
            // Payloads are encrypted at rest (enc1: marker): read + decrypt.
            guard let file = item.payloadFile,
                  let stored = try? Data(contentsOf: store.storeDirectory.appendingPathComponent(file)),
                  let png = Crypto.open(stored),
                  let image = NSImage(data: png)
            else { return .payloadUnreadable }

            // ONE pasteboard item carrying both flavours.
            //
            // `writeObjects` ALWAYS APPENDS a new item, and `dataForType:` resolves against
            // the FIRST item carrying the type — so mixing `writeObjects([NSImage])` with
            // `setData` yields two items whose representations can disagree, with nothing in
            // the API surfacing the split. Build the item, then write it once.
            //
            // PNG is offered alongside TIFF because `writeObjects([NSImage])` declares TIFF
            // and nothing else, which left Cliphoard's own output as flavour-poor as the
            // pasteboards it exists to rescue. The PNG bytes are already in hand.
            let pbItem = NSPasteboardItem()
            pbItem.setData(png, forType: .png)
            if let tiff = image.tiffRepresentation { pbItem.setData(tiff, forType: .tiff) }
            pb.clearContents()
            return pb.writeObjects([pbItem]) ? .wrote : .pasteboardRefused

        case .file:
            guard let path = item.filePath else { return .payloadUnreadable }
            pb.clearContents()
            return pb.writeObjects([URL(fileURLWithPath: path) as NSURL])
                ? .wrote : .pasteboardRefused

        default:
            pb.clearContents()
            // String FIRST, then RTF. The other order let `setData(rtf:)` succeed and
            // `setString` fail, returning `.pasteboardRefused` — "nothing was written" —
            // while the pasteboard HAD changed. `AppDelegate` would then skip
            // `suppressOwnWrite()`, so `poll()` would capture Cliphoard's own RTF write back
            // as a brand-new clip. Unreachable in practice (`item.text` is non-optional so
            // `setString` does not realistically fail), but the outcome must mean the same
            // thing in every branch or the caller cannot trust it.
            guard pb.setString(item.text, forType: .string) else { return .pasteboardRefused }
            if !plain, let rtf = item.rtf {
                pb.setData(rtf, forType: .rtf)
            }
            return .wrote
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
