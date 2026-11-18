import AppKit
import SwiftUI

/// Transparent mascot artwork follows the panel's effective appearance, including
/// a user-selected theme that differs from the macOS appearance.
@MainActor
enum BrandIcon {
    private static let light = load(for: .light, resourceDirectory: Bundle.main.resourceURL)
    private static let dark = load(for: .dark, resourceDirectory: Bundle.main.resourceURL)

    static func image(for scheme: ColorScheme) -> NSImage? {
        scheme == .dark ? dark : light
    }

    static func load(for scheme: ColorScheme, resourceDirectory: URL?) -> NSImage? {
        guard let resourceDirectory else { return nil }
        let name = scheme == .dark ? "BrandIconDark.png" : "BrandIconLight.png"
        return NSImage(contentsOf: resourceDirectory.appendingPathComponent(name))
    }
}
