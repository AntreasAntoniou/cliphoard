import XCTest
import AppKit
import SwiftUI
@testable import Cliphoard

/// A card's CONTENT may never displace the card's own CHROME.
///
/// Two independent breaches of that rule shipped, and they share a shape: a child
/// that reports a size larger than the slot it was offered. A flexible frame
/// (`maxWidth/maxHeight: .infinity`) does not clamp such a child — an infinite
/// maximum resolves to `max(proposal, childSize)` — so the oversized child became
/// the size of the card's `VStack`. The card's own `.frame(width:height:)` then
/// CENTRED that oversized subtree inside 220x250 and `clipShape` cut the ends off.
/// The card measured a correct 220x250 the whole time, which is why every
/// size-based instrument called it innocent.
///
///   1. The image. `.aspectRatio(contentMode: .fill)` reports the FILLED size,
///      which exceeds the proposal on one axis by construction. Measured on the
///      real card at HEAD:
///
///        image        ratio   photo over header   ink in left gutter
///        220x177      1.243   0%                  0     <- the one correct ratio
///        1920x1080    1.78    0%                  29    <- header slid sideways
///        4032x3024    1.33    0%                  23
///        1000x1000    1.00    65%                 --
///        3024x4032    0.75    95%                 --
///        1080x1920    0.56    95%                 --
///        4000x900     4.44    0%, and 4 ink pixels in the whole band
///
///      So EXACTLY ONE aspect ratio rendered correctly, and every other was
///      displaced in proportion to how far it missed. Portrait and square shapes
///      lost the header, the chip row and the footer outright; landscape shapes
///      slid them sideways ("WhatsApp" rendered as "atsApp", "29 characters" as
///      "9 characters"). `.clipped()` on the image never helped: it clips to the
///      image's own oversized bounds.
///
///   2. The chip row, which is NOT image-specific and hits text cards too. Chips
///      are `.fixedSize()`, so a full row can want more width than the card has:
///      shape "command" (71pt) + source "Google Chrome" (97pt) + "fresh" (49pt)
///      + spacing = 225pt against the 200pt a card offers. That widened the same
///      VStack and slid every row 12pt left.
///
/// These tests render the REAL `ClipCardView` and read PIXELS. That is not
/// belt-and-braces: a walk of the NSView tree cannot see a SwiftUI card at all
/// (the caveat `PanelHeightTests` documents), the outer size was correct
/// throughout, and the chips were present in the view tree — just not on the card.
///
/// Crypto/store safety: the payloads here are PLAINTEXT PNGs. `Crypto.open(_: Data?)`
/// returns at its marker check for bytes that do not begin with `enc1:`, before
/// `primaryRing` is ever forced, so no key is resolved and no keychain read happens.
/// No `ClipStore` is constructed.
@MainActor
final class ClipCardChromeTests: XCTestCase {

    private var dir: URL!
    private var savedPreset: String?

