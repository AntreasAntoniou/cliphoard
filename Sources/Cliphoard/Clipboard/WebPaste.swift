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
    static func webSafePNG(from image: NSImage) -> Data? {
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
        case restored             // write failed and the original was put back
        case lost                 // write failed AND restore failed — must be logged loudly
    }

    /// Legacy NeXT-era pasteboard names are not valid UTIs, so `setData` refuses them
    /// ("'NeXT TIFF v4.0 pasteboard type' is not a valid UTI string"). They are aliases the
    /// translation layer re-synthesises from the modern type anyway — the rewritten board
    /// still advertises them — so they are salvaged for the abort check but skipped when
    /// writing, rather than logged as an error on every screenshot.
    static func isWritableUTI(_ type: NSPasteboard.PasteboardType) -> Bool {
        !type.rawValue.contains(" ")
    }

    /// Salvage every declared type, then rewrite the board as ONE item carrying all of them
    /// verbatim plus a web-safe PNG.
    ///
    /// ORDER IS THE WHOLE SAFETY ARGUMENT: nothing is cleared until every original byte is in
    /// hand and the replacement item is fully built. `Paster` had the opposite order and it
    /// wiped the user's clipboard whenever a payload failed to load; that bug outlived the
    /// audit that named it (AUDIT.md:164). Not repeating it here.
    @discardableResult
    static func makeWebSafe(_ pb: NSPasteboard, image: NSImage) -> Outcome {
        let declared = pb.types ?? []
        guard needsWebSafeCopy(types: declared.map(\.rawValue)) else { return .notNeeded }

        // Salvage FIRST. A nil read means a live promise we cannot reproduce — abort whole.
        var salvaged: [(NSPasteboard.PasteboardType, Data)] = []
        for type in declared {
            guard let data = pb.data(forType: type) else { return .unsalvageable }
            salvaged.append((type, data))
        }
        guard let png = webSafePNG(from: image) else { return .unsalvageable }

        let item = NSPasteboardItem()
        for (type, data) in salvaged where isWritableUTI(type) { item.setData(data, forType: type) }
        item.setData(png, forType: .png)

        pb.clearContents()
        if pb.writeObjects([item]) { return .rewritten(pb.changeCount) }

        // Cleared but could not write: put the original back rather than leave them empty.
        let fallback = NSPasteboardItem()
        for (type, data) in salvaged where isWritableUTI(type) { fallback.setData(data, forType: type) }
        pb.clearContents()
        return pb.writeObjects([fallback]) ? .restored : .lost
    }
}
