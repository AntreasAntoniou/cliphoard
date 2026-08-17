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
    @Published var activeUserTags: Set<String> = []
    @Published var selection: Int = 0
    /// Bumped each time the bar is presented so the UI can reset scroll/state.
    @Published var presentToken: Int = 0
    /// Set by keyboard navigation to request the strip scroll a card into view.
    /// Mouse clicks deliberately do NOT set this — a clicked card is already
    /// under the cursor, so re-centering it would feel like lag.
    @Published var scrollRequest: Int = 0
    /// When true the bar shows the settings surface instead of the card strip.
    @Published var showSettings: Bool = false
    /// Clip currently expanded into the detail supercard.
    @Published var inspectedItem: ClipItem?
    /// Whether the inspector should scroll directly to its tag editor.
    @Published var inspectorFocusTags: Bool = false

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
    /// invalidate the cache.
    ///
    /// That pair is not sufficient on its own — an in-place mutation touching neither
    /// goes undetected — and image recognition is exactly such a mutation: it rewrites an
    /// existing clip's searchable text without adding or removing anything. Without
    /// `imageRevision` here, a screenshot stays unfindable until the next copy, and the
    /// whole feature reads as broken. Hence a real counter rather than another proxy.
    private struct ResultsKey: Equatable {
        let query: String
        let activeKind: ClipKind?
        let pinnedOnly: Bool
        let timeFilter: TimeFilter
        let facets: Set<Int>
        let userTags: Set<String>
        let mode: SearchMode
        let itemCount: Int
        let lastAddedID: UUID?
        let imageRevision: Int
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
            userTags: activeUserTags,
            mode: DeepSearch.mode,
            itemCount: store.items.count,
            lastAddedID: store.lastAddedID,
            imageRevision: store.imageUnderstandingRevision
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

        // Pictures only, ranked by what they LOOK like. Deliberately not folded into the
        // other modes: this one CHANGES THE CORPUS as well as the ranking, hiding every
        // text, link, colour and file clip. That is the whole point — with 19 images among
        // 169 clips, a picture that matches weakly still loses to text that matches
        // strongly, so the only reliable way to search pictures is to search only pictures.
        //
        // An empty query lists every image rather than nothing, so the mode doubles as a
        // browse-my-pictures view and never looks broken before you have typed anything.
        if DeepSearch.mode == .image {
            let scoped = store.filtered(kind: .image, query: "", pinnedOnly: pinnedOnly,
                                        facets: activeFacets, userTags: activeUserTags,
                                        time: time)
            guard !q.isEmpty else { return scoped }
            let allowed = Set(scoped.map(\.id))
            let ranked = store.imagesMatching(q, limit: 200)
                .filter { allowed.contains($0.0.id) }
                .map(\.0)
            // Below-floor images are DROPPED, not appended. In every other mode a weak
            // result costs nothing because strong ones sit above it; here there is nothing
            // above it, so padding the list would present noise as the answer.
            return ranked
        }

        // Exact (or empty query) → substring filter, scoped by kind/pin/time/facets.
        if DeepSearch.mode == .exact || q.isEmpty {
            return store.filtered(kind: activeKind, query: q, pinnedOnly: pinnedOnly,
                                  facets: activeFacets, userTags: activeUserTags, time: time)
        }
        // Kind/pinned/time/facet scope first (no substring), then semantic search.
        let scoped = store.filtered(kind: activeKind, query: "", pinnedOnly: pinnedOnly,
                                    facets: activeFacets, userTags: activeUserTags, time: time)
        let embedder = EmbedderProvider.active
        switch DeepSearch.mode {
        case .exact, .image:
            // `.image` returned above; listed here so the switch stays EXHAUSTIVE without a
            // `default:`. A default would silently absorb any future mode into the text
            // path, which is how a new mode ships doing something plausible and wrong.
            return scoped
        case .tag:
            // Explicit user labels win over inferred automatic categories.
            let userTagged = store.items(withUserTag: q)
            if !userTagged.isEmpty {
                let ids = Set(userTagged.map(\.id))
                return scoped.filter { ids.contains($0.id) }
            }
            // Otherwise map the query to its nearest preset tag and intersect
            // the pre-tagged entries with the current scope.
            guard let tag = TagSpace.nearestTag(toQuery: q, embedder: embedder) else { return [] }
            let ids = Set(store.items(taggedWith: tag).map { $0.id })
            return scoped.filter { ids.contains($0.id) }
        case .neural:
            // Pure model-based semantic ranking (cosine only, no substring/tags).
            return withPixelMatches(for: q, into:
                SemanticRanker.neural(query: q, items: scoped, embedder: embedder),
                scoped: scoped)
        case .smart:
            // Clever hybrid: exact hits first, then blended neural + shared-tag topic.
            return withPixelMatches(for: q, into:
                SemanticRanker.smart(query: q, items: scoped, embedder: embedder),
                scoped: scoped)
        }
    }

    /// Fold joint text-pixel matches into a text ranking, APPENDING rather than reordering.
    ///
    /// The two scores live in different spaces and are not comparable — a 192-d OpenVision
    /// cosine and a 1024-d ogma cosine calibrate differently, which is exactly why
    /// `relevanceFloor` travels with each embedder. Interleaving them would require a
    /// fusion weight nobody has measured, and the most likely outcome of guessing one is
    /// that a mediocre pixel match outranks a correct OCR hit. That is the single most
    /// plausible way this feature ships and quietly makes search WORSE, so it does not
    /// happen here: the text ranking is preserved intact, and pixel-only matches are added
    /// underneath it.
    ///
    /// What this buys is the whole point of the model. An image with no recognised text
    /// cannot appear in the text ranking at ALL — there is nothing to match — so anything
    /// this appends is a clip that was previously unreachable by typing. On the reference
    /// store that is five clips, 28% of the images.
    private func withPixelMatches(for query: String, into ranked: [ClipItem],
                                  scoped: [ClipItem]) -> [ClipItem] {
        let matches = store.imagesMatching(query)
        guard !matches.isEmpty else { return ranked }
        // Respect the active scope (kind/pin/time/facets) — the pixel index is not a way
        // around a filter the user set.
        let allowed = Set(scoped.map(\.id))
        let already = Set(ranked.map(\.id))
        let extra = matches
            .filter { allowed.contains($0.0.id) && !already.contains($0.0.id) }
            .map(\.0)
        return ranked + extra
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
        // The store already refuses while frozen, so no data is at risk — but a shortcut
        // that silently does nothing reads as a broken app. AppKit's standard "this is
        // unavailable" signal, the same one a disabled key equivalent produces. The
        // safe-mode banner is already on screen and names the reason.
        guard !store.safeMode else { NSSound.beep(); return }
        store.delete(r[selection])
        selection = min(selection, max(0, results.count - 1))
    }

    func pinSelection() {
        let r = results
        guard r.indices.contains(selection) else { return }
        store.togglePin(r[selection])
    }

    func inspect(_ item: ClipItem, focusTags: Bool = false) {
        inspectorFocusTags = focusTags
        inspectedItem = item
    }

    func inspectSelection(focusTags: Bool = false) {
        let results = results
        guard results.indices.contains(selection) else { return }
        inspect(results[selection], focusTags: focusTags)
    }

    func closeInspector() {
        inspectedItem = nil
        inspectorFocusTags = false
    }

    /// Number 1…9 quick-select.
    func quickSelect(_ n: Int, plain: Bool = false) {
        let r = results
        guard r.indices.contains(n - 1) else { return }
        onPaste?(r[n - 1], plain)
    }
}
