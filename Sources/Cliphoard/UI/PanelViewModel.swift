import SwiftUI
import Combine

/// View-model backing the floating bar. Holds the search/filter state and the
/// current keyboard selection, and exposes intents the controller wires up.
@MainActor
final class PanelViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var activeKind: ClipKind? = nil
    @Published var pinnedOnly: Bool = false
    /// Time window over `createdAt` (chip selection). A `when:` token typed in the
    /// query overrides this for that search.
    @Published var timeFilter: TimeFilter = .any
    /// Selected facet-cube constraints (tag ids). Within a dimension OR'd, across
    /// dimensions AND'd — see `ClipStore.items(matchingFacets:)`.
    @Published var activeFacets: Set<Int> = []
    @Published var selection: Int = 0
    /// Bumped each time the bar is presented so the UI can reset scroll/state.
    @Published var presentToken: Int = 0
    /// Set by keyboard navigation to request the strip scroll a card into view.
    /// Mouse clicks deliberately do NOT set this — a clicked card is already
    /// under the cursor, so re-centering it would feel like lag.
    @Published var scrollRequest: Int = 0
    /// When true the bar shows the settings surface instead of the card strip.
    @Published var showSettings: Bool = false

    let store: ClipStore

    /// Forwards `store.objectWillChange` so that `results` (a plain computed
    /// property reading `store`) participates in SwiftUI's update cycle. Without
    /// this, `ContentView` observed two objects and the live data path (`store`)
    /// could update without driving a `body` re-evaluation through `model`.
    private var storeObserver: AnyCancellable?

    /// Invoked when the user commits a clip (Enter / double click). The `plain`
    /// flag requests "paste as plain text" (Option held at commit time).
    var onPaste: ((ClipItem, _ plain: Bool) -> Void)?
    /// Invoked when the user dismisses the bar (Esc).
    var onClose: (() -> Void)?
    /// Invoked to copy a clip onto the system clipboard without pasting (⌘C/⌃C).
    var onCopy: ((ClipItem) -> Void)?

    init(store: ClipStore) {
        self.store = store
        // Republish store changes so the two-object observation collapses into
        // one deterministic update path — fixes the live-while-open refresh case.
        storeObserver = store.objectWillChange.sink { [weak self] _ in
            // Any store mutation (add/delete/pin/reclassify/embedder switch)
            // invalidates the memoized results, closing the staleness windows the
            // (count, lastAddedID) key alone would miss.
            self?.cachedResultsKey = nil
            self?.objectWillChange.send()
        }
    }

    /// Identity of the inputs `results` depends on. When this is unchanged we
    /// return the cached array instead of recomputing (BL-10b) — `.essence`
    /// otherwise re-runs dot-products over every item on each read (several
    /// times per `body` pass and per keystroke).
    ///
    /// The store revision proxy is `(items.count, lastAddedID)`: adds and
    /// removes change the count (and adds also bump `lastAddedID`), so they
    /// invalidate the cache. Known minor limitation: an in-place mutation that
    /// leaves both the count and `lastAddedID` untouched is not detected.
    private struct ResultsKey: Equatable {
        let query: String
        let activeKind: ClipKind?
        let pinnedOnly: Bool
        let timeFilter: TimeFilter
        let facets: Set<Int>
        let mode: SearchMode
        let itemCount: Int
        let lastAddedID: UUID?
    }

    private var cachedResultsKey: ResultsKey?
    private var cachedResults: [ClipItem] = []

    var results: [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = ResultsKey(
            query: q,
            activeKind: activeKind,
            pinnedOnly: pinnedOnly,
            timeFilter: timeFilter,
            facets: activeFacets,
            mode: DeepSearch.mode,
            itemCount: store.items.count,
            lastAddedID: store.lastAddedID
        )
        if key == cachedResultsKey { return cachedResults }

        let value = computeResults(query: q)
        cachedResultsKey = key
        cachedResults = value
        return value
    }

    /// Pure computation behind `results`. `q` is the already-trimmed query. A
    /// `when:` token in the query is parsed out and applied as the effective time
    /// window (overriding the chip); the remaining text drives the match. The
    /// time + facet-cube scope applies in every mode.
    private func computeResults(query raw: String) -> [ClipItem] {
        let parsed = WhenToken.parse(raw)
        let time = parsed.filter ?? timeFilter
        let q = parsed.rest.trimmingCharacters(in: .whitespacesAndNewlines)

        // Exact (or empty query) → substring filter, scoped by kind/pin/time/facets.
        if DeepSearch.mode == .exact || q.isEmpty {
            return store.filtered(kind: activeKind, query: q, pinnedOnly: pinnedOnly,
                                  facets: activeFacets, time: time)
        }
        // Kind/pinned/time/facet scope first (no substring), then semantic search.
        let scoped = store.filtered(kind: activeKind, query: "", pinnedOnly: pinnedOnly,
                                    facets: activeFacets, time: time)
        let embedder = EmbedderProvider.active
        switch DeepSearch.mode {
        case .exact:
            return scoped
        case .tag:
            // O(1) tag lookup: map the query to its nearest preset tag (100
            // comparisons), then intersect the pre-tagged entries with the scope.
            guard let tag = TagSpace.nearestTag(toQuery: q, embedder: embedder) else { return [] }
            let ids = Set(store.items(taggedWith: tag).map { $0.id })
            return scoped.filter { ids.contains($0.id) }
        case .neural:
            // Pure model-based semantic ranking (cosine only, no substring/tags).
            return SemanticRanker.neural(query: q, items: scoped, embedder: embedder)
        case .smart:
            // Clever hybrid: exact hits first, then blended neural + shared-tag topic.
            return SemanticRanker.smart(query: q, items: scoped, embedder: embedder)
        }
    }

    func resetSelection() { selection = 0 }

    // MARK: Keyboard intents

    func moveSelection(_ delta: Int) {
        let count = results.count
        guard count > 0 else { selection = 0; return }
        selection = (selection + delta + count) % count
        scrollRequest = selection
    }

    /// Select a card via mouse click — instant, no scroll animation. Clicking the
    /// already-selected card commits it (paste).
    func click(_ index: Int) {
        if selection == index {
            let r = results
            if r.indices.contains(index) { onPaste?(r[index], false) }
        } else {
            selection = index
        }
    }

    func commitSelection(plain: Bool = false) {
        let r = results
        guard r.indices.contains(selection) else { return }
        onPaste?(r[selection], plain)
    }

    func copySelection() {
        let r = results
        guard r.indices.contains(selection) else { return }
        onCopy?(r[selection])
    }

    func deleteSelection() {
        let r = results
        guard r.indices.contains(selection) else { return }
        store.delete(r[selection])
        selection = min(selection, max(0, results.count - 1))
    }

    func pinSelection() {
        let r = results
        guard r.indices.contains(selection) else { return }
        store.togglePin(r[selection])
    }

    /// Number 1…9 quick-select.
    func quickSelect(_ n: Int, plain: Bool = false) {
        let r = results
        guard r.indices.contains(n - 1) else { return }
        onPaste?(r[n - 1], plain)
    }
}
