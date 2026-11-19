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

    func testBothThemeVariantsKeepTheOriginalTealAndTransparentBackground() throws {
        for scheme in [ColorScheme.light, .dark] {
            let image = try XCTUnwrap(BrandIcon.load(for: scheme, resourceDirectory: resources))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            XCTAssertTrue(bitmap.hasAlpha)
            for (x, y) in [(0, 0), (bitmap.pixelsWide - 1, 0), (0, bitmap.pixelsHigh - 1),
                           (bitmap.pixelsWide - 1, bitmap.pixelsHigh - 1)] {
                XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent, 0)
            }
            let fabric = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2,
                y: bitmap.pixelsHigh * 73 / 100)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(fabric.alphaComponent, 0.99)
            XCTAssertGreaterThan(fabric.greenComponent, fabric.redComponent + 0.25)
            XCTAssertGreaterThan(fabric.blueComponent, fabric.redComponent + 0.25)
            let mouth = (63...69).compactMap { row in
                bitmap.colorAt(x: bitmap.pixelsWide / 2,
                    y: bitmap.pixelsHigh * row / 100)?.usingColorSpace(.deviceRGB)
            }
            XCTAssertTrue(mouth.contains { $0.redComponent > $0.greenComponent + 0.25 },
                "The original character has a coral tongue in its open smile")
        }
        let dark = try Data(contentsOf: resources.appendingPathComponent("BrandIconDark.png"))
        let light = try Data(contentsOf: resources.appendingPathComponent("BrandIconLight.png"))
        XCTAssertNotEqual(dark, light)
    }
}
