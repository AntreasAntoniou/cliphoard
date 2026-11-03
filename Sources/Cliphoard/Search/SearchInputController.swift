import Foundation
import Combine

enum SearchTiming: String, CaseIterable, Identifiable {
    case instant, pause, enter
    var id: String { rawValue }
    var title: String {
        switch self {
        case .instant: return "While typing"
        case .pause: return "After a short pause"
        case .enter: return "When I press Return"
        }
    }
    var detail: String {
        switch self {
        case .instant: return "Update results with each edit."
        case .pause: return "Wait until you stop typing for 0.45 seconds. Return searches immediately."
        case .enter: return "Keep results still while you type. Press Return or Search when ready."
        }
    }
    static let changed = Notification.Name("CliphoardSearchTimingChanged")
    static func current(_ defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: "searchTiming") ?? "") ?? .pause
    }
    static func save(_ value: Self, _ defaults: UserDefaults = .standard) {
        defaults.set(value.rawValue, forKey: "searchTiming")
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

/// The field's draft is deliberately separate from the query used by every
/// search lane. Editing never invokes inference until this owner commits it.
@MainActor
final class SearchInputController: ObservableObject {
    @Published private(set) var draft = ""
    @Published private(set) var submitted = ""
    @Published private(set) var timing: SearchTiming
    var isPending: Bool { draft != submitted }
    var onCommit: ((String) -> Void)?
    /// The real field editor owns input-method composition; provisional text
    /// must not start inference even if the user pauses during composition.
    var isComposing: () -> Bool = { false }
    private let sleep: @Sendable (UInt64) async throws -> Void
    private var pending: Task<Void, Never>?
    private var revision = UUID()

    init(timing: SearchTiming = .current(),
         sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.timing = timing
        self.sleep = sleep
    }

    deinit { pending?.cancel() }

    func updateDraft(_ value: String) {
        guard value != draft else { return }
        draft = value
        reschedule()
    }

    func setTiming(_ value: SearchTiming) {
        guard value != timing else { return }
        timing = value
        reschedule()
    }

    /// A programmatic query/reset (including closing or reopening the bar)
    /// invalidates any pending edit without launching another search.
    func reset(to value: String) {
        invalidate()
        if draft != value { draft = value }
        if submitted != value { submitted = value }
    }

    /// Return consumes an outstanding edit; it must not paste an old selection
    /// on the same keystroke. A later Return retains the normal paste action.
    @discardableResult
    func submitPending() -> Bool {
        guard isPending, !isComposing() else { return false }
        invalidate()
        submitted = draft
        onCommit?(submitted)
        return true
    }

    private func invalidate() {
        pending?.cancel()
        pending = nil
        revision = UUID()
    }

    private func reschedule() {
        invalidate()
        guard isPending else { return }
        // Clear immediately in every mode; never leave a hidden old filter.
        let isClear = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !isComposing(), isClear || timing == .instant {
            submitPending()
        } else if timing != .enter || isClear {
            let ticket = revision, expected = draft, sleep = sleep
            pending = Task { [weak self] in
                do { try await sleep(450_000_000) } catch { return }
                guard !Task.isCancelled, let self, self.revision == ticket,
                      self.draft == expected else { return }
                if self.isComposing() { self.reschedule() }
                else { self.submitPending() }
            }
        }
    }
}
