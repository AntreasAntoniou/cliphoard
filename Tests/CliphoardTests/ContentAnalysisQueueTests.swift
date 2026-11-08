import XCTest
@testable import Cliphoard

private actor ScreeningSpy: ContentModelEvaluating {
    var calls: [String] = []
    var shouldMatch: Bool
    init(match: Bool = false) { shouldMatch = match }
    func text(_ text: String) async throws -> Bool { calls.append("text"); return false }
    func image(_ data: Data) async throws -> Bool { calls.append("image"); return shouldMatch }
    func media(_ url: URL, video: Bool, audio: Bool, cache: URL, admit: @escaping @Sendable () async -> Bool) async throws -> Bool {
        guard await admit() else { throw NSFWModelEvaluator.Failure.stale }
        calls.append("media"); return shouldMatch
    }
    func reset() async { }
}

@MainActor final class ContentAnalysisQueueTests: XCTestCase {
    private var saved: [String: Any] = [:]
    private let keys = ["nsfwEnabled", "nsfwFocusOnly", "nsfwImagesEnabled", "nsfwAudioEnabled", "nsfwVideoEnabled", "documentTextEnabled", "documentPDFEnabled", "documentRichTextEnabled", "documentTagsEnabled", "deepSearchLevel"]
    override func setUp() {
        super.setUp()
        for k in keys { saved[k] = UserDefaults.standard.object(forKey: k); UserDefaults.standard.removeObject(forKey: k) }
        UserDefaults.standard.set("off", forKey: "deepSearchLevel")
    }
    override func tearDown() {
        for k in keys {
            if let v = saved[k] { UserDefaults.standard.set(v, forKey: k) }
            else { UserDefaults.standard.removeObject(forKey: k) }
        }
        FocusProtectionState.set(nil)
        super.tearDown()
    }
    private func finish(_ analysis: ContentAnalysisController) async throws {
        analysis.schedule()
        let deadline = Date().addingTimeInterval(5)
        while analysis.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(analysis.busy, "Queue must finish")
    }
    private func store() throws -> ClipStore {
        try skipIfKeychainUnreachable()
        let dir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("content-queue-" + UUID().uuidString)
        return ClipStore(directory: dir)
    }
    private func file(_ name: String, contents: String, store: ClipStore) throws -> ClipItem {
        let path = store.storeDirectory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: path)
        let item = ClipItem(kind: .file, text: name); item.filePath = path.path
        store.add(item); return item
    }
    func testFreeChecksEveryMediaPathButDoesNotReadAudioVideoContent() async throws {
        let s = try store(); s.entitlement = .free(reason: nil)
        let plain = try file("ordinary.mp4", contents: "fixture", store: s)
        let marked = try file("NSFW.wav", contents: "fixture", store: s)
        let spy = ScreeningSpy(); let a = ContentAnalysisController(store: s, evaluator: spy, monitorFocus: false)
        try await finish(a)
        let calls = await spy.calls
        XCTAssertFalse(calls.contains("media")); XCTAssertFalse(plain.flags.contains(.nsfw)); XCTAssertTrue(marked.flags.contains(.nsfw))
    }
    func testFreeImageAndProMediaAreAdmittedToTheirModels() async throws {
        let s = try store(); s.entitlement = .free(reason: nil)
        let image = try file("ordinary.png", contents: "fixture", store: s)
        let movie = try file("ordinary.mp4", contents: "fixture", store: s)
        let spy = ScreeningSpy(match: true); let a = ContentAnalysisController(store: s, evaluator: spy, monitorFocus: false)
        try await finish(a)
        XCTAssertTrue(image.flags.contains(.nsfw)); XCTAssertFalse(movie.flags.contains(.nsfw))
        s.entitlement = .pro(orderID: "synthetic-local-test", issued: .distantPast)
        a.refresh(); try await finish(a)
        XCTAssertTrue(movie.flags.contains(.nsfw)); let calls = await spy.calls; XCTAssertTrue(calls.contains("media"))
    }
    func testDisabledScreeningNeverCallsModelsButStillExtractsDocuments() async throws {
        let s = try store()
        UserDefaults.standard.set(false, forKey: "nsfwEnabled")
        UserDefaults.standard.set(true, forKey: "documentTextEnabled")
        let doc = try file("notes.txt", contents: "Orchid galaxy calibration notes", store: s)
        let spy = ScreeningSpy(); let a = ContentAnalysisController(store: s, evaluator: spy, monitorFocus: false)
        try await finish(a)
        let calls = await spy.calls; XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(doc.ocrText, "Orchid galaxy calibration notes")
        XCTAssertEqual(s.filtered(kind: nil, query: "orchid galaxy", pinnedOnly: false).map(\.id), [doc.id])
        UserDefaults.standard.set(false, forKey: "documentTextEnabled"); a.refresh()
        XCTAssertTrue(s.filtered(kind: nil, query: "orchid galaxy", pinnedOnly: false).isEmpty)
        XCTAssertEqual(doc.ocrText, "Orchid galaxy calibration notes", "Snapshot stays available in Inspect")
    }
    func testConfiguredFocusControlsScreeningAndReset() async throws {
        let s = try store(); let spy = ScreeningSpy()
        UserDefaults.standard.set(true, forKey: "nsfwFocusOnly"); FocusProtectionState.set(false)
        _ = try file("notes.txt", contents: "ordinary", store: s)
        let a = ContentAnalysisController(store: s, evaluator: spy, monitorFocus: false)
        try await finish(a); let before = await spy.calls; XCTAssertTrue(before.isEmpty)
        var intent = NSFWFocusFilter(); intent.protectNSFW = true; _ = try await intent.perform()
        a.refresh(); try await finish(a); let active = await spy.calls; XCTAssertFalse(active.isEmpty)
        _ = try await NSFWFocusFilter().perform()
        XCTAssertEqual(FocusProtectionState.active, false)
        a.refresh(); try await finish(a); let after = await spy.calls; XCTAssertEqual(after, active)
    }
}
