#!/usr/bin/env swift
import AppKit

// Draws the final Cliphoard app icon: the Command-V paste keystroke (the action Cliphoard
// performs) as a stacked hero glyph — a bold chevron V over the Command
// looped-square (U+2318) — in a cyan gradient on a graphite macOS squircle.
// Ported by hand from design/icons/cmdv/stacked.html (512x512 viewBox); pure
// AppKit/CoreGraphics so it renders at build time with `swift make-icon.swift`.
// Writes PNGs at every size an .icns needs.

// All geometry below is authored in the SVG's 512x512, y-DOWN coordinate space
// and mapped to the requested output size with a flip so it matches AppKit's
// y-UP space.
private let VB: CGFloat = 512

// Append a circular SVG elliptical-arc segment ("A r r 0 largeArc sweep x y")
// to a path, from its current point to `to`. Mirrors the SVG endpoint->centre
// parameterisation for the rx == ry, no-rotation case. Angles/sweep are in the
// path's own (SVG y-down) coordinate space, so `sweep == true` is the SVG
// positive-angle (clockwise-on-screen) direction.
func svgArc(_ path: CGMutablePath, to: CGPoint, r: CGFloat, largeArc: Bool, sweep: Bool) {
    let from = path.currentPoint
    let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
    let dx = (from.x - to.x) / 2, dy = (from.y - to.y) / 2
    let half = (dx * dx + dy * dy).squareRoot()        // half chord length
    let rr = max(r, half)                               // clamp like SVG
    // Distance from chord midpoint to centre, perpendicular to the chord.
    let h = (rr * rr - half * half).squareRoot()
    // Perpendicular unit vector to the chord (from -> to).
    let len = (4 * (dx * dx + dy * dy)).squareRoot()
    let ux = len == 0 ? 0 : -(to.y - from.y) / len
    let uy = len == 0 ? 0 :  (to.x - from.x) / len
    // Two candidate centres; pick the side per largeArc/sweep.
    let sign: CGFloat = (largeArc != sweep) ? 1 : -1
    let cx = mid.x + sign * h * ux
    let cy = mid.y + sign * h * uy
    let centre = CGPoint(x: cx, y: cy)
    let a0 = atan2(from.y - cy, from.x - cx)
    let a1 = atan2(to.y - cy, to.x - cx)
    // In CGPath, `clockwise` is in the path's coordinate space; SVG sweep==1 is
    // the positive-angle direction, which CGPath treats as counter-clockwise.
    path.addArc(center: centre, radius: rr, startAngle: a0, endAngle: a1,
                clockwise: !sweep)
}

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext

    // Map SVG (0..512, y-down) -> output (0..size, y-up).
    let scale = size / VB
    ctx.saveGState()
    ctx.translateBy(x: 0, y: size)        // origin to top-left
    ctx.scaleBy(x: scale, y: -scale)      // flip y, scale into viewBox units

    // ----- macOS squircle tile path (verbatim from the SVG) -----
    let squircle = CGMutablePath()
    squircle.move(to: CGPoint(x: 256, y: 24))
    squircle.addCurve(to: CGPoint(x: 56, y: 56), control1: CGPoint(x: 120, y: 24), control2: CGPoint(x: 88, y: 24))
    squircle.addCurve(to: CGPoint(x: 24, y: 256), control1: CGPoint(x: 24, y: 88), control2: CGPoint(x: 24, y: 120))
    squircle.addCurve(to: CGPoint(x: 56, y: 456), control1: CGPoint(x: 24, y: 392), control2: CGPoint(x: 24, y: 424))
    squircle.addCurve(to: CGPoint(x: 256, y: 488), control1: CGPoint(x: 88, y: 488), control2: CGPoint(x: 120, y: 488))
    squircle.addCurve(to: CGPoint(x: 456, y: 456), control1: CGPoint(x: 392, y: 488), control2: CGPoint(x: 424, y: 488))
    squircle.addCurve(to: CGPoint(x: 488, y: 256), control1: CGPoint(x: 488, y: 424), control2: CGPoint(x: 488, y: 392))
    squircle.addCurve(to: CGPoint(x: 456, y: 56), control1: CGPoint(x: 488, y: 120), control2: CGPoint(x: 488, y: 88))
    squircle.addCurve(to: CGPoint(x: 256, y: 24), control1: CGPoint(x: 424, y: 24), control2: CGPoint(x: 392, y: 24))
    squircle.closeSubpath()

    // Clip to the squircle, then fill the vertical graphite gradient.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    let space = CGColorSpaceCreateDeviceRGB()
    func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: space, components: [r, g, b, a])!
    }
    // Vertical: top #2A3350 -> mid(0.45) #1A2034 -> bottom #0B0E18.
    let tileColors = [rgb(0x2A/255, 0x33/255, 0x50/255),
                      rgb(0x1A/255, 0x20/255, 0x34/255),
                      rgb(0x0B/255, 0x0E/255, 0x18/255)]
    let tileGrad = CGGradient(colorsSpace: space, colors: tileColors as CFArray,
                              locations: [0, 0.45, 1])!
    // y-down: top of tile is y=24, bottom is y=488.
    ctx.drawLinearGradient(tileGrad, start: CGPoint(x: 0, y: 24),
                           end: CGPoint(x: 0, y: 488), options: [])

    // Soft top-left radial sheen (#5A6CB0 fading out), cx 0.30 cy 0.16 r 0.95.
    let sheenColors = [rgb(0x5A/255, 0x6C/255, 0xB0/255, 0.55),
                       rgb(0x5A/255, 0x6C/255, 0xB0/255, 0.0)]
    let sheenGrad = CGGradient(colorsSpace: space, colors: sheenColors as CFArray,
                               locations: [0, 1])!
    let sheenCenter = CGPoint(x: 0.30 * VB, y: 0.16 * VB)
    ctx.drawRadialGradient(sheenGrad, startCenter: sheenCenter, startRadius: 0,
                           endCenter: sheenCenter, endRadius: 0.95 * VB,
                           options: [])

    // Subtle bottom shading to ground the tile (matches the SVG overlay).
    ctx.setFillColor(rgb(0, 0, 0, 0.14))
    ctx.fill(CGRect(x: 24, y: 300, width: 464, height: 188))
    ctx.restoreGState()  // drop squircle clip

    // ----- HERO GLYPH (cyan gradient), nudged down 14 like the SVG group -----
    // Glyph gradient: #8BFADF -> (0.5) #34D2E2 -> #1F9CF0, diagonal x1:.1 y1:0 -> x2:.9 y2:1.
    let glyphColors = [rgb(0x8B/255, 0xFA/255, 0xDF/255),
                       rgb(0x34/255, 0xD2/255, 0xE2/255),
                       rgb(0x1F/255, 0x9C/255, 0xF0/255)]
    let glyphGrad = CGGradient(colorsSpace: space, colors: glyphColors as CFArray,
                               locations: [0, 0.5, 1])!
    let gStart = CGPoint(x: 0.1 * VB, y: 0.0 * VB)
    let gEnd = CGPoint(x: 0.9 * VB, y: 1.0 * VB)

    func fillWithGlyphGradient(_ path: CGPath) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(glyphGrad, start: gStart, end: gEnd,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }
    func strokeWithGlyphGradient(_ path: CGPath, width: CGFloat) {
        // Convert the stroke to a fillable outline, then gradient-fill it so the
        // weight is even and the loops stay crisply open at small sizes.
        let outline = path.copy(strokingWithWidth: width, lineCap: .round,
                                lineJoin: .round, miterLimit: 10)
        fillWithGlyphGradient(outline)
    }

    // ===== BOLD V (top), exact polygon from the SVG =====
    let v = CGMutablePath()
    v.move(to: CGPoint(x: 146, y: 122))
    v.addLine(to: CGPoint(x: 224, y: 122))
    v.addLine(to: CGPoint(x: 256, y: 196))
    v.addLine(to: CGPoint(x: 288, y: 122))
    v.addLine(to: CGPoint(x: 366, y: 122))
    v.addLine(to: CGPoint(x: 288, y: 256))
    v.addLine(to: CGPoint(x: 224, y: 256))
    v.closeSubpath()

    // ===== COMMAND looped-square =====
    // One continuous stroked path (verbatim SVG arcs): straight bars between
    // four 270deg corner loops that bulge diagonally OUTWARD so the holes stay
    // open and legible at small sizes. r = 32, stroke-width 22.
    let cmdStroke = CGMutablePath()
    cmdStroke.move(to: CGPoint(x: 228, y: 324))
    cmdStroke.addLine(to: CGPoint(x: 284, y: 324))
    svgArc(cmdStroke, to: CGPoint(x: 312, y: 352), r: 32, largeArc: true, sweep: true)   // top-right loop
    cmdStroke.addLine(to: CGPoint(x: 312, y: 412))
    svgArc(cmdStroke, to: CGPoint(x: 284, y: 440), r: 32, largeArc: true, sweep: true)   // bottom-right loop
    cmdStroke.addLine(to: CGPoint(x: 228, y: 440))
    svgArc(cmdStroke, to: CGPoint(x: 200, y: 412), r: 32, largeArc: true, sweep: true)   // bottom-left loop
    cmdStroke.addLine(to: CGPoint(x: 200, y: 352))
    svgArc(cmdStroke, to: CGPoint(x: 228, y: 324), r: 32, largeArc: true, sweep: true)   // top-left loop
    cmdStroke.closeSubpath()
    let cmdWidth: CGFloat = 22

    // ----- Layout: the raw SVG places the ⌘ very low, leaving it detached and
    // bottom-heavy. Pull the ⌘ up toward the V so they read as ONE stacked
    // glyph, then centre the whole unit in the tile (with a small upward optical
    // nudge so the heavier ⌘ doesn't feel like it's sinking).
    let pull: CGFloat = 20
    var lift = CGAffineTransform(translationX: 0, y: -pull)
    let cmdUp = cmdStroke.copy(using: &lift)!
    let cmdOutline = cmdUp.copy(strokingWithWidth: cmdWidth, lineCap: .round,
                                lineJoin: .round, miterLimit: 10)
    let unit = v.boundingBoxOfPath.union(cmdOutline.boundingBoxOfPath)
    let targetMidX: CGFloat = 256
    let targetMidY: CGFloat = 248
    let place = CGAffineTransform(translationX: targetMidX - unit.midX,
                                  y: targetMidY - unit.midY)

    ctx.saveGState()
    ctx.concatenate(place)
    fillWithGlyphGradient(v)
    strokeWithGlyphGradient(cmdUp, width: cmdWidth)
    ctx.restoreGState()

    ctx.restoreGState()  // drop viewBox transform

    image.unlockFocus()
    return image
}

func png(_ image: NSImage, _ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = "\(outDir)/Cliphoard.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let sizes: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (px, name) in sizes {
    let img = drawIcon(size: CGFloat(px))
    let data = png(img, px)
    try! data.write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}
print("wrote \(iconset)")
