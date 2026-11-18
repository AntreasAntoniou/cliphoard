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
                y: bitmap.pixelsHigh * 3 / 5)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(fabric.alphaComponent, 0.99)
            brightness.append((fabric.redComponent + fabric.greenComponent + fabric.blueComponent) / 3)
        }
        XCTAssertLessThan(brightness[0], 0.4, "Light themes use the charcoal mascot")
        XCTAssertGreaterThan(brightness[1], 0.7, "Dark themes use the ivory mascot")
    }
}
