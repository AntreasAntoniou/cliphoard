import XCTest
import AppKit
@testable import Cliphoard

/// Opening a file clip from the bar, and copying its path.
///
/// The click rule is the part that can go quietly wrong: "click again to paste" and
/// "double-click to open" are the same two clicks, so one of them had to give for file
/// clips, and the choice must not leak into any other clip kind. The rule is pure and static
/// (`PanelViewModel.clickAction`) so it is asserted here as arithmetic, then confirmed
/// through a live model; the AppKit wiring that cannot be driven headlessly (the mouse-down
/// monitor, the hide-before-open ordering, the key handler) is pinned at the source, bounded
/// by the next declaration and never by a character count.
@MainActor
final class FileClipActionsTests: XCTestCase {

    private var dir: URL!
    private var store: ClipStore!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliphoard-file-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = ClipStore(directory: dir)
    }

    override func tearDown() {
        store = nil
        if let dir { try? FileManager.default.removeItem(at: dir) }
        super.tearDown()
    }

    private func sourceRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: sourceRoot().appendingPathComponent(path), encoding: .utf8)
    }

    /// The body of a member, from its declaration to the earliest next declaration.
    private func body(of decl: String, in src: String) -> String? {
        guard let start = src.range(of: decl) else { return nil }
        let rest = src[start.upperBound...]
        let ends = ["\n    private ", "\n    static func ", "\n    func ", "\n    // MARK:",
                    "\n    @objc ", "\n    override "]
            .compactMap { rest.range(of: $0)?.lowerBound }
        return String(rest[..<(ends.min() ?? rest.endIndex)])
    }

    private func fileClip(at path: String) -> ClipItem {
        var item = ClipItem(kind: .file, text: path)
        item.filePath = path
        return item
    }

    private func tempFile(named name: String = "doc.pdf") throws -> String {
        let url = dir.appendingPathComponent(name)
        try Data("pdf".utf8).write(to: url)
        return url.path
    }

    // MARK: - The click rule, as arithmetic

    func testASingleClickOnAFileCardNeverPastes() {
        XCTAssertEqual(PanelViewModel.clickAction(kind: .file, clickCount: 1, alreadySelected: false), .select)
        XCTAssertEqual(PanelViewModel.clickAction(kind: .file, clickCount: 1, alreadySelected: true), .select,
                       "a file clip must not paste on a mouse click: a file URL pasted anywhere "
                       + "but Finder or a file well arrives as junk, and the second click of a "
                       + "double-click would otherwise paste before it could open")
    }

    func testADoubleClickOpensOnlyTheCardItSelected() {
        XCTAssertEqual(PanelViewModel.clickAction(kind: .file, clickCount: 2, alreadySelected: true), .open)
        XCTAssertEqual(PanelViewModel.clickAction(kind: .file, clickCount: 2, alreadySelected: false), .select,
                       "AppKit raises clickCount on time and proximity, so two quick clicks on "
                       + "adjacent list rows arrive with clickCount == 2 — without the "
                       + "already-selected guard they would open a file nobody double-clicked")
    }

    /// `allCases` is what makes a future kind fail loudly instead of inheriting a rule that
    /// was decided for files.
    func testEveryOtherKindKeepsTodaysClickRule() {
        for kind in ClipKind.allCases where kind != .file {
            for count in 1...3 {
                XCTAssertEqual(PanelViewModel.clickAction(kind: kind, clickCount: count, alreadySelected: true), .paste,
                               "\(kind) with clickCount \(count): a new ClipKind fell through the "
                               + "file rule — decide explicitly what a double-click means for it")
                XCTAssertEqual(PanelViewModel.clickAction(kind: kind, clickCount: count, alreadySelected: false), .select)
            }
        }
    }

    func testAnImposterTextClipIsNeverTreatedAsAFile() throws {
        let path = try tempFile()
        XCTAssertEqual(PanelViewModel.clickAction(kind: .text, clickCount: 2, alreadySelected: true), .paste,
                       "a text clip whose text happens to be a real path is still a text clip")
        try skipIfKeychainUnreachable()
        try XCTSkipIf(store.safeMode, "frozen store")
        store.add(ClipItem(kind: .text, text: path))
        let model = PanelViewModel(store: store)
        var verbs: [FileVerb] = []
        model.onFileVerb = { _, verb in verbs.append(verb) }
        XCTAssertFalse(model.fileVerb(.open), "fileVerb must refuse a non-file selection")
        XCTAssertTrue(verbs.isEmpty)
    }

    // MARK: - The live model routes it

    func testTheModelRoutesADoubleClickToOpenAndNeverToPaste() throws {
        try skipIfKeychainUnreachable()
        try XCTSkipIf(store.safeMode, "frozen store")
        let path = try tempFile()
        store.add(fileClip(at: path))
        let model = PanelViewModel(store: store)
        var pastes = 0, opens: [FileVerb] = []
        model.onPaste = { _, _ in pastes += 1 }
        model.onFileVerb = { _, verb in opens.append(verb) }
        XCTAssertEqual(model.results.first?.kind, .file)

        model.lastClickCount = 1; model.click(0)
        XCTAssertEqual(pastes, 0); XCTAssertEqual(opens, [])
        model.lastClickCount = 2; model.click(0)
        XCTAssertEqual(opens, [.open], "the second click of a double-click on the selected file card opens it")
        XCTAssertEqual(pastes, 0, "and never pastes")
    }

    /// The converse, so the fix cannot pass by breaking click-to-paste for everyone.
    func testATextClipStillPastesOnTheSecondClick() throws {
        try skipIfKeychainUnreachable()
        try XCTSkipIf(store.safeMode, "frozen store")
        // Two clips: a fresh model already has card 0 selected (the summon rule), so a click
        // on card 0 pastes at once — today's behaviour. The select-then-paste sequence is
        // observable on card 1.
        store.add(ClipItem(kind: .text, text: "first"))
        store.add(ClipItem(kind: .text, text: "second"))
        let model = PanelViewModel(store: store)
        var pastes = 0, opens = 0
        model.onPaste = { _, _ in pastes += 1 }
        model.onFileVerb = { _, _ in opens += 1 }
        model.lastClickCount = 1; model.click(1)
        XCTAssertEqual(pastes, 0, "the first click on an unselected card selects")
        model.lastClickCount = 1; model.click(1)
        XCTAssertEqual(pastes, 1, "click to select, click again to paste — unchanged for text")
        XCTAssertEqual(opens, 0)
    }

    /// Pins the reset that stops a stale count opening a file nobody double-clicked.
    func testTheClickCountIsConsumed() throws {
        try skipIfKeychainUnreachable()
        try XCTSkipIf(store.safeMode, "frozen store")
        store.add(fileClip(at: try tempFile()))
        let model = PanelViewModel(store: store)
        var opens = 0
        model.onFileVerb = { _, _ in opens += 1 }
        model.lastClickCount = 1; model.click(0)          // select
        model.lastClickCount = 2; model.click(0)          // open
        XCTAssertEqual(opens, 1)
        model.click(0)                                    // no mouse-down recorded in between
        XCTAssertEqual(opens, 1, "a tap with no mouse-down ahead of it must read as a single "
                       + "click, not inherit the previous double")
        XCTAssertEqual(model.lastClickCount, 1)
    }

    // MARK: - Availability

    func testOpenAndRevealNeedTheFileButCopyPathDoesNot() throws {
        let path = try tempFile()
        XCTAssertNil(FileClipAction.unavailableReason(path: path))
        try FileManager.default.removeItem(atPath: path)
        XCTAssertEqual(FileClipAction.unavailableReason(path: path), "file is missing")
        XCTAssertEqual(FileClipAction.unavailableReason(path: nil), "no path recorded")
        XCTAssertEqual(FileClipAction.unavailableReason(path: ""), "no path recorded")
        XCTAssertTrue(FileVerb.open.needsFile && FileVerb.reveal.needsFile)
        XCTAssertFalse(FileVerb.copyPath.needsFile,
                       "a path you can paste into a terminal is exactly what you want when "
                       + "you are trying to find out where the file went")
        // Injected existence, so the miss is testable without a filesystem.
        XCTAssertEqual(FileClipAction.unavailableReason(path: "/x", exists: { _ in false }), "file is missing")
    }

    func testADisabledFileItemCarriesItsReasonInItsTitle() {
        XCTAssertEqual(FileClipAction.title(.open, reason: "file is missing"), "Open (file is missing)")
        XCTAssertEqual(FileClipAction.title(.open, reason: nil), "Open")
        XCTAssertEqual(FileClipAction.title(.copyPath, reason: "file is missing"), "Copy Path",
                       "Copy Path does not need the file, so it never carries the reason")
    }

    func testTheMissingFileNoticeNamesThePath() {
        XCTAssertTrue(FileClipAction.missingMessage(path: "/tmp/gone.pdf").contains("/tmp/gone.pdf"),
                      "\"moved or deleted\" is only actionable if you can see WHICH file")
        XCTAssertTrue(FileClipAction.missingMessage(path: nil).contains("no file path"))
    }

    // MARK: - Wiring that cannot be driven headlessly

    func testBothContextMenusAndTheInspectorOfferTheFileVerbs() throws {
        let card = try source("Sources/Cliphoard/UI/ClipCardView.swift")
        let content = try source("Sources/Cliphoard/UI/ContentView.swift")
        let detail = try source("Sources/Cliphoard/UI/ClipDetailView.swift")
        // Exact counts: a file-wide `contains` is satisfiable by an unrelated call site.
        XCTAssertEqual(card.components(separatedBy: "FileClipMenuItems(").count - 1, 1)
        XCTAssertEqual(content.components(separatedBy: "FileClipMenuItems(").count - 1, 1)
        for src in [card, content] {
            guard let use = src.range(of: "FileClipMenuItems(") else { return XCTFail("no menu items") }
            let before = String(src[..<use.lowerBound].suffix(200))
            XCTAssertTrue(before.contains("item.kind == .file"),
                          "the file verbs must be gated on the clip being a file")
        }
        XCTAssertTrue(detail.contains("FileVerb.allCases") && detail.contains("FileClipAction.title("),
                      "the inspector must offer the same three verbs, with the same titles")
    }

    func testOpeningHidesTheBarBeforeItOpensAndDoesNotRestoreFocus() throws {
        let src = try source("Sources/Cliphoard/App/AppDelegate.swift")
        guard let body = body(of: "private func openInWorkspace(", in: src) else {
            return XCTFail("openInWorkspace was renamed — move this test with it")
        }
        guard let hide = body.range(of: "hide(paste: false, restoreFocus: false)") else {
            return XCTFail("opening must hide the bar WITHOUT restoring focus: the ordinary "
                           + "hide re-activates the app you came from, which would raise it "
                           + "back over Preview 0.2 s after we opened the document")
        }
        guard let open = body.range(of: "NSWorkspace.shared.") else { return XCTFail("no open call") }
        XCTAssertLessThan(hide.lowerBound, open.lowerBound,
                          "hide FIRST: hide sets isClosing synchronously and onResignKey guards "
                          + "on it, so the resign that Preview's activation causes is swallowed "
                          + "instead of firing a second dismissal")
    }

    func testTheKeyHandlerCarriesCommandOAndCopyPath() throws {
        let src = try source("Sources/Cliphoard/App/AppDelegate.swift")
        guard let body = body(of: "private func handleKey(", in: src) else {
            return XCTFail("handleKey was renamed")
        }
        XCTAssertTrue(body.contains("case kVK_ANSI_O where cmd:"), "⌘O must open the selected file clip")
        XCTAssertTrue(body.contains("model.fileVerb(.copyPath)"), "⌥⌘C must copy a file clip's path")
        guard let copyPath = body.range(of: "model.fileVerb(.copyPath)") else { return }
        let after = String(body[copyPath.upperBound...].prefix(120))
        XCTAssertTrue(after.contains("model.copySelection()"),
                      "on a non-file clip ⌥⌘C must fall back to copying the clip, exactly as "
                      + "before — a chord that silently does nothing reads as a broken app")
    }

    func testTheReadmeDocumentsTheFileShortcuts() throws {
        let readme = try source("README.md")
        XCTAssertTrue(readme.contains("| `⌘O` |"), "README must list ⌘O")
        XCTAssertTrue(readme.contains("| `⌥⌘C` |"), "README must list ⌥⌘C")
        XCTAssertTrue(readme.contains("double-click opens"),
                      "README must say a file clip opens on double-click and no longer pastes on click")
    }
}
