import AppKit

/// Making a screenshot pasteable into web apps.
///
/// A screenshot taken with ⌘⇧4 lands on the pasteboard with `public.heic` — and ONLY that —
/// on pasteboard item 0. `public.tiff` shows up in `pb.types` but is a pasteboard-LEVEL
/// flavour synthesised by the translation layer; it is not on the item.
///
/// WebKit's `DataTransfer` reads at ITEM level and gates JS exposure on the UTI, not on the
/// pixels: `public.png` is on its allowlist, `public.heic` is not. So a web app's paste
/// handler receives `items=[]` and attaches nothing. Safari Web Apps are the common case —
/// Messenger installed from Safari is `com.apple.Safari.WebApp.*` — and their compose boxes
/// upload via JavaScript, so the paste silently does nothing.
///
/// Measured, real ⌘V into a page logging `e.clipboardData`:
///
///     real screenshot (item 0 = heic only)  ->  items=[]
///     any board whose item 0 carries png    ->  items=[file:image/png]
///
/// Note this is NOT about HDR. SDR screenshots fail identically; an earlier HDR theory was
/// refuted by measurement. It is purely about which UTI sits on the item.
///
/// WHY THIS REWRITES RATHER THAN APPENDS. The obvious fix — `addTypes([.png])` — is
/// impossible: a process that does not own the pasteboard cannot add to it. Measured across
/// three separate processes, with the writing process exited first:
///
///     addTypes([.png], owner: nil)  ->  -1        (not even the documented 0)
///     setData(png, forType: .png)   ->  false
///     changeCount, types, bytes     ->  all unchanged
///
/// Controls isolate the cause as OWNERSHIP, not the writer's death: the same calls succeed
/// when we own the board. The Pasteboard Manager underneath says so plainly —
/// HIServices/Pasteboard.h: `notPasteboardOwnerErr = -25135 /* client did not clear the
/// pasteboard */`, and "PasteboardClear must be called before the pasteboard can be
/// modified." Nothing is logged when it fails, so a naive implementation would have shipped
/// as a silent no-op.
///
/// Taking ownership therefore means clearing, and clearing means we must be able to put
/// everything back. Hence: salvage every byte first, and never clear until the replacement
/// item is fully built.
@MainActor
enum WebPaste {
    /// OPT-IN. Default OFF, deliberately.
    ///
    /// Everything else Cliphoard does to the clipboard is passive: it reads, and it writes
    /// only when you pick a clip. This is the one feature that reaches out and REWRITES what
    /// another app put there, and macOS offers no gentler way — adding a flavour requires
    /// owning the pasteboard, and owning it requires `clearContents()` (HIServices
    /// Pasteboard.h: `notPasteboardOwnerErr = -25135 /* client did not clear the pasteboard
    /// */`). Measured: `addTypes` on a board we do not own returns -1 and `setData` returns
    /// false, silently.
    ///
    /// So the trade is real and the user should make it rather than inherit it: apps asking
    /// for `public.tiff` receive an 8-bit sRGB image where they previously received 16-bit
    /// Display P3, and pasteboard-owner provenance shows Cliphoard rather than the app that
    /// took the screenshot. Off by default keeps "Cliphoard only observes your clipboard"
    /// true for anyone who has not asked otherwise.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "webSafeScreenshots") }   // absent => false
        set { UserDefaults.standard.set(newValue, forKey: "webSafeScreenshots") }
    }

    /// The legacy alias always accompanies `public.png` on a real board; treat either as
    /// "already pasteable" so we never rewrite a board that does not need it.
    static let pngTypes: Set<String> = ["public.png", "Apple PNG pasteboard type"]

    /// Types we cannot faithfully reproduce, so their presence forbids a rewrite. A browser
    /// image copy carries `public.html`; clobbering that would break pasting into rich-text
    /// targets. These boards already carry PNG anyway, so the gate below is belt-and-braces.
    static let unreproducible: Set<String> = [
        "public.html", "Apple HTML pasteboard type",
        "com.apple.flat-rtfd", "NeXT RTFD pasteboard type",
        "com.apple.webarchive", "Apple Web Archive pasteboard type",
        "public.rtf", "NeXT Rich Text Format v1.0 pasteboard type",
        "public.file-url", "public.url",
    ]

    /// Whether this pasteboard is one a web app would fail to paste, and that we can fix.
    static func needsWebSafeCopy(types: [String]) -> Bool {
        guard !types.isEmpty else { return false }                 // torn read; see poll()
        guard !types.contains(where: pngTypes.contains) else { return false }   // already fine
        guard !types.contains(where: unreproducible.contains) else { return false }
        return types.contains("public.heic") || types.contains("public.tiff")
    }

    /// An 8-bit sRGB PNG. `persistImage`'s PNG faithfully preserves a 16-bit Display P3
    /// source (measured: 30,830 bytes vs 15,615 for sRGB), which pastes correctly but is
    /// twice the size to cross pasteboard IPC and then a web upload. Both forms were
    /// verified to paste; this is the cheaper one.
    nonisolated static func webSafePNG(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cg = rep.cgImage,
              let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: cg.width, height: cg.height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard let flat = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: flat).representation(using: .png, properties: [:])
    }

    enum Outcome: Equatable {
        case notNeeded            // gate said no; pasteboard untouched
        case unsalvageable        // a declared type read nil; pasteboard untouched
        case rewritten(Int)       // success; the post-write changeCount
        case restored(Int)        // write failed; original put back, at this changeCount
        case lost                 // write failed AND restore failed — must be logged loudly
        case movedOn              // the user copied again mid-flight; board left untouched
    }

    /// Legacy NeXT-era pasteboard names are not valid UTIs, so `setData` refuses them
    /// ("'NeXT TIFF v4.0 pasteboard type' is not a valid UTI string"). They are aliases the
    /// translation layer re-synthesises from the modern type anyway — the rewritten board
    /// still advertises them — so they are salvaged for the abort check but skipped when
    /// writing, rather than logged as an error on every screenshot.
    static func isWritableUTI(_ type: NSPasteboard.PasteboardType) -> Bool {
        !type.rawValue.contains(" ")
    }

    /// Salvage the item's types, then rewrite the board as ONE item carrying them plus a
    /// web-safe PNG.
    ///
    /// WHAT ACTUALLY SURVIVES, measured rather than assumed — an earlier version of this
    /// comment claimed "all types verbatim" and that was wrong:
    ///
    ///   * Types ON THE ITEM survive byte-for-byte. For a screenshot that is `public.heic`,
    ///     so an app that asks for HEIC still gets the original bytes.
    ///   * Pasteboard-level flavours are NOT preserved. They were always synthesised by the
    ///     translation layer, and afterwards they are re-synthesised from what is now on the
    ///     item. Since the item gains an 8-bit sRGB PNG, `public.tiff` is derived from that.
    ///
    /// That is a REAL FIDELITY COST and it should not be discovered by surprise. Measured on
    /// an HDR screenshot:
    ///
    ///     before   public.tiff  12,583,842 bytes  16-bit  Display P3
    ///     after    public.tiff   3,186,516 bytes   8-bit  sRGB
    ///
    /// So an app requesting TIFF — Preview and Keynote typically do — receives an SDR image
    /// where it previously received a wide-gamut one. The original remains available as
    /// `public.heic` for anything that asks. The trade is deliberate: without it, pasting a
    /// screenshot into any browser-based compose box silently does nothing at all, which is
    /// the bug this exists to fix.
    ///
    /// ORDER IS THE WHOLE SAFETY ARGUMENT: nothing is cleared until every original byte is in
    /// hand and the replacement item is fully built. `Paster` had the opposite order and it
    /// wiped the user's clipboard whenever a payload failed to load; that bug outlived the
    /// audit that named it (AUDIT.md:164). Not repeating it here.
    /// Render off the main actor, then apply on it.
    ///
    /// The render is the expensive half and it is superlinear: 51ms at 1200x800, 268ms at
    /// 2880x1800, and 1200ms at 6016x3384. Running it inline on the @MainActor poll path
    /// froze the UI for about a second on every full-screen grab on a 5K/6K display. It is
    /// pure — no pasteboard access — so it moves off freely.
    ///
    /// A longer render widens the gap between deciding to act and acting, which is safe by
    /// construction: `apply` re-checks `expecting` as the statement immediately before
    /// `clearContents()`, so a board that moved meanwhile is left untouched.
    nonisolated static func renderWebSafePNG(from image: NSImage) async -> Data? {
        await Task.detached(priority: .userInitiated) { webSafePNG(from: image) }.value
    }

    /// Salvage and apply using a PNG rendered elsewhere — the path `poll()` uses, so the
    /// superlinear render never runs on the main actor.
    @discardableResult
    static func makeWebSafe(_ pb: NSPasteboard, png: Data, expecting: Int) -> Outcome {
        guard let items = pb.pasteboardItems, let first = items.first else { return .notNeeded }
        guard needsWebSafeCopy(types: first.types.map(\.rawValue)) else { return .notNeeded }
        var salvaged: [[(NSPasteboard.PasteboardType, Data)]] = []
        for item in items {
            var flavours: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                guard let data = item.data(forType: type) else { return .unsalvageable }
                flavours.append((type, data))
            }
            salvaged.append(flavours)
        }
        return apply(pb, png: png, salvaged: salvaged, expecting: expecting)
    }

    @discardableResult
    static func makeWebSafe(_ pb: NSPasteboard, image: NSImage, expecting: Int) -> Outcome {
        // EVERY item, not just the first.
        //
        // An earlier version salvaged `pasteboardItems.first` and then wrote a single item
        // back — which DESTROYED items 1..n. A pasteboard can hold many items (a multi-file
        // copy, an app offering alternatives), the gate passes on such a board, and the
        // pre-change behaviour was merely to observe. Deleting the user's clipboard is a
        // strictly worse outcome than the bug being fixed, and no test covered item count.
        guard let items = pb.pasteboardItems, let first = items.first else { return .notNeeded }
        guard needsWebSafeCopy(types: first.types.map(\.rawValue)) else { return .notNeeded }

        // Salvage FIRST, every item. A nil read means a live promise we cannot reproduce.
        var salvaged: [[(NSPasteboard.PasteboardType, Data)]] = []
        for item in items {
            var flavours: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                guard let data = item.data(forType: type) else { return .unsalvageable }
                flavours.append((type, data))
            }
            salvaged.append(flavours)
        }
        guard let png = webSafePNG(from: image) else { return .unsalvageable }
        return apply(pb, png: png, salvaged: salvaged, expecting: expecting)
    }

    /// The pasteboard half: cheap, main-actor, and re-checks `expecting` immediately before
    /// clearing. Split out so the expensive render can happen off the main actor first.
    private static func apply(_ pb: NSPasteboard, png: Data,
                              salvaged: [[(NSPasteboard.PasteboardType, Data)]],
                              expecting: Int) -> Outcome {

        func rebuild(addingPNG: Bool) -> [NSPasteboardItem] {
            salvaged.enumerated().map { index, flavours in
                let item = NSPasteboardItem()
                var dropped: [String] = []
                for (type, data) in flavours where isWritableUTI(type) {
                    if !item.setData(data, forType: type) { dropped.append(type.rawValue) }
                }
                if addingPNG && index == 0 { _ = item.setData(png, forType: .png) }
                if !dropped.isEmpty {
                    NSLog("Cliphoard: pasteboard flavours dropped during rewrite: "
                          + dropped.joined(separator: ","))
                }
                return item
            }
        }

        let replacement = rebuild(addingPNG: true)
        guard replacement.first?.data(forType: .png) != nil else { return .unsalvageable }

        // LAST possible moment. Salvage and render together take long enough that a copy can
        // land in between; overwriting it with the older screenshot would be its own data
        // loss. If the board moved, leave it entirely alone.
        guard pb.changeCount == expecting else { return .movedOn }

        // `clearContents()` RETURNS the new changeCount, and writeObjects rides that same
        // change (measured delta +1). Use it rather than re-reading the board afterwards: a
        // user copy landing between writeObjects returning and a fresh read would hand back
        // THEIR count, which the caller stores as `ignoreChangeCount` — discarding their clip
        // as "our own paste". That is the bug class the suppressNextChange +1 prediction fix
        // removed; do not reintroduce it here.
        let mine = pb.clearContents()
        if pb.writeObjects(replacement) { return .rewritten(mine) }

        let restoredCount = pb.clearContents()
        return pb.writeObjects(rebuild(addingPNG: false)) ? .restored(restoredCount) : .lost
    }
}
