import XCTest
@testable import Cliphoard

/// Synthetic input and a controlled clock: no clipboard, models, DB or Keychain.
@MainActor
final class SearchInputControllerTests: XCTestCase {
    private actor Clock {
        var waits: [CheckedContinuation<Void, Never>?] = []
        var delays: [UInt64] = []
        func sleep(_ delay: UInt64) async {
            delays.append(delay)
            await withCheckedContinuation { waits.append($0) }
        }
        var count: Int { waits.count }
        func wake(_ index: Int) { waits[index]?.resume(); waits[index] = nil }
        func finish() { for i in waits.indices { wake(i) } }
    }

    private func waitFor(_ clock: Clock, count: Int) async {
        for _ in 0..<10_000 {
            if await clock.count >= count { return }
            await Task.yield()
        }
        XCTFail("The scheduled sleep did not register")
    }
    private func settle() async { for _ in 0..<30 { await Task.yield() } }

    func testTypingBurstCommitsOnlyTheLatestDraftAfterFullPause() async {
        let clock = Clock()
        let input = SearchInputController(timing: .pause, sleep: { await clock.sleep($0) })
        var queries: [String] = []
        input.onCommit = { queries.append($0) }
        input.updateDraft("c"); await waitFor(clock, count: 1)
        input.updateDraft("ca"); await waitFor(clock, count: 2)
        input.updateDraft("cat"); await waitFor(clock, count: 3)
        XCTAssertEqual(input.draft, "cat")
        XCTAssertEqual(input.submitted, "")
        XCTAssertTrue(queries.isEmpty)
        // Even a sleeper that ignores cancellation cannot publish an old query.
        await clock.wake(0); await clock.wake(1); await settle()
        XCTAssertTrue(queries.isEmpty)
        await clock.wake(2); await settle()
        XCTAssertEqual(queries, ["cat"])
        XCTAssertFalse(input.isPending)
        let delays = await clock.delays
        XCTAssertEqual(delays, [450_000_000, 450_000_000, 450_000_000])
    }

    func testReturnModeWaitsAndConsumesFirstReturnOnly() async {
        let clock = Clock()
        let input = SearchInputController(timing: .enter, sleep: { await clock.sleep($0) })
        var queries: [String] = []
        input.onCommit = { queries.append($0) }
        input.updateDraft("cat"); input.updateDraft("cats")
        await settle()
        let waits = await clock.count
        XCTAssertEqual(waits, 0)
        XCTAssertTrue(queries.isEmpty)
        XCTAssertTrue(input.submitPending()) // caller consumes Return without pasting
        XCTAssertEqual(queries, ["cats"])
        XCTAssertFalse(input.submitPending()) // normal selected-result action resumes
    }

    func testInstantModeCommitsEditsWithoutScheduling() {
        let input = SearchInputController(timing: .instant)
        var queries: [String] = []
        input.onCommit = { queries.append($0) }
        input.updateDraft("c"); input.updateDraft("ca"); input.updateDraft("cat")
        XCTAssertEqual(queries, ["c", "ca", "cat"])
        XCTAssertFalse(input.isPending)
    }

    func testClearingIsImmediateAndCannotBeUndoneByOldSleep() async {
        let clock = Clock()
        let input = SearchInputController(timing: .pause, sleep: { await clock.sleep($0) })
        var queries: [String] = []
        input.onCommit = { queries.append($0) }
        input.reset(to: "cats")
        input.updateDraft("dogs"); await waitFor(clock, count: 1)
        input.updateDraft("")
        XCTAssertEqual(queries, [""])
        await clock.finish(); await settle()
        XCTAssertEqual(input.submitted, "")
        XCTAssertEqual(queries, [""])
    }

    func testTimingChangeInvalidatesPendingPauseAndInstantFlushesIt() async {
        let clock = Clock()
        let input = SearchInputController(timing: .pause, sleep: { await clock.sleep($0) })
        var queries: [String] = []
        input.onCommit = { queries.append($0) }
        input.updateDraft("cat"); await waitFor(clock, count: 1)
        input.setTiming(.enter)
        await clock.finish(); await settle()
        XCTAssertTrue(queries.isEmpty)
        input.setTiming(.instant)
        XCTAssertEqual(queries, ["cat"])
    }

    func testDismissalOrProgrammaticResetFencesAnOldTask() async {
        let clock = Clock()
        let input = SearchInputController(timing: .pause, sleep: { await clock.sleep($0) })
        var queries: [String] = []
        input.onCommit = { queries.append($0) }
        input.updateDraft("old"); await waitFor(clock, count: 1)
        input.reset(to: "restored")
        await clock.finish(); await settle()
        XCTAssertEqual(input.draft, "restored")
        XCTAssertEqual(input.submitted, "restored")
        XCTAssertTrue(queries.isEmpty)
    }

    func testReturningToSubmittedTextDoesNotRepeatTheSearch() async {
        let clock = Clock()
        let input = SearchInputController(timing: .pause, sleep: { await clock.sleep($0) })
        input.reset(to: "cat")
        var queries: [String] = []
        input.onCommit = { queries.append($0) }
        input.updateDraft("cats"); await waitFor(clock, count: 1)
        input.updateDraft("cat")
        await clock.finish(); await settle()
        XCTAssertFalse(input.isPending)
        XCTAssertTrue(queries.isEmpty)
    }

    func testUnsetAndInvalidPreferencesDefaultToPauseAndSelectionPersists() throws {
        let name = "SearchTimingTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(SearchTiming.current(defaults), .pause)
        defaults.set("future-unknown", forKey: "searchTiming")
        XCTAssertEqual(SearchTiming.current(defaults), .pause)
        SearchTiming.save(.enter, defaults)
        XCTAssertEqual(SearchTiming.current(defaults), .enter)
        SearchTiming.save(.instant, defaults)
        XCTAssertEqual(SearchTiming.current(defaults), .instant)
    }

    func testProvisionalCompositionWaitsEvenInInstantMode() async {
        let clock = Clock()
        let input = SearchInputController(timing: .instant, sleep: { await clock.sleep($0) })
        var composing = true
        input.isComposing = { composing }
        var queries: [String] = []
        input.onCommit = { queries.append($0) }
        input.updateDraft("provisional"); await waitFor(clock, count: 1)
        XCTAssertFalse(input.submitPending())
        await clock.wake(0); await waitFor(clock, count: 2)
        XCTAssertTrue(queries.isEmpty)
        composing = false
        await clock.wake(1); await settle()
        XCTAssertEqual(queries, ["provisional"])
    }

    func testReturnModeStillRequiresSubmissionAfterComposition() async {
        let input = SearchInputController(timing: .enter)
        var composing = true
        input.isComposing = { composing }
        var queries: [String] = []
        input.onCommit = { queries.append($0) }
        input.updateDraft("provisional")
        XCTAssertFalse(input.submitPending())
        composing = false
        await settle()
        XCTAssertTrue(queries.isEmpty)
        XCTAssertTrue(input.submitPending())
        XCTAssertEqual(queries, ["provisional"])
    }
}
