import AppKit
import SwiftUI
import XCTest
@testable import Cliphoard

@MainActor
final class BrandIconTests: XCTestCase {
    private var resources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
    }

    func testBothThemeVariantsAreTransparentWithContrastingMascots() throws {
        var brightness: [CGFloat] = []
        for scheme in [ColorScheme.light, .dark] {
            let image = try XCTUnwrap(BrandIcon.load(for: scheme, resourceDirectory: resources))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            XCTAssertTrue(bitmap.hasAlpha)
            for (x, y) in [(0, 0), (bitmap.pixelsWide - 1, 0), (0, bitmap.pixelsHigh - 1),
                           (bitmap.pixelsWide - 1, bitmap.pixelsHigh - 1)] {
                XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent, 0)
            }
            let fabric = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2,
                y: bitmap.pixelsHigh * 63 / 100)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(fabric.alphaComponent, 0.99)
            XCTAssertGreaterThan(fabric.greenComponent, fabric.redComponent + 0.25)
            XCTAssertGreaterThan(fabric.blueComponent, fabric.redComponent + 0.25)
            brightness.append((fabric.redComponent + fabric.greenComponent + fabric.blueComponent) / 3)
        }
        XCTAssertGreaterThan(brightness[1], brightness[0] + 0.04, "Dark UI uses the brighter teal")
    }
    func testPupilsAreCenteredWithinBothEyeWhites() throws {
        for scheme in [ColorScheme.light, .dark] {
            let image = try XCTUnwrap(BrandIcon.load(for: scheme, resourceDirectory: resources))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            let width = bitmap.pixelsWide
            let height = bitmap.pixelsHigh
            for xRange in [0.30...0.47, 0.53...0.67] {
                var eyePixels: [(Int, Int)] = []
                for y in Int(Double(height) * 0.47)...Int(Double(height) * 0.57) {
                    for x in Int(Double(width) * xRange.lowerBound)...Int(Double(width) * xRange.upperBound) {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                        if color.alphaComponent > 0.99 && color.redComponent > 0.85 &&
                            color.greenComponent > 0.85 && color.blueComponent > 0.75 {
                            eyePixels.append((x, y))
                        }
                    }
                }
                let left = try XCTUnwrap(eyePixels.map { $0.0 }.min())
                let right = try XCTUnwrap(eyePixels.map { $0.0 }.max())
                let top = try XCTUnwrap(eyePixels.map { $0.1 }.min())
                let bottom = try XCTUnwrap(eyePixels.map { $0.1 }.max())
                let center = try XCTUnwrap(bitmap.colorAt(x: (left + right) / 2,
                    y: (top + bottom) / 2)?.usingColorSpace(.deviceRGB))
                XCTAssertLessThan(center.redComponent, 0.3)
                XCTAssertGreaterThan(center.greenComponent, center.redComponent + 0.02,
                    "The dark teal pupil sits at the center of each ivory eye")
            }
        }
    }

}
