import XCTest
@testable import Cliphoard

// MARK: - The hybrid facet basket (surviving 8-wide axes + topical pool)
//
// Wave 4 retired the four abstract axes (design §4), so General now carries ZERO
// axes and the axis MACHINERY is exercised through a specialist overlay, which is
// where the surviving concrete axes live. The numbers below were tightened, not
// relaxed: every assertion that used to say "4 axes / 48 tags" now names the
// smaller, exact truth. Per-basket axis counts are pinned in CoarseTopicTests.

@MainActor
final class DimensionalTagTests: XCTestCase {
    private let e = HashingEmbedder()

    override func setUp() {
        super.setUp()
        TagBaskets.activeID = "general"
        TagBaskets.overlayID = nil
    }
    override func tearDown() { TagBaskets.overlayID = nil; super.tearDown() }

    /// General is still a hybrid basket — it just has no axes left to force onto
    /// a clip — and, after design §4 struck the topical word tags too, no tag
    /// space at all. Every chip a General user sees is deterministic.
    func testGeneralBasketHasNoModelDerivedVocabulary() {
        XCTAssertTrue(TagSpace.isDimensional, "still hybrid, not a flat pool")
        XCTAssertEqual(TagSpace.dimensionCount, 0, "all four abstract axes are retired")
        XCTAssertEqual(TagSpace.count, 0, "the topical word tags were struck too")
        XCTAssertTrue(TagSpace.topicalRange.isEmpty)
    }

    func testDimensionRangesAreContiguousEightWideSlices() {
        // Developer keeps two concrete axes (Artifact, Language); General adds none.
        TagBaskets.overlayID = "dev"
        XCTAssertEqual(TagSpace.dimensionCount, 2)
        for d in 0..<2 {
            XCTAssertEqual(TagSpace.range(ofDimension: d), (d * 8)..<(d * 8 + 8))
        }
        XCTAssertEqual(TagSpace.range(ofDimension: 2), 0..<0, "no third axis exists")
    }

    func testDimensionOfTag() {
        TagBaskets.overlayID = "dev"
        XCTAssertEqual(TagSpace.dimension(ofTag: 0), 0)
        XCTAssertEqual(TagSpace.dimension(ofTag: 7), 0)
        XCTAssertEqual(TagSpace.dimension(ofTag: 8), 1)
        XCTAssertEqual(TagSpace.dimension(ofTag: 15), 1)
        XCTAssertNil(TagSpace.dimension(ofTag: 16), "topical tags do not belong to an axis")

        TagBaskets.overlayID = nil
        XCTAssertNil(TagSpace.dimension(ofTag: 0), "General has no axis to own id 0")
    }

    func testClassifyDimensionsGivesOnePerDimensionInOrder() {
        TagBaskets.overlayID = "dev"
        let v = e.embed("def foo(): return 1   # some python code")
        let dims = TagSpace.classifyDimensions(v, embedder: e)
        XCTAssertLessThanOrEqual(dims.count, TagSpace.dimensionCount,
                                 "confidence gating may intentionally leave axes blank")
        for id in dims {
            guard let owner = TagSpace.dimension(ofTag: id) else {
                return XCTFail("axis classification returned topical id \(id)")
            }
            XCTAssertTrue(TagSpace.range(ofDimension: owner).contains(id))
        }
    }

    func testIndexerTagsAreDimensionalForCube() {
        let v = e.embed("select * from users")
        XCTAssertLessThanOrEqual(ClipIndexer.tags(for: v, embedder: e).count, 3,
                                 "General: three topical tags and no axes at all")
        TagBaskets.overlayID = "dev"
        XCTAssertLessThanOrEqual(ClipIndexer.tags(for: v, embedder: e).count, 5,
                                 "at most two axes plus three topical tags")
    }

    func testFacetLabelsPairDimensionWithValue() {
        TagBaskets.overlayID = "dev"
        // ids 1 (Artifact slice) and 9 (Language slice) → labelled by axis; 20 is
        // topical and carries no axis label.
        let labels = TagSpace.facetLabels(for: [1, 9, 20])
        XCTAssertEqual(labels.count, 2)
        XCTAssertEqual(labels[0].dimension, TagSpace.dimensions[0].name)
        XCTAssertEqual(labels[1].dimension, TagSpace.dimensions[1].name)
    }

    /// General emits no facet labels at all now — there is no axis to label with.
    func testGeneralProducesNoFacetLabels() {
        XCTAssertTrue(TagSpace.facetLabels(for: [0, 1, 2]).isEmpty)
    }

