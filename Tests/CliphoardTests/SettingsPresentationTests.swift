import XCTest
import AppKit
import SwiftUI
@testable import Cliphoard

@MainActor
final class SettingsPresentationTests: XCTestCase {
    func testSettingsUsesAvailableHeightInsteadOfTheHistoryStrip() {
        let screen = NSRect(x: 0, y: 24, width: 1440, height: 876)
        let frame = SettingsWindowController.settingsFrame(visible: screen)
        XCTAssertGreaterThan(frame.height, 800)
        XCTAssertEqual(frame.width, 980)
        XCTAssertTrue(screen.contains(frame))
        XCTAssertEqual(frame.midX, screen.midX)
        XCTAssertEqual(frame.midY, screen.midY)
    }

    func testSettingsClampsRememberedSizeOnSmallerAndNegativeOriginScreens() {
        for screen in [NSRect(x: -1280, y: 24, width: 1280, height: 696),
                       NSRect(x: 1440, y: -900, width: 900, height: 600),
                       NSRect(x: 0, y: 0, width: 480, height: 320)] {
            let frame = SettingsWindowController.settingsFrame(visible: screen,
                                                               preferred: NSSize(width: 4000, height: 3000))
            XCTAssertTrue(screen.contains(frame))
            XCTAssertGreaterThan(frame.height, 0)
            XCTAssertGreaterThan(frame.width, 0)
        }
    }

    func testSettingsPreservesAUsableUserChosenSizeAndRejectsMissingScreens() {
        let screen = NSRect(x: 100, y: 80, width: 2000, height: 1200)
        let requested = NSSize(width: 800, height: 650)
        XCTAssertEqual(SettingsWindowController.settingsFrame(visible: screen, preferred: requested).size,
                       requested)
        XCTAssertEqual(SettingsWindowController.settingsFrame(visible: .zero), .zero)
    }

    func testTagSummaryCountsTheMaintainedIndexIncludingZeroTagClips() {
        let a = ClipItem(kind: .text, text: "synthetic a")
        let b = ClipItem(kind: .text, text: "synthetic b")
        let untagged = ClipItem(kind: .text, text: "synthetic untagged")
        let otherModel = ClipItem(kind: .text, text: "synthetic other model")
        for item in [a, b, untagged] { item.embeddings["active"] = ModelEmbedding(vector: [1, 0]) }
        otherModel.embeddings["old"] = ModelEmbedding(vector: [1, 0])
        let index = [0: [a, b], 1: [a]]
        XCTAssertEqual(SettingsTagSummary.average(items: [a, b, untagged, otherModel],
                                                   tagIndex: index, signature: "active"), 1)
        XCTAssertEqual(SettingsTagSummary.average(items: [a, b], tagIndex: [:], signature: "active"), 0)
        XCTAssertEqual(SettingsTagSummary.average(items: [], tagIndex: [:], signature: "active"), 0)
    }

    func testOffscreenSettingsSectionsDoNotBuildTheirControlsDuringOpeningLayout() {
        final class Visits { var sections: Set<Int> = [] }
        let visits = Visits()
        let form = SettingsForm {
            ForEach(0..<40, id: \.self) { index in
                SettingsSection(title: "Synthetic section \(index)") {
                    let _ = visits.sections.insert(index)
                    Text("Synthetic controls").frame(height: 160)
                }
            }
        }
        let host = NSHostingController(rootView: form)
        host.view.frame = NSRect(x: 0, y: 0, width: 980, height: 740)
        host.view.layoutSubtreeIfNeeded()
        _ = host.sizeThatFits(in: NSSize(width: 980, height: 740))
        XCTAssertTrue(visits.sections.contains(0), "the visible section must actually be laid out")
        XCTAssertLessThan(visits.sections.count, 20,
                          "opening Settings must not construct the entire 40-section form")
        print("SETTINGS_LAZY_LAYOUT built=\(visits.sections.count) total=40")
    }
}

/// Measures the actual old classification operation and the replacement over
/// synthetic vectors. No ClipStore, Keychain, model download or user data is used.
@MainActor
final class SettingsSummaryPerformanceTests: XCTestCase {
    func testIndexedSummaryMatchesClassificationWithoutRepeatingIt() {
        let defaults = UserDefaults.standard
        let oldArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = oldArguments
        arguments["activeBasket"] = "general"
        arguments["overlayBaskets"] = [TagBaskets.developer.id, TagBaskets.writer.id, TagBaskets.finance.id]
        arguments["tagAssignmentThreshold"] = 0.1
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(oldArguments, forName: UserDefaults.argumentDomain) }

        let embedder = HashingEmbedder()
        let vector = embedder.embed("swift implementation architecture source code documentation")
        let assigned = ClipIndexer.tags(for: vector, embedder: embedder)
        XCTAssertFalse(TagSpace.names.isEmpty, "the benchmark needs a real nonempty vocabulary")
        for count in [200, 1000, 5000] {
            let items = (0..<count).map { index -> ClipItem in
                let item = ClipItem(kind: .text, text: "synthetic clip \(index)")
                item.embeddings[embedder.signature] = ModelEmbedding(vector: vector)
                return item
            }
            let tagIndex = Dictionary(uniqueKeysWithValues: assigned.map { ($0, items) })
            let oldStart = CFAbsoluteTimeGetCurrent()
            let oldTotal = items.reduce(0) { sum, item in
                sum + ClipIndexer.tags(for: item.embeddings[embedder.signature]!.vector,
                                       embedder: embedder).count
            }
            let oldMilliseconds = (CFAbsoluteTimeGetCurrent() - oldStart) * 1000
            let newStart = CFAbsoluteTimeGetCurrent()
            let summary = SettingsTagSummary.average(items: items, tagIndex: tagIndex,
                                                     signature: embedder.signature)
            let newMilliseconds = (CFAbsoluteTimeGetCurrent() - newStart) * 1000
            XCTAssertEqual(summary, Double(oldTotal) / Double(count))
            // Timings are evidence, not a flaky machine-speed correctness gate.
            print(String(format: "SETTINGS_SUMMARY clips=%d vocabulary=%d old_ms=%.3f indexed_ms=%.3f",
                         count, TagSpace.names.count, oldMilliseconds, newMilliseconds))
        }
    }
}
