import XCTest
@testable import Cliphoard

// MARK: - The facet cube (10 dimensions × 10 tags)

@MainActor
final class DimensionalTagTests: XCTestCase {
    private let e = HashingEmbedder()

    override func setUp() { super.setUp(); TagBaskets.activeID = "general" }

    func testGeneralBasketIsA10x10Cube() {
        XCTAssertTrue(TagSpace.isDimensional)
        XCTAssertEqual(TagSpace.dimensionCount, 10)
        XCTAssertEqual(TagSpace.count, 100)
        XCTAssertTrue(TagSpace.dimensions.allSatisfy { $0.tags.count == 10 })
    }

    func testDimensionRangesAreContiguousDeciles() {
        for d in 0..<10 {
            XCTAssertEqual(TagSpace.range(ofDimension: d), (d * 10)..<(d * 10 + 10))
        }
    }

    func testDimensionOfTag() {
        XCTAssertEqual(TagSpace.dimension(ofTag: 0), 0)
        XCTAssertEqual(TagSpace.dimension(ofTag: 9), 0)
        XCTAssertEqual(TagSpace.dimension(ofTag: 10), 1)
        XCTAssertEqual(TagSpace.dimension(ofTag: 55), 5)
        XCTAssertEqual(TagSpace.dimension(ofTag: 99), 9)
    }

    func testClassifyDimensionsGivesOnePerDimensionInOrder() {
        let v = e.embed("def foo(): return 1   # some python code")
        let dims = TagSpace.classifyDimensions(v, embedder: e)
        XCTAssertEqual(dims.count, TagSpace.dimensionCount, "a value on every axis")
        for (d, id) in dims.enumerated() {
            XCTAssertTrue(TagSpace.range(ofDimension: d).contains(id),
                          "dimension \(d) must pick a tag from its own decile, got \(id)")
        }
    }

    func testIndexerTagsAreDimensionalForCube() {
        let v = e.embed("select * from users")
        XCTAssertEqual(ClipIndexer.tags(for: v, embedder: e).count, TagSpace.dimensionCount)
    }

    func testFacetLabelsPairDimensionWithValue() {
        // ids 1 (Content type slice) and 13 (Sensitivity slice) → labelled by axis.
        let labels = TagSpace.facetLabels(for: [1, 13])
        XCTAssertEqual(labels.count, 2)
        XCTAssertEqual(labels[0].dimension, TagSpace.dimensions[0].name)
        XCTAssertEqual(labels[1].dimension, TagSpace.dimensions[1].name)
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
    }
    override func tearDown() { DeepSearch.level = .off; super.tearDown() }

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
        // Content type: 1=code, 2=link. Domain: 10=software, 11=web.
        let a = clip("a", tags: [1, 10])   // code + software
        let b = clip("b", tags: [1, 11])   // code + web
        let c = clip("c", tags: [2, 10])   // link + software
        store.add(a); store.add(b); store.add(c)

        // Single facet → its bucket.
        XCTAssertEqual(Set(store.items(matchingFacets: [1]).map { $0.text }), ["a", "b"])
        // Same dimension (Domain 10 OR 11) → union.
        XCTAssertEqual(Set(store.items(matchingFacets: [10, 11]).map { $0.text }), ["a", "b", "c"])
        // Across dimensions (code AND software) → intersection.
        XCTAssertEqual(Set(store.items(matchingFacets: [1, 10]).map { $0.text }), ["a"])
        // Across dimensions with an OR leg: (code) AND (software OR web) → a, b.
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
