import XCTest
import AppKit
@testable import Cliphoard

/// A screenshot that no web app will accept.
///
/// ⌘⇧4 puts `public.heic` — and only that — on pasteboard item 0. `public.tiff` appears in
/// `pb.types` but is a pasteboard-LEVEL flavour synthesised by the translation layer, not
/// something on the item. WebKit's `DataTransfer` reads at item level and gates JS exposure
/// on the UTI rather than the pixels, so a web app's paste handler gets `items=[]` and
/// attaches nothing. Messenger installed from Safari is `com.apple.Safari.WebApp.*` and
/// uploads via JavaScript, which is why that paste silently did nothing while the same
/// clipboard pasted fine into TextEdit.
///
/// Not an HDR bug — SDR screenshots fail identically. An earlier HDR theory was refuted by
/// measurement, and this file exists partly so nobody re-derives it.
///
/// Every test drives a NAMED pasteboard. Writing to `NSPasteboard.general` here would
/// destroy the developer's clipboard on every `swift test`, which is a defect this suite
/// had and fixed.
@MainActor
final class WebPasteTests: XCTestCase {
    private var pb: NSPasteboard!

    override func setUp() {
        super.setUp()
        pb = NSPasteboard(name: .init("io.antreas.cliphoard.tests.web.\(UUID().uuidString)"))
    }
    override func tearDown() { pb.releaseGlobally(); pb = nil; super.tearDown() }

    private func image() -> NSImage {
        let i = NSImage(size: .init(width: 16, height: 16))
        i.lockFocus(); NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 16, height: 16).fill(); i.unlockFocus()
        return i
    }

    // MARK: - The gate

    func testAScreenshotPasteboardNeedsFixing() {
        XCTAssertTrue(WebPaste.needsWebSafeCopy(
            types: ["public.heic", "public.tiff", "NeXT TIFF v4.0 pasteboard type"]),
            "this is the exact shape ⌘⇧4 produces and the exact shape web apps refuse")
    }

    func testABoardThatAlreadyHasPNGIsLeftAlone() {
        XCTAssertFalse(WebPaste.needsWebSafeCopy(types: ["public.png", "public.tiff"]))
        XCTAssertFalse(WebPaste.needsWebSafeCopy(
            types: ["Apple PNG pasteboard type", "public.tiff"]),
            "the legacy alias counts too — it always accompanies public.png on a real board, "
            + "and rewriting a board that is already fine is pure risk for no gain")
    }

    /// A browser image copy carries HTML we cannot reproduce. Those boards already carry PNG
    /// and already paste correctly, so touching them could only break something.
    func testABrowserCopyIsLeftAlone() {
        XCTAssertFalse(WebPaste.needsWebSafeCopy(
            types: ["public.png", "public.html", "public.tiff"]))
        XCTAssertFalse(WebPaste.needsWebSafeCopy(
            types: ["public.heic", "public.html", "public.tiff"]),
            "even without PNG, unreproducible HTML must veto the rewrite")
    }

    func testATornReadIsLeftAlone() {
        XCTAssertFalse(WebPaste.needsWebSafeCopy(types: []),
                       "an empty type list means the writing app has not finished publishing "
                       + "(debug.log:1817). Clearing into that window destroys what had not "
                       + "arrived yet.")
    }

    func testNonImageBoardsAreLeftAlone() {
        XCTAssertFalse(WebPaste.needsWebSafeCopy(types: ["public.utf8-plain-text"]))
    }

    // MARK: - The rewrite

    func testTheRewriteAddsPNGAndKeepsEverythingElseByteForByte() throws {
        let heic = Data("pretend-heic-bytes".utf8)
        let tiff = try XCTUnwrap(image().tiffRepresentation)
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(heic, forType: .init("public.heic"))
        item.setData(tiff, forType: .tiff)
        XCTAssertTrue(pb.writeObjects([item]))

        let before = pb.changeCount
        let outcome = WebPaste.makeWebSafe(pb, image: image(), expecting: pb.changeCount)

        guard case .rewritten = outcome else {
            return XCTFail("expected a rewrite, got \(outcome)")
        }
        XCTAssertNotNil(pb.data(forType: .png),
                        "the whole point: a web app needs public.png or it receives nothing")
        XCTAssertEqual(pb.data(forType: .init("public.heic")), heic,
                       "the original HEIC must survive BYTE-FOR-BYTE. Dropping it would "
                       + "silently downgrade every native paste of content the user "
                       + "deliberately captured.")
        XCTAssertEqual(pb.data(forType: .tiff), tiff, "the TIFF must survive byte-for-byte")
        XCTAssertGreaterThan(pb.changeCount, before,
                             "taking ownership necessarily bumps the count; poll() must "
                             + "suppress it or it recaptures its own write")
    }

    func testAnAlreadyPasteableBoardIsNotTouched() throws {
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(try XCTUnwrap(image().tiffRepresentation), forType: .tiff)
        item.setData(Data("png".utf8), forType: .png)
        XCTAssertTrue(pb.writeObjects([item]))
        let before = pb.changeCount

        XCTAssertEqual(WebPaste.makeWebSafe(pb, image: image(), expecting: pb.changeCount), .notNeeded)
        XCTAssertEqual(pb.changeCount, before, "an untouched board must not change count")
        XCTAssertEqual(pb.data(forType: .png), Data("png".utf8), "and must keep its own PNG")
    }

    /// The PNG must be the web-safe form, not merely any PNG.
    func testTheGeneratedPNGIsAnEightBitSRGBPNG() throws {
        let png = try XCTUnwrap(WebPaste.webSafePNG(from: image()))
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "PNG magic")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(rep.bitsPerSample, 8,
                       "persistImage's PNG faithfully preserves a 16-bit source, which "
                       + "pastes but is twice the bytes over IPC and then a web upload")
    }

    // MARK: - Ordering, which is the safety argument

    /// Nothing may be cleared until every original byte is in hand. `Paster` had the opposite
    /// order and wiped the user's clipboard whenever a payload failed to load — a defect that
    /// outlived the audit naming it (AUDIT.md:164). Pinned here so it cannot come back.
    func testTheBoardIsNotClearedBeforeTheReplacementIsBuilt() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Cliphoard/Clipboard/WebPaste.swift"),
            encoding: .utf8)
        guard let start = source.range(of: "static func makeWebSafe(") else {
            return XCTFail("makeWebSafe was renamed — move this test with it")
        }
        let body = String(source[start.upperBound...])
        guard let clear = body.range(of: "pb.clearContents()"),
              let salvage = body.range(of: "salvaged.append("),
              let build = body.range(of: "item.setData(png, forType: .png)") else {
            return XCTFail("makeWebSafe no longer salvages, builds and clears")
        }
        XCTAssertLessThan(salvage.lowerBound, clear.lowerBound,
                          "the pasteboard is cleared BEFORE the originals are salvaged — a "
                          + "failure now destroys content that can never be recovered")
        XCTAssertLessThan(build.lowerBound, clear.lowerBound,
                          "the pasteboard is cleared before the replacement item is complete")
    }

    /// A failed write must put the original back, not leave the user with nothing.
    func testAFailedWriteRestoresRatherThanLeavingItEmpty() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Cliphoard/Clipboard/WebPaste.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains("case restored"),
                      "there must be a restore path: we hold every salvaged byte, so a "
                      + "failed write is recoverable and leaving the clipboard empty is not "
                      + "an acceptable outcome")
        XCTAssertTrue(source.contains("case lost"),
                      "and the unrecoverable case must be distinguishable, so it can be "
                      + "logged loudly rather than passing as success")
    }
}

