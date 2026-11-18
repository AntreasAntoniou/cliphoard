import AppKit
import XCTest
@testable import Cliphoard

@MainActor
final class CapturePauseTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var defaultsName: String!
    private var pasteboard: NSPasteboard!
    private var state: CaptureState!
    private var store: ClipStore!
    private var monitor: ClipboardMonitor!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defaultsName = "CapturePauseTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)!
        pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        state = CaptureState(defaults: defaults)
        store = ClipStore(directory: directory)
        monitor = ClipboardMonitor(store: store, pasteboard: pasteboard, captureState: state)
    }

    override func tearDown() {
        monitor.stop()
        monitor = nil
        store = nil
        pasteboard.releaseGlobally()
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func testPauseDropsCopiesAndResumeOnlyCapturesNewCopies() {
        copy("before pause")
        monitor.poll()
        XCTAssertEqual(store.items.map(\.text), ["before pause"])
        state.setPaused(true)
        copy("private while paused")
        monitor.poll()
        XCTAssertEqual(store.items.count, 1)
        state.setPaused(false)
        monitor.poll()
        XCTAssertEqual(store.items.count, 1)
        copy("after resume")
        monitor.poll()
        XCTAssertEqual(Set(store.items.map(\.text)), ["before pause", "after resume"])
    }

    func testQuickPauseAndResumeSkipsContentWithoutAnInterveningPoll() {
        state.setPaused(true)
        copy("private between ticks")
        state.setPaused(false)
        monitor.poll()
        XCTAssertTrue(store.items.isEmpty)
        copy("new copy")
        monitor.poll()
        XCTAssertEqual(store.items.map(\.text), ["new copy"])
    }

    func testPauseSurvivesRestartAndUpdateWithSamePreferences() {
        state.setPaused(true)
        let restored = CaptureState(defaults: defaults)
        XCTAssertTrue(restored.isPaused)
        let restarted = ClipboardMonitor(store: store, pasteboard: pasteboard, captureState: restored)
        copy("private after restart")
        restarted.poll()
        restored.setPaused(false)
        restarted.poll()
        XCTAssertTrue(store.items.isEmpty)
        copy("resumed after restart")
        restarted.poll()
        XCTAssertEqual(store.items.map(\.text), ["resumed after restart"])
        XCTAssertFalse(CaptureState(defaults: defaults).isPaused)
        restarted.stop()
    }

    func testResumeDoesNotOverridePassphraseCaptureSuspension() {
        state.setPaused(true)
        ClipboardMonitor.suspendCapture()
        defer { ClipboardMonitor.resumeCapture() }
        state.setPaused(false)
        copy("private passphrase sheet")
        monitor.poll()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertGreaterThan(ClipboardMonitor.captureSuspensions, 0)
    }

    func testInFlightImageRewriteCannotCrossPauseResumeBoundary() {
        let originalGeneration = monitor.captureGeneration
        state.setPaused(true)
        state.setPaused(false)
        pasteboard.clearContents()
        pasteboard.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("public.heic"))
        let count = pasteboard.changeCount
        monitor.applyWebSafe(png: Data([4, 5, 6]), expecting: count, generation: originalGeneration)
        XCTAssertEqual(pasteboard.changeCount, count)
        XCTAssertNil(pasteboard.data(forType: .png))
    }

    func testRunningTimerUsesTheSamePauseAndResumeControls() async throws {
        monitor.start()
        monitor.start()
        copy("timer before pause")
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(store.items.map(\.text), ["timer before pause"])
        state.toggle()
        copy("timer private copy")
        try await Task.sleep(nanoseconds: 700_000_000)
        state.toggle()
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(store.items.map(\.text), ["timer before pause"])
        copy("timer resumed copy")
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(Set(store.items.map(\.text)), ["timer before pause", "timer resumed copy"])
    }

    func testOwnPasteSuppressionStillWorksAfterResume() {
        state.setPaused(true)
        state.setPaused(false)
        copy("own paste")
        monitor.suppressOwnWrite()
        monitor.poll()
        XCTAssertTrue(store.items.isEmpty)
        copy("new external copy")
        monitor.poll()
        XCTAssertEqual(store.items.map(\.text), ["new external copy"])
    }
}
