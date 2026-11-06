import XCTest
@testable import Cliphoard

final class CardResponsivenessTests: XCTestCase {
    private func clip(_ i: Int) -> ClipItem {
        let item = ClipItem(kind: .image, text: "Screenshot of the red bicycle near the library, note \(i)")
        item.ocrText = "Meeting notes and a sketch of the afternoon route."
        item.sourceApp = "Preview"
        return item
    }

    // Read-only synthetic items: no store, clipboard, model, network or Keychain.
    func testLargeHistorySensitivityBenchmark() {
        for count in [1_000, 8_000, 32_000] {
            let items = (0..<count).map(clip)
            for pass in 1...2 {
                let start = Date()
                let protected = items.reduce(0) { $0 + (SensitiveClipPolicy.requiresAuthentication($1) ? 1 : 0) }
                let elapsed = Date().timeIntervalSince(start) * 1_000
                XCTAssertEqual(protected, 0)
                print("PERF sensitivity items=\(count) pass=\(pass) ms=\(elapsed)")
            }
        }
    }

    func testEverySensitiveFieldInvalidatesAPreviousClearVerdict() {
        let secret = "whsec_" + "A1b2C3d4E5f6G7h8I9j0"
        let mutations: [(ClipItem) -> Void] = [
            { $0.text = secret }, { $0.ocrText = secret }, { $0.filePath = secret },
            { $0.colorHex = secret }, { $0.sourceApp = "1Password" },
            { $0.userTags.append(secret) }, { $0.flags.insert(.secret) },
            { $0.rtf = Data([1, 2, 3]) }
        ]
        for mutate in mutations {
            let item = clip(0)
            XCTAssertFalse(SensitiveClipPolicy.requiresAuthentication(item))
            let before = SensitiveClipPolicy.fingerprint(item)
            mutate(item)
            XCTAssertTrue(SensitiveClipPolicy.requiresAuthentication(item))
            XCTAssertNotEqual(before, SensitiveClipPolicy.fingerprint(item))
        }
    }

    func testFingerprintTracksPayloadKindAndInPlaceTextEdits() {
        let item = clip(0)
        for mutate in [{ (c: ClipItem) in c.payloadFile = "changed.png" },
                       { c in c.kind = .text }, { c in c.text.append(" changed") }] {
            let before = SensitiveClipPolicy.fingerprint(item)
            mutate(item)
            XCTAssertNotEqual(before, SensitiveClipPolicy.fingerprint(item))
        }
    }
    func testRepositionMatchesStableSortAcrossTiesAndPinChanges() {
        var items = (0..<200).map(clip)
        for (i, item) in items.enumerated() {
            item.pinned = i % 5 == 0
            item.lastUsedAt = Date(timeIntervalSince1970: Double(i % 17))
        }
        items.sort(by: ClipOrdering.precedes)
        for step in 0..<1_000 {
            let item = items[(step * 37) % items.count]
            if step % 2 == 0 { item.pinned.toggle() }
            else { item.lastUsedAt = Date(timeIntervalSince1970: Double(step % 23)) }
            let expected = items.sorted(by: ClipOrdering.precedes).map(\.id)
            ClipOrdering.reposition(item, in: &items)
            XCTAssertEqual(items.map(\.id), expected, "step \(step)")
        }
        let before = items.map(\.id)
        ClipOrdering.reposition(clip(-1), in: &items)
        XCTAssertEqual(items.map(\.id), before)
    }

    func testDisplayedRowsPreserveOriginalKeyboardIndices() {
        let items = (0..<8_000).map(clip)
        let all = DisplayedClips(items)
        XCTAssertEqual(all.count, 8_000)
        XCTAssertEqual(all[7_999].id, items[7_999].id)
        let filtered = DisplayedClips(items, visibleIndices: [2, 70, 7_999])
        XCTAssertEqual(filtered.map(\.index), [2, 70, 7_999])
        XCTAssertEqual(filtered.map(\.id), [items[2].id, items[70].id, items[7_999].id])
        XCTAssertEqual(Array(filtered.dropFirst()).map(\.index), [70, 7_999])
        XCTAssertTrue(DisplayedClips(items, visibleIndices: []).isEmpty)
    }

    func testLongCardPreviewPreservesFullTextAndUnicode() throws {
        let original = String(repeating: "👨‍👩‍👧‍👦", count: 20_000)
        let item = ClipItem(kind: .text, text: original)
        XCTAssertEqual(item.cardText.count, 2_049)
        XCTAssertEqual(item.text, original)
        XCTAssertEqual(item.characterCountLabel, "20000 characters")
        let encoded = try JSONEncoder().encode(item)
        let restored = try JSONDecoder().decode(ClipItem.self, from: encoded)
        XCTAssertEqual(restored.text, original)
        item.text = "a"
        XCTAssertEqual(item.cardText, "a")
        XCTAssertEqual(item.characterCountLabel, "1 character")
    }

    func testImageTopKMatchesFullSortIncludingTiesAndIncompatibleFeatures() throws {
        typealias F = InspectorImageSearch.Feature
        let query = F(id: UUID(), revision: 2, vector: [1, 0])
        var candidates = (0..<8_000).map { i in
            F(id: UUID(), revision: 2, vector: [Float(i % 17) / 17, 1])
        }
        candidates += [query, F(id: UUID(), revision: 1, vector: [1, 0]),
                       F(id: UUID(), revision: 2, vector: [1])]
        let reference = candidates.filter {
            $0.id != query.id && $0.revision == query.revision && $0.vector.count == query.vector.count
        }.map { ($0.id, ImageUnderstanding.similarity(query.vector, $0.vector)) }
            .sorted { $0.1 > $1.1 }.prefix(8).map { $0.0 }
        XCTAssertEqual(try InspectorImageSearch.rank(query: query, candidates: candidates, limit: 8), reference)
        XCTAssertEqual(try InspectorImageSearch.rank(query: query, candidates: candidates, limit: 0), [])
    }

    func testCancelledImageSearchCannotPublishResults() async {
        let query = InspectorImageSearch.Feature(id: UUID(), revision: 2, vector: [1, 0])
        let task = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return try await InspectorImageSearch.search(query: query, candidates: [query], limit: 8)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled search returned a result") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testLargeHistoryOrderingBenchmark() {
        for count in [8_000, 32_000] {
            var items = (0..<count).map(clip)
            items.sort(by: ClipOrdering.precedes)
            var fullSort = items
            let moved = items[count / 2]
            moved.pinned = true
            var start = Date()
            fullSort.sort(by: ClipOrdering.precedes)
            let old = Date().timeIntervalSince(start) * 1_000
            start = Date()
            ClipOrdering.reposition(moved, in: &items)
            let new = Date().timeIntervalSince(start) * 1_000
            XCTAssertEqual(items.map(\.id), fullSort.map(\.id))
            print("PERF order items=\(count) fullSortMs=\(old) repositionMs=\(new)")
        }
    }

}