/// Legacy pasteboard names are not UTIs and `setData` rejects them. They must be skipped on
/// write — not passed through to log an error on every single screenshot.
@MainActor
final class WebPasteLegacyTypeTests: XCTestCase {
    func testLegacyNeXTNamesAreNotWritten() {
        XCTAssertFalse(WebPaste.isWritableUTI(.init("NeXT TIFF v4.0 pasteboard type")),
                       "this name reaches setData as an invalid UTI and is refused; macOS "
                       + "re-synthesises the alias from public.tiff regardless")
        XCTAssertFalse(WebPaste.isWritableUTI(.init("Apple PNG pasteboard type")))
    }
    func testRealUTIsAreWritten() {
        XCTAssertTrue(WebPaste.isWritableUTI(.init("public.heic")))
        XCTAssertTrue(WebPaste.isWritableUTI(.init("public.tiff")))
        XCTAssertTrue(WebPaste.isWritableUTI(.png))
    }
}

/// The gate and the salvage must read the ITEM, not the pasteboard.
///
/// `pb.types` is a superset: the translation layer synthesises flavours on demand. Two things
/// go wrong if you trust it. A synthesised PNG would report "already pasteable" for a board
/// whose item carries only heic — masking the very bug this fixes, because WebKit reads at
/// item level. And reading a synthesised `public.tiff` MATERIALISES it: measured at 12.5 MB
/// from a 31 KB item, which would then be written back on every screenshot.
@MainActor
final class WebPasteItemLevelTests: XCTestCase {
    private var pb: NSPasteboard!
    override func setUp() {
        super.setUp()
        pb = NSPasteboard(name: .init("io.antreas.cliphoard.tests.item.\(UUID().uuidString)"))
    }
    override func tearDown() { pb.releaseGlobally(); pb = nil; super.tearDown() }