    override func setUp() {
        super.setUp()
        // Force a FLAT preset. Two reasons, both load-bearing: `.system` reads
        // `NSApp.effectiveAppearance`, which is nil in a test process, and
        // `ImageRenderer` does not draw `NSVisualEffectView` at all — so a
        // material preset renders a card with no background and the three pixel
        // populations (photo, card fill, ink) stop separating.
        //
        // This writes to `com.apple.dt.xctest.tool`, the test runner's own
        // defaults domain — verified NOT to be the app's `io.antreas.cliphoard`,
        // so a test run cannot repaint a running Cliphoard. The domain is shared
        // with every other SwiftPM suite on the machine, hence the restore below.
        // It survives a failing assertion; it cannot survive a hard crash.
        savedPreset = UserDefaults.standard.string(forKey: "themePreset")
        UserDefaults.standard.set("swiss", forKey: "themePreset")
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CardChrome-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let savedPreset { UserDefaults.standard.set(savedPreset, forKey: "themePreset") }
        else { UserDefaults.standard.removeObject(forKey: "themePreset") }
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// Every aspect ratio a real clipboard produces. The middle four are the shapes
    /// the bug ate whole — anything at least as tall as the content box, which
    /// includes a SQUARE image — and the outer three are the ones it slid sideways.
    ///
    /// Deliberately does NOT include the one ratio that rendered correctly at HEAD
    /// (220:177). That number is not a constant to protect: the content slot is
    /// ~177pt tall with a chip row and ~196pt without, so "the correct ratio"
    /// depends on the clip's chips. Nothing here may hard-code it.
    private static let ratios: [(String, Int, Int)] = [
        ("panorama 40:9", 4000, 900), ("landscape 16:9", 1920, 1080),
        ("landscape 4:3", 4032, 3024), ("square", 1000, 1000),
        ("portrait 3:4", 3024, 4032), ("portrait 9:16", 1080, 1920),
        ("very tall", 800, 3000),
    ]

    // MARK: - The chrome survives the photograph

    /// No photograph may reach the header band or the footer band at ANY aspect
    /// ratio — and the chrome must actually BE there, not merely un-covered.
    ///
    /// Both halves are needed. "No photo in the header" alone passes on a card
    /// whose header has been pushed off and left blank; "ink in the header" alone
    /// passes on a card where the photo's own edge supplies the dark pixels.
    ///
    /// Runs selected as well as unselected because the expand affordance only
    /// exists while hovering or selected, and selection is the half of that state
    /// a headless render can reach.
    ///
    /// Kills: restoring `.aspectRatio(contentMode: .fill)` under
    /// `.frame(maxWidth: .infinity, maxHeight: .infinity)` (measured 95% of the
    /// header band covered for a portrait photo, 65% for a SQUARE one, and 4 ink
    /// pixels left in the whole header band for a panorama); and dropping the
    /// `.clipped()` that cuts the overhang.
    func testAnImageNeverDisplacesTheCardsOwnChrome() throws {
        for (label, w, h) in Self.ratios {
            for selected in [false, true] {
                let s = try shoot(card(imageClip(w, h), selected: selected))
                let where_ = "\(label)\(selected ? ", selected" : "")"

                let header = s.band(rows: 3..<25)
                XCTAssertLessThan(header.photoFraction, 0.05,
                    "\(where_): \(Int(header.photoFraction * 100))% of the header band is "
                    + "photograph — the image has taken the card edge to edge")
                XCTAssertGreaterThan(header.ink, 20,
                    "\(where_): the header band holds only \(header.ink) ink pixels — the "
                    + "kind glyph, source name and ⌘-hint are not on the card")

                let footer = s.band(rows: (s.h - 23)..<(s.h - 4))
                XCTAssertLessThan(footer.photoFraction, 0.05,
                    "\(where_): the photograph reaches the footer band")
                XCTAssertGreaterThan(footer.ink, 10,
                    "\(where_): the footer band holds only \(footer.ink) ink pixels — the "
                    + "size and age are not on the card")
            }
        }
    }

    /// …and the photograph must still FILL the space it does have. A card
    /// thumbnail that letterboxes a portrait photo into a 110pt column wastes
    /// half the card, and would satisfy every assertion above.
    ///
    /// Kills: "fixing" the defect with `.aspectRatio(contentMode: .fit)`, which
    /// measures 0.45 here for 9:16, 0.60 for 3:4 and 0.21 for a very tall image.
    func testThePhotographStillFillsItsSlot() throws {
        for (label, w, h) in Self.ratios {
            let s = try shoot(card(imageClip(w, h)))
            let mid = s.band(rows: (s.h / 2 - 10)..<(s.h / 2 + 10))
            XCTAssertGreaterThan(mid.photoFraction, 0.90,
                "\(label): only \(Int(mid.photoFraction * 100))% of the content band is "
                + "photograph — an image card must fill its slot, not letterbox it")
        }
    }

    /// The card may not grow SIDEWAYS either. An oversized VStack is CENTRED, so a
    /// landscape photo slid the header off both edges at once while the card still
    /// measured 220pt wide.
    ///
    /// Every chrome row is inset by `.padding(.horizontal, 10)`, so ink in the
    /// first 8 columns means the row is wider than the card and has been centred
    /// out over its own margin. This is the sensitive instrument: a card widened
    /// by only 25pt still slides 12pt, which a landmark-in-a-corner check misses.
    /// The accent-glyph landmark catches the other end — a panorama slides the
    /// header 244pt and leaves nothing in the corner to measure at all.
    ///
    /// Unselected only: the selection ring is 2pt of accent blue at x=0, which is
    /// dark enough to read as ink by construction.
    ///
    /// Kills: the same restoration as above (measured 29 gutter pixels for 16:9
    /// and 23 for 4:3), and any repair that fixes only the vertical axis.
    func testNoRowIsSlidIntoItsOwnMargin() throws {
        for (label, w, h) in Self.ratios {
            let s = try shoot(card(imageClip(w, h)))
            XCTAssertTrue(s.hasAccentGlyphInTopLeft(),
                "\(label): the kind glyph is not in the card's top-left corner — the "
                + "header row is wider than the card and has been centred off both edges")
            XCTAssertEqual(s.inkInLeftGutter(rows: 10..<24), 0,
                "\(label): the header row has spilled into its own 10pt margin")
            XCTAssertEqual(s.inkInLeftGutter(rows: (s.h - 22)..<(s.h - 8)), 0,
                "\(label): the footer row has spilled into its own 10pt margin")
        }
        // The converse, so the landmark cannot pass by being unfalsifiable: a text
        // card has always had its glyph there and an empty gutter.
        let text = ClipItem(kind: .text, text: "hello"); text.sourceApp = "Safari"
        let s = try shoot(card(text))
        XCTAssertTrue(s.hasAccentGlyphInTopLeft())
        XCTAssertEqual(s.inkInLeftGutter(rows: 10..<24), 0)
    }

    /// The chip row is chrome too, and it is drawn from data the user does not
    /// control: a shape, the source app's name, a lifecycle word. Three of them
    /// measure 225pt against the 200pt a card offers, which widened the VStack and
    /// slid EVERY row sideways — on text cards as much as image ones.
    ///
    /// The second fixture is the one that matters most: its chips come from
    /// DETECTOR FLAGS, so no user action can avoid it. "password app" +
    /// "one-time code" + "+2" measures 216pt, the widest protective row this
    /// vocabulary can produce.
    ///
    /// What the clamp gives up is bounded and correct: the row is certainty-
    /// descending with protective chips first and `+N` always last, so the element
    /// that overhangs the card edge is either the lowest-certainty chip or the
    /// `+N` capsule's trailing curve (6pt of it, measured) — never a protective
    /// chip, and never the `+N` digit. Everything hidden stays reachable through
    /// `+N`, which opens the supercard.
    ///
    /// Kills: removing `.frame(maxWidth: Theme.cardWidth - 20, alignment: .leading)`
    /// from `tagRow` (measured: 22 gutter pixels in the header, 24 in the footer,
    /// rendering "brew" as "rew" and "29 characters" as "9 characters").
    func testAWideChipRowCannotSlideTheCardSideways() throws {
        let command = ClipItem(kind: .text, text: "brew install --cask cliphoard")
        command.shape = "command"
        command.sourceApp = "Google Chrome"          // + the "fresh" lifecycle chip = 3 chips
        XCTAssertEqual(ClipChips.row(for: command).shown.count, 3,
                       "fixture no longer produces a full chip row")

        let flagged = ClipItem(kind: .text, text: "482913")
        flagged.flags = [.otp, .quarantined]
        flagged.sourceApp = "Authy"
        XCTAssertGreaterThan(ClipChips.row(for: flagged).overflow, 0,
                             "fixture no longer produces an overflow chip")

        for (label, item) in [("three neutral chips", command), ("two protective chips + N", flagged)] {
            let s = try shoot(card(item))
            XCTAssertEqual(s.inkInLeftGutter(rows: 10..<24), 0,
                "\(label): the row is wider than the card and slid the header into its "
                + "own margin")
            XCTAssertEqual(s.inkInLeftGutter(rows: (s.h - 22)..<(s.h - 8)), 0,
                "\(label): the row slid the footer into its own margin")
        }
    }

    /// The crop must stay CENTRED on the picture.
    ///
    /// This is the test that says which repair we chose, and it exists because
    /// the two candidate repairs are not equivalent. Clamping the card's content
    /// SLOT also stops the overflow — every other test in this file passes with
    /// the slot clamp alone and the image site reverted — but it re-anchors the
    /// crop to `.topLeading`, silently turning every photo thumbnail in the strip
    /// into its top-left corner: foreheads, ceilings, the left third of a
    /// screenshot. That is a regression no assertion about chrome can see.
    ///
    /// The fixture paints its LEADING quarter red — the top quarter for a
    /// portrait, the left quarter for a landscape, i.e. whichever edge a
    /// `.topLeading` anchor would keep. A centred fill crop never shows it.
    ///
    /// Kills: reverting the `Color.clear.overlay(…)` at the image site while
    /// leaving the slot clamp in place; and any `alignment:` other than centre on
    /// the image's own overlay.
    func testTheCropStaysCentredOnThePicture() throws {
        // Only the ratios that genuinely crop. A square or 4:3 image is scaled to
        // very nearly the slot, so its crop window is most of the picture and the
        // anchor barely moves it — including them would only weaken the margin.
        // The narrowest window here still starts 15% into the picture, so a 10%
        // leading band cannot show under a centred crop.
        let cropping = Self.ratios.filter { $0.0 != "square" && $0.0 != "landscape 4:3" }
        XCTAssertEqual(cropping.count, 5, "the cropping-ratio list has drifted")
        for (label, w, h) in cropping {
            let s = try shoot(card(imageClip(w, h, markLeadingEdge: true)))
            let content = s.redFraction(rows: (s.h / 2 - 40)..<(s.h / 2 + 40))
            XCTAssertLessThan(content, 0.02,
                "\(label): \(Int(content * 100))% of the content band is the picture's "
                + "leading edge — the fill crop is anchored to the leading edge "
                + "instead of the centre")
        }
    }

    /// The header must keep its height while the expand affordance grows.
    ///
    /// The affordance is a bare 9pt glyph with `.buttonStyle(.plain)`, which
    /// measures 11x11pt — a 121pt² target on a card in a dense strip. Giving it a
    /// `.frame(width: 22, height: 14)` plus `.contentShape(Rectangle())` makes it
    /// 308pt² and costs NOTHING: the header stays 28pt because 14 < 28 and the
    /// `Spacer` absorbs the extra 11pt of width.
    ///
    /// This asserts the cost, not the target — a hit region is not readable from a
    /// rendered image, so a revert of the frame would pass here. What it does kill
    /// is the tempting alternative: `.padding(5)` around the glyph, which grows
    /// the header from 28pt to 35pt and takes 7pt out of every card's image slot,
    /// on every card, forever.
    func testGrowingTheExpandAffordanceDoesNotGrowTheHeader() throws {
        let s = try shoot(card(imageClip(1000, 1000), selected: true))
        XCTAssertEqual(s.firstPhotoRow(), 29, accuracy: 1,
            "the content slot no longer starts at y=29 — the header has changed height, "
            + "which takes the difference out of the image slot on every card")
    }

    // MARK: - Rendering the real card

    /// A uniformly magenta PNG — a colour no chrome uses, so "is this pixel the
    /// photograph?" is a decidable question. Written UNSEALED; see the safety note
    /// on the suite.
    ///
    /// `markLeadingEdge` paints the edge a `.topLeading` anchor would keep — the
    /// top tenth of a portrait, the left tenth of a landscape — in red, which is
    /// neither photo nor card fill, so the crop's anchor is decidable.
    private func png(_ w: Int, _ h: Int, markLeadingEdge: Bool) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        if markLeadingEdge {
            NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
            // AppKit's origin is bottom-left, so the image's TOP tenth is the
            // high-y band.
            if h >= w { NSRect(x: 0, y: h - h / 10, width: w, height: h / 10).fill() }
            else      { NSRect(x: 0, y: 0, width: w / 10, height: h).fill() }
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    private func imageClip(_ w: Int, _ h: Int, markLeadingEdge: Bool = false) -> ClipItem {
        // Unique per clip: `ClipCardView.imageCache` is keyed by file name.
        let name = "\(UUID().uuidString).png"
        try? png(w, h, markLeadingEdge: markLeadingEdge)
            .write(to: dir.appendingPathComponent(name))
        let item = ClipItem(kind: .image, text: "Image \(w)×\(h)")
        item.payloadFile = name
        item.sourceApp = "WhatsApp"
        return item
    }

    private func card(_ item: ClipItem, selected: Bool = false) -> some View {
        ClipCardView(item: item, index: 0, selected: selected, storeDir: dir,
                     onActivate: {}, onInspect: {}, onInspectTags: {},
                     onPin: {}, onDelete: {}, historyIsMutable: true)
    }

    private func shoot<V: View>(_ v: V) throws -> Shot {
        let renderer = ImageRenderer(content: v)
        renderer.scale = 1
        let cg = try XCTUnwrap(renderer.cgImage, "ImageRenderer produced no image")
        var buf = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let ctx = try XCTUnwrap(CGContext(data: &buf, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        XCTAssertEqual(CGFloat(cg.width), Theme.cardWidth, accuracy: 1)
        XCTAssertEqual(CGFloat(cg.height), Theme.cardHeight, accuracy: 1)
        return Shot(w: cg.width, h: cg.height, px: buf)
    }

    // MARK: - Pixel classification

    /// The rendered card in three populations: the photograph (saturated magenta),
    /// the card fill (near-white under the Swiss preset), and ink — everything
    /// else, i.e. text and glyphs.
    private struct Shot {
        let w: Int, h: Int, px: [UInt8]

        private func rgba(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            let i = (y * w + x) * 4
            return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]), Int(px[i + 3]))
        }

        private func isPhoto(_ p: (r: Int, g: Int, b: Int, a: Int)) -> Bool {
            p.a > 200 && p.r > 180 && p.g < 90 && p.b > 180
        }

        /// Counts inside a horizontal band, ignoring the rounded corners (x inset)
        /// and any fully transparent pixel.
        func band(rows: Range<Int>) -> (ink: Int, photoFraction: Double) {
            var ink = 0, photo = 0, total = 0
            for y in rows where y >= 0 && y < h {
                for x in 10..<(w - 10) {
                    let p = rgba(x, y)
                    guard p.a > 200 else { continue }
                    total += 1
                    if isPhoto(p) { photo += 1 }
                    else if p.r > 225 && p.g > 225 && p.b > 225 { /* card fill */ }
                    else { ink += 1 }
                }
            }
            return (ink, total == 0 ? 0 : Double(photo) / Double(total))
        }

        /// Dark pixels inside the card's 10pt horizontal gutter. Callers pass a
        /// CORNER-FREE row band: the rounded clip antialiases two pixels of border
        /// into every corner, a permanent false positive otherwise. The card fill
        /// is white and its border is 209, so only glyphs and text score below 200.
        func inkInLeftGutter(rows: Range<Int>, columns: Int = 8) -> Int {
            var ink = 0
            for y in rows where y >= 0 && y < h {
                for x in 0..<min(columns, w) {
                    let p = rgba(x, y)
                    guard p.a > 200 else { continue }
                    if 0.2126 * Double(p.r) + 0.7152 * Double(p.g) + 0.0722 * Double(p.b) < 200 {
                        ink += 1
                    }
                }
            }
            return ink
        }

        /// The Swiss accent, i.e. the kind glyph that opens the header row.
        func hasAccentGlyphInTopLeft(side: Int = 26) -> Bool {
            for y in 0..<min(side, h) {
                for x in 0..<min(side, w) {
                    let p = rgba(x, y)
                    if p.a > 120 && p.b > 150 && p.r < 140 && p.g < 190 && p.b > p.r + 60 {
                        return true
                    }
                }
            }
            return false
        }

        /// Saturated red — the fixture's leading-quarter marker.
        func redFraction(rows: Range<Int>) -> Double {
            var hit = 0, total = 0
            for y in rows where y >= 0 && y < h {
                for x in 10..<(w - 10) {
                    let p = rgba(x, y)
                    guard p.a > 200 else { continue }
                    total += 1
                    if p.r > 180 && p.g < 90 && p.b < 90 { hit += 1 }
                }
            }
            return total == 0 ? 0 : Double(hit) / Double(total)
        }

        /// The first row that is mostly photograph — i.e. the top of the content
        /// slot, which is the bottom of the header plus its divider.
        func firstPhotoRow() -> Double {
            for y in 0..<h {
                var hit = 0
                for x in 10..<(w - 10) where isPhoto(rgba(x, y)) { hit += 1 }
                if Double(hit) / Double(w - 20) > 0.5 { return Double(y) }
            }
            return -1
        }
    }
}
