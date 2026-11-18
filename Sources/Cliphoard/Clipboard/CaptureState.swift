import Combine
import Foundation

/// The owner's capture choice survives relaunches and updates. Temporary privacy
/// suspensions (such as passphrase sheets) remain independent of this setting.
@MainActor
final class CaptureState: ObservableObject {
    static let shared = CaptureState()
    private static let defaultsKey = "capturePaused"

    @Published private(set) var isPaused: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isPaused = defaults.bool(forKey: Self.defaultsKey)
    }

    var actionTitle: String { isPaused ? "Resume capture" : "Pause capture" }

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        defaults.set(paused, forKey: Self.defaultsKey)
        isPaused = paused
    }

    func toggle() { setPaused(!isPaused) }
}