    /// A PNG-only item makes the pasteboard advertise TIFF it does not itself hold. If the
    /// implementation salvaged the pasteboard's list it would copy that phantom.
    func testThePasteboardAdvertisesMoreThanTheItemHolds() throws {
        let img = NSImage(size: .init(width: 24, height: 24))
        img.lockFocus(); NSColor.orange.setFill()
        NSRect(x: 0, y: 0, width: 24, height: 24).fill(); img.unlockFocus()
        let png = try XCTUnwrap(
            NSBitmapImageRep(data: try XCTUnwrap(img.tiffRepresentation))?
                .representation(using: .png, properties: [:]))

        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        XCTAssertTrue(pb.writeObjects([item]))

        XCTAssertEqual(pb.pasteboardItems?.first?.types.map(\.rawValue), ["public.png"],
                       "the item holds exactly what was written")
        XCTAssertTrue((pb.types ?? []).contains(.tiff),
                      "yet the pasteboard advertises a TIFF nobody wrote — synthesised on "
                      + "demand. Salvaging at this level copies phantoms and forces their "
                      + "materialisation.")
    }

    func testSalvageReadsTheItemNotThePasteboard() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Cliphoard/Clipboard/WebPaste.swift"),
            encoding: .utf8)
        guard let start = source.range(of: "static func makeWebSafe(") else {
            return XCTFail("makeWebSafe was renamed")
        }
        let body = String(source[start.upperBound...])
        XCTAssertTrue(body.contains("pb.pasteboardItems"),
                      "the gate and salvage must read ITEMS; reading pb.types lets a "
                      + "synthesised PNG mask the bug and forces a 12.5MB TIFF expansion")
        XCTAssertTrue(body.contains("for item in items"),
                      "and it must walk EVERY item — salvaging only the first destroyed "
                      + "items 1..n, which is worse than the bug being fixed")
        guard let salvage = body.range(of: "salvaged.append(") else {
            return XCTFail("no salvage loop")
        }
        // Strip comment lines first. The doc comment above the salvage loop EXPLAINS the
        // pasteboard-level read it is warning against, and a substring search cannot tell
        // prose from a call — the trap ForgetOrderingTests documents, hit again here.
        let upToSalvage = String(body[..<salvage.lowerBound])
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertFalse(upToSalvage.contains("pb.data(forType:"),
                       "salvage still reads through the PASTEBOARD, which materialises "
                       + "synthesised flavours it should never have touched")
    }
}

/// What survives a rewrite — pinned, because the first version of this code claimed "all
/// types verbatim" and that was measurably false.
///
/// Types on the ITEM survive byte-for-byte. Pasteboard-level flavours do not: they were
/// synthesised all along, and afterwards they are re-synthesised from whatever is now on the
/// item. Measured on an HDR screenshot, `public.tiff` went from 12,583,842 bytes of 16-bit
/// Display P3 to 3,186,516 bytes of 8-bit sRGB, because it is now derived from the PNG we
/// added. The original survives as `public.heic` for anything that asks for it.
@MainActor
final class WebPasteFidelityTests: XCTestCase {
    func testItemTypesSurviveByteForByteAndPNGIsAdded() throws {
        let pb = NSPasteboard(name: .init("io.antreas.cliphoard.tests.fid.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }

        // A screenshot's shape: ONE item whose only flavour is heic.
        let heic = Data((0..<4096).map { UInt8($0 % 251) })
        pb.clearContents()
        let seed = NSPasteboardItem()
        seed.setData(heic, forType: .init("public.heic"))
        XCTAssertTrue(pb.writeObjects([seed]))
        XCTAssertEqual(pb.pasteboardItems?.first?.types.map(\.rawValue), ["public.heic"])

        let img = NSImage(size: .init(width: 12, height: 12))
        img.lockFocus(); NSColor.systemIndigo.setFill()
        NSRect(x: 0, y: 0, width: 12, height: 12).fill(); img.unlockFocus()
        guard case .rewritten = WebPaste.makeWebSafe(pb, image: img, expecting: pb.changeCount) else {
            return XCTFail("expected a rewrite")
        }

        let after = try XCTUnwrap(pb.pasteboardItems?.first)
        XCTAssertEqual(after.data(forType: .init("public.heic")), heic,
                       "the ORIGINAL heic must survive byte-for-byte — it is the only copy "
                       + "of the wide-gamut original left once tiff is re-derived from PNG")
        XCTAssertNotNil(after.data(forType: .png),
                        "and the PNG must be on the ITEM, since WebKit reads at item level")
    }

    /// The doc must not re-acquire the overstatement it was corrected for.
    func testTheDocDoesNotClaimEverythingSurvivesVerbatim() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Cliphoard/Clipboard/WebPaste.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains("FIDELITY COST"),
                      "the fidelity trade must stay documented where the code lives; it was "
                      + "found by a verifier after the original claim shipped, not before")
        XCTAssertTrue(source.contains("re-synthesised"),
                      "the doc must say pasteboard-level flavours are re-derived, not kept")
    }
}