    func testWeakSimilarityAssignsNoAutomaticTags() {
        struct PerpendicularEmbedder: TextEmbedder {
            let dimension = 2
            let signature = "perpendicular-tags-v1"
            func embed(_ text: String) -> [Float] { [0, 1] }
        }
        let weak: [Float] = [1, 0]
        let embedder = PerpendicularEmbedder()
        XCTAssertTrue(TagSpace.classifyDimensions(weak, embedder: embedder).isEmpty,
                      "weak axis matches must leave the axes blank")
        XCTAssertTrue(TagSpace.classify(weak, embedder: embedder, topK: 3).isEmpty,
                      "weak topical matches must not manufacture tags")
    }

    /// The hybrid SHAPE survives the retirement even though the axis COUNT fell:
    /// every basket is still dimensional, every surviving axis is still 8-wide,
    /// and the tag list is still exactly "axes then topical". The exact per-basket
    /// axis counts (and that each one went DOWN) are pinned in `RetiredAxisTests`.
    func testEveryBuiltInBasketUsesTheHybridShape() {
        XCTAssertEqual(TagBaskets.builtIn.count, 11)
        for basket in TagBaskets.builtIn {
            XCTAssertTrue(basket.isDimensional, basket.name)
            XCTAssertLessThan(basket.dimensions.count, 4,
                              "\(basket.name) must have shed at least one abstract axis")
            XCTAssertTrue(basket.dimensions.allSatisfy { $0.tags.count == 8 }, basket.name)
            XCTAssertEqual(basket.tags.count,
                           basket.dimensions.count * 8 + basket.topical.count, basket.name)
            // The old invariant "every basket carries exactly 16 topical words" is
            // GONE by design: those words either duplicated a deterministic
            // detector (url/path/command/code/color/email/phone/password …) or had
            // no glance action, so they were struck per design §4. What remains is
            // the layout rule — axes first, then a tail — plus the ban on
            // re-introducing a term a detector already emits exactly.
            let deterministic: Set<String> = ["url", "path", "link", "email", "address", "phone",
                                              "code", "color", "command", "password", "amount",
                                              "id", "env-var", "endpoint"]
            XCTAssertTrue(Set(basket.topical).isDisjoint(with: deterministic),
                          "\(basket.name) re-introduces a term a detector already emits exactly")
        }
        // General is the default experience: it must emit NO model-derived tags.
        XCTAssertTrue(TagBaskets.general.tags.isEmpty,
                      "General must produce no model-guessed labels at all")
    }
}

// MARK: - Facet filtering (OR within a dimension, AND across dimensions)

@MainActor
final class FacetFilterTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Feedback.soundEnabled = false
        DeepSearch.level = .normal
        TagBaskets.activeID = "general"
        // OR-within / AND-across is a property of AXES, and General no longer has
        // any (the four abstract ones were retired). Developer is the smallest
        // basket that still carries two concrete axes — Artifact on ids 0..<8 and
        // Language on ids 8..<16 — which is exactly the id layout this suite uses.
        TagBaskets.overlayID = "dev"
    }
    override func tearDown() {
        TagBaskets.overlayID = nil
        DeepSearch.level = .off
        super.tearDown()
    }

    private func tempStore() -> ClipStore {
        ClipStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoTests-facet-\(UUID().uuidString)"))
    }

    /// A usable (non-degenerate, right-length) vector so `add` keeps the tags we
    /// set rather than re-classifying (the clip isn't stale).
    private func usableVector() -> [Float] {
        let dim = EmbedderProvider.active.dimension
        var v = [Float](repeating: 0, count: dim); v[3] = 1
        return v
    }

    private func clip(_ text: String, tags: [Int]) -> ClipItem {
        let item = ClipItem(kind: .text, text: text)
        item.embeddings[EmbedderProvider.active.signature] =
            ModelEmbedding(vector: usableVector(), tags: tags)
        return item
    }

    func testWithinDimensionOrAcrossDimensionAnd() {
        let store = tempStore()
        // Artifact: 1=config, 2=command. Language: 10=swift, 11=shell.
        let a = clip("a", tags: [1, 10])   // config + swift
        let b = clip("b", tags: [1, 11])   // config + shell
        let c = clip("c", tags: [2, 10])   // command + swift
        store.add(a); store.add(b); store.add(c)

        // Single facet → its bucket.
        XCTAssertEqual(Set(store.items(matchingFacets: [1]).map { $0.text }), ["a", "b"])
        // Same dimension (Language 10 OR 11) → union.
        XCTAssertEqual(Set(store.items(matchingFacets: [10, 11]).map { $0.text }), ["a", "b", "c"])
        // Across dimensions (config AND swift) → intersection.
        XCTAssertEqual(Set(store.items(matchingFacets: [1, 10]).map { $0.text }), ["a"])
        // Across dimensions with an OR leg: (config) AND (swift OR shell) → a, b.
        XCTAssertEqual(Set(store.items(matchingFacets: [1, 10, 11]).map { $0.text }), ["a", "b"])
        // Empty selection → everything.
        XCTAssertEqual(store.items(matchingFacets: []).count, 3)
    }

    func testFilteredComposesFacetsWithTime() {
        let store = tempStore()
        let a = clip("keep", tags: [1, 10])
        store.add(a)
        // Facet matches, time (this year) matches a freshly-added clip.
        XCTAssertEqual(store.filtered(kind: nil, query: "", pinnedOnly: false,
                                      facets: [1], time: .today).map { $0.text }, ["keep"])
        // A facet that no clip carries → empty.
        XCTAssertTrue(store.filtered(kind: nil, query: "", pinnedOnly: false,
                                     facets: [5]).isEmpty)
    }

    func testUserTagFacetsIntersectAutoAxes() {
        let store = tempStore()
        let matching = clip("matching", tags: [1, 8]); matching.userTags = ["client-acme"]
        let wrongAxis = clip("wrong axis", tags: [2, 8]); wrongAxis.userTags = ["client-acme"]
        let wrongUserTag = clip("wrong user", tags: [1, 8]); wrongUserTag.userTags = ["client-beta"]
        store.add(matching); store.add(wrongAxis); store.add(wrongUserTag)

        XCTAssertEqual(store.items(matchingFacets: [1], userTags: ["client-acme"]).map(\.text),
                       ["matching"], "user-tag group ANDs with the selected auto-tag axes")
    }
}

