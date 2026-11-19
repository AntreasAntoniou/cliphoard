import Foundation
import Combine

/// One shared model keeps the Settings window and an already-open bar in sync.
@MainActor
final class BarHeightSettings: ObservableObject {
    static let shared = BarHeightSettings()
    static let defaultsKey = "barPreviewHeight"
    static let defaultHeight = 250.0
    static let range = 200.0...400.0

    @Published private(set) var previewHeight: Double
    @Published private(set) var availableHeight: Double?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        previewHeight = Self.validated((defaults.object(forKey: Self.defaultsKey) as? NSNumber)?.doubleValue
                                      ?? Self.defaultHeight)
    }

    static func validated(_ height: Double) -> Double {
        guard height.isFinite else { return defaultHeight }
        return min(max(height, range.lowerBound), range.upperBound)
    }

    func setHeight(_ height: Double) {
        previewHeight = Self.validated(height)
        defaults.set(previewHeight, forKey: Self.defaultsKey)
    }

    func setAvailableHeight(_ height: Double) {
        guard height.isFinite, height > 1, availableHeight != height else { return }
        availableHeight = height
    }

    var effectiveHeight: Double {
        // Reserve the existing maximum chrome allowance and strip padding before
        // adding height. Small displays retain the original layout at most.
        let chrome = Double(FloatingPanel.fixedChromeAllowance + 2 * Theme.chromeMaxHeight
                            + 2 * Theme.stripInset)
        let ceiling = max(Self.defaultHeight, (availableHeight ?? .greatestFiniteMagnitude) - chrome)
        return min(previewHeight, ceiling)
    }

    var panelFloor: Double { 320 + min(0, effectiveHeight - Self.defaultHeight) }
}