/// Defects found by a blind verifier AFTER the fix was pushed. Each is reachable, and the
/// first was data loss strictly worse than the bug being fixed.
@MainActor
final class WebPasteHazardTests: XCTestCase {
    private var pb: NSPasteboard!
    override func setUp() {
        super.setUp()
        pb = NSPasteboard(name: .init("io.antreas.cliphoard.tests.hz.\(UUID().uuidString)"))
    }
    override func tearDown() { pb.releaseGlobally(); pb = nil; super.tearDown() }

    private func img() -> NSImage {
        let i = NSImage(size: .init(width: 10, height: 10))
        i.lockFocus(); NSColor.systemBrown.setFill()
        NSRect(x: 0, y: 0, width: 10, height: 10).fill(); i.unlockFocus()
        return i
    }

    /// The first version salvaged `pasteboardItems.first` and wrote ONE item back, deleting
    /// items 1..n. A pasteboard routinely holds several (a multi-file copy, an app offering
    /// alternatives), and the gate passes on such a board — so Cliphoard could destroy a
    /// user's clipboard where before it merely observed.
    func testEveryItemSurvivesNotJustTheFirst() throws {
        pb.clearContents()
        let a = NSPasteboardItem(); a.setData(Data("heic-a".utf8), forType: .init("public.heic"))
        let b = NSPasteboardItem(); b.setData(Data("second".utf8), forType: .string)
        let c = NSPasteboardItem(); c.setData(Data("third".utf8), forType: .string)
        XCTAssertTrue(pb.writeObjects([a, b, c]))
        XCTAssertEqual(pb.pasteboardItems?.count, 3)

        guard case .rewritten = WebPaste.makeWebSafe(pb, image: img(), expecting: pb.changeCount) else {
            return XCTFail("expected a rewrite")
        }
        XCTAssertEqual(pb.pasteboardItems?.count, 3,
                       "items 1..n were destroyed — the user's other clipboard entries are "
                       + "gone, which is worse than the paste bug this code exists to fix")
        XCTAssertEqual(pb.pasteboardItems?[1].data(forType: .string), Data("second".utf8))
        XCTAssertEqual(pb.pasteboardItems?[2].data(forType: .string), Data("third".utf8))
        XCTAssertNotNil(pb.pasteboardItems?[0].data(forType: .png),
                        "and the PNG goes on item 0, where WebKit reads it")
    }

    /// Salvage plus render takes 113–258ms depending on size. A copy landing in that window
    /// must not be overwritten by the older screenshot.
    func testACopyArrivingMidFlightIsNotClobbered() throws {
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(Data("heic".utf8), forType: .init("public.heic"))
        XCTAssertTrue(pb.writeObjects([item]))

        // Simulate the race: the caller's expectation is already stale.
        let stale = pb.changeCount - 1
        XCTAssertEqual(WebPaste.makeWebSafe(pb, image: img(), expecting: stale), .movedOn,
                       "the board moved between the caller's check and the write; rewriting "
                       + "would silently replace whatever the user just copied")
        XCTAssertEqual(pb.pasteboardItems?.first?.data(forType: .init("public.heic")),
                       Data("heic".utf8), "and the board must be left exactly as found")
        XCTAssertNil(pb.data(forType: .png), "nothing written on the abandoned path")
    }

    /// The recovery paths must record the changeCount their own write produced, or the next
    /// poll sees a changed board and captures the restored content as a duplicate clip.
    func testRecoveryPathsUpdateTheMonitorsBookkeeping() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Cliphoard/Clipboard/ClipboardMonitor.swift"),
            encoding: .utf8)
        for arm in ["case .restored:", "case .lost:"] {
            guard let start = source.range(of: arm) else {
                return XCTFail("\(arm) is gone — move this test with it")
            }
            let body = String(source[start.upperBound...].prefix(500))
            XCTAssertTrue(body.contains("lastChangeCount = pb.changeCount"),
                          "\(arm) does not record the changeCount its restore produced, so "
                          + "the next tick re-captures the restored board as a new clip")
        }
    }
}