// MARK: - Time filter

final class TimeFilterTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func d(_ s: String) -> Date {
        let f = DateFormatter()
        f.calendar = cal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    func testTodayAndYesterday() {
        let now = d("2026-07-20 10:00")
        XCTAssertTrue(TimeFilter.today.contains(d("2026-07-20 00:05"), now: now, calendar: cal))
        XCTAssertFalse(TimeFilter.today.contains(d("2026-07-19 23:59"), now: now, calendar: cal))
        XCTAssertTrue(TimeFilter.yesterday.contains(d("2026-07-19 12:00"), now: now, calendar: cal))
        XCTAssertFalse(TimeFilter.yesterday.contains(d("2026-07-20 00:01"), now: now, calendar: cal))
    }

    func testLast7Window() {
        let now = d("2026-07-20 10:00")
        XCTAssertTrue(TimeFilter.last7.contains(d("2026-07-14 10:00"), now: now, calendar: cal))
        XCTAssertFalse(TimeFilter.last7.contains(d("2026-07-12 10:00"), now: now, calendar: cal))
    }

    func testCustomRangeIsDayInclusive() {
        let f = TimeFilter.range(d("2026-07-01 00:00"), d("2026-07-15 00:00"))
        XCTAssertTrue(f.contains(d("2026-07-01 00:00"), calendar: cal))
        XCTAssertTrue(f.contains(d("2026-07-15 23:30"), calendar: cal), "end day is inclusive")
        XCTAssertFalse(f.contains(d("2026-07-16 00:01"), calendar: cal))
        XCTAssertFalse(f.contains(d("2026-06-30 23:59"), calendar: cal))
    }

    func testAnyMatchesEverything() {
        XCTAssertTrue(TimeFilter.any.contains(d("1999-01-01 00:00"), now: d("2026-07-20 10:00"), calendar: cal))
    }
}

// MARK: - when: token parsing

final class WhenTokenTests: XCTestCase {
    func testParsesWordAndStripsToken() {
        let (f, rest) = WhenToken.parse("hello when:today world")
        XCTAssertEqual(f, .today)
        XCTAssertEqual(rest, "hello world")
    }

    func testAliases() {
        XCTAssertEqual(WhenToken.parse("when:yday").filter, .yesterday)
        XCTAssertEqual(WhenToken.parse("when:week").filter, .thisWeek)
        XCTAssertEqual(WhenToken.parse("when:month").filter, .thisMonth)
        XCTAssertEqual(WhenToken.parse("when:30d").filter, .last30)
    }

    func testSingleDateBecomesOneDayRange() {
        guard case .range(let a, let b)? = WhenToken.parse("when:2026-07-15").filter else {
            return XCTFail("expected a range")
        }
        XCTAssertEqual(a, b)
    }

    func testExplicitRange() {
        guard case .range? = WhenToken.parse("logs when:2026-07-01..2026-07-15").filter else {
            return XCTFail("expected a range")
        }
    }

    func testNoTokenLeavesQueryUntouched() {
        let (f, rest) = WhenToken.parse("just a normal query")
        XCTAssertNil(f)
        XCTAssertEqual(rest, "just a normal query")
    }

    func testUnparseableWhenValueYieldsNilFilter() {
        let (f, rest) = WhenToken.parse("when:someday")
        XCTAssertNil(f)
        XCTAssertEqual(rest, "")   // token still stripped
    }
}
