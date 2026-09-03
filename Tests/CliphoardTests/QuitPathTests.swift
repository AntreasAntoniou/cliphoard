import XCTest
import AppKit
@testable import Cliphoard

/// The app had exactly one quit: an item in a status-bar menu — which a menu-bar manager
/// (Ice, Bartender) hides behind a chevron. With it hidden, the only way out was Activity
/// Monitor. The path that matters most is the one out of SAFE MODE, where the banner tells
/// the user to "quit and reopen" and offered nothing to press.
@MainActor
final class QuitPathTests: XCTestCase {

    private func sourceRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func source(_ path: String) throws -> String {
        try String(contentsOf: sourceRoot().appendingPathComponent(path), encoding: .utf8)
    }
    /// A store genuinely frozen on ANY machine — the recipe proven by
    /// `FrozenControlsTests.testTheInspectorTagFieldIsInertOnAFrozenStore`.
    private func frozenStore() throws -> ClipStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoQuit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0xFF, count: 100).write(to: dir.appendingPathComponent("ditto.sqlite"))
        let store = ClipStore(directory: dir)
        XCTAssertTrue(store.safeMode, "precondition: an unreadable database freezes the store")
        return store
    }

    // MARK: - The menu is the ⌘Q (live)

    func testTheMainMenuCarriesQuitOnCommandQ() {
        let menu = AppDelegate.makeMainMenu(target: nil)
        guard let appItem = menu.item(at: 0) else { return XCTFail("no app menu") }
        guard let submenu = appItem.submenu else {
            return XCTFail("a top-level item with no submenu never dispatches its key "
                           + "equivalent — ⌘Q would be inert while every assertion below passed")
        }
        XCTAssertEqual(submenu.items.count, 1,
                       "ONE item. An Edit menu here would put ⌘C in the main-menu chain, "
                       + "competing with the conditional ⌘C in handleKey (selected text vs. "
                       + "selected clip) — a silent regression.")
        let quit = submenu.items[0]
        XCTAssertEqual(quit.title, "Quit Cliphoard")
        XCTAssertEqual(quit.keyEquivalent, "q")
        XCTAssertEqual(quit.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(quit.action.map(NSStringFromSelector), "quit",
                       "must target the same `quit` the status item uses, so both land in "
                       + "the one termination gate")
        // Pinned at its default, NOT for re-entrancy protection: a verifier probed that a
        // modal session swallows ⌘Q with autoenabling on OR off (isEnabled reads true in
        // both). The guard against a second quit request is `isAskingAboutQuit`. This
        // assertion only keeps the menu at the default so nothing new needs enabling logic.
        XCTAssertTrue(menu.autoenablesItems,
                      "the main menu should stay at AppKit's default autoenabling; nothing "
                      + "here needs manual isEnabled management")
    }

    /// Without this the builder above passes while the app ships no menu at all.
    func testTheMenuIsInstalledAtLaunch() throws {
        let src = try source("Sources/Cliphoard/App/AppDelegate.swift")
        guard let start = src.range(of: "func applicationDidFinishLaunching") else {
            return XCTFail("applicationDidFinishLaunching was renamed")
        }
        XCTAssertTrue(String(src[start.upperBound...].prefix(400)).contains("setupMainMenu()"),
                      "the main menu is never installed, so ⌘Q resolves to nothing")
    }

    /// ⌘Q must be claimed in exactly ONE place. A branch in the local key monitor fires
    /// even while a modal alert is up (probed) and would re-enter `terminate` on top of its
    /// own confirm; the main menu is disabled for the modal's duration and cannot.
    func testCommandQIsNotAlsoClaimedByTheKeyMonitor() throws {
        let src = try source("Sources/Cliphoard/App/AppDelegate.swift")
        XCTAssertFalse(src.contains("kVK_ANSI_Q"),
                       "⌘Q is handled twice. The monitor sees keys during a modal session; "
                       + "the main menu does not. Two handlers means the confirm can be "
                       + "quit out from under itself.")
    }

    // MARK: - The decision (pure)

    func testAHealthyAppQuitsWithoutAQuestion() {
        XCTAssertNil(AppDelegate.unsavedQuitPrompt(count: 0, relaunching: false),
                     "a store that WROTE its clips must never ask — deploy-local.sh quits "
                     + "by osascript and waits 5s, and a trained-away warning warns nobody")
    }
    func testTheWarningNamesTheNumberAndIsGrammatical() {
        let two = AppDelegate.unsavedQuitPrompt(count: 2, relaunching: false)
        XCTAssertEqual(two?.title, "Quit without saving 2 clips?")
        XCTAssertTrue(two?.body.contains("never written to disk") ?? false)
        XCTAssertEqual(two?.confirm, "Quit Anyway")
        XCTAssertEqual(AppDelegate.unsavedQuitPrompt(count: 1, relaunching: false)?.title,
                       "Quit without saving 1 clip?")
        XCTAssertEqual(AppDelegate.unsavedQuitPrompt(count: 3, relaunching: true)?.title,
                       "Relaunch without saving 3 clips?",
                       "the banner's Relaunch must not warn about quitting")
    }

    // MARK: - The count is real (live, deterministic)

    func testAFrozenStoreCountsEveryClipItRefusedToWrite() throws {
        let store = try frozenStore()
        store.add(ClipItem(kind: .text, text: "unsaved one"))
        store.add(ClipItem(kind: .text, text: "unsaved two"))
        XCTAssertEqual(store.unsavedClipCount, 2,
                       "the refusal is a DebugLog line and nothing else — without this count "
                       + "the confirm has no number to show and cannot exist")
        XCTAssertEqual(store.items.count, 2,
                       "and they are still in memory: that is what makes quitting a loss")
    }
    func testARecopiedClipIsNotCountedTwice() throws {
        let store = try frozenStore()
        store.add(ClipItem(kind: .text, text: "same"))
        store.add(ClipItem(kind: .text, text: "same"))
        XCTAssertEqual(store.unsavedClipCount, 1,
                       "the dedup path returns before the safe-mode arm; a count that "
                       + "inflates on re-copy makes the warning a lie")
    }
    func testAHealthyStoreNeverCountsAnythingUnsaved() throws {
        try skipIfKeychainUnreachable()
        let store = ClipStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoQuitOK-\(UUID().uuidString)"))
        try XCTSkipIf(store.safeMode, "frozen here")
        store.add(ClipItem(kind: .text, text: "a"))
        store.add(ClipItem(kind: .text, text: "b"))
        XCTAssertEqual(store.unsavedClipCount, 0,
                       "counting on a store that WROTE the rows would make every healthy "
                       + "quit stop and ask, and the warning would be trained away before "
                       + "it ever meant anything")
    }

    // MARK: - The gate, and the alert that must be visible

    func testEveryQuitPassesThroughOneCancellableGate() throws {
        let src = try source("Sources/Cliphoard/App/AppDelegate.swift")
        XCTAssertTrue(src.contains("func applicationShouldTerminate"),
                      "the confirm must be the delegate gate: the status item, ⌘Q, the "
                      + "banner and `osascript quit` are four paths")
        XCTAssertTrue(src.contains("store.unsavedClipCount"), "the gate reads no count")
        XCTAssertTrue(src.contains(".terminateCancel"), "a confirm with no Cancel is not one")
        XCTAssertTrue(src.contains("@objc private func quit() { NSApp.terminate(nil) }"),
                      "the status item's Quit must stay a plain terminate so it goes "
                      + "through the same gate")
    }

    /// `NSAlert.runModal()` overwrites its window level with `.modalPanel` (8) — probed —
    /// so the bar at `.mainMenu + 1` (25) covers it. The warning must be raised by lowering
    /// OUR windows, and both levels must be restored on the cancel path.
    func testTheConfirmIsRaisedAboveTheBarAndTheBarIsPutBack() throws {
        let src = try source("Sources/Cliphoard/App/AppDelegate.swift")
        guard let gate = src.range(of: "func applicationShouldTerminate") else {
            return XCTFail("the gate was renamed")
        }
        // Bounded by the next declaration, not a character count, and anchored on the CALL
        // `alert.runModal()` — a bare "runModal()" matched the comment above the lowering
        // line that explains why the level must be lowered, and the ordering assertion
        // failed against prose. The exact trap ForgetOrderingTests documents.
        let rest = src[gate.upperBound...]
        let end = rest.range(of: "\n    func ") ?? rest.range(of: "\n    // MARK:")
        let body = String(rest[..<(end?.lowerBound ?? rest.endIndex)])
        guard let lower = body.range(of: "panel.level = .normal"),
              let modal = body.range(of: "alert.runModal()") else {
            return XCTFail("the alert does not lower the panel level — it will render "
                           + "BEHIND the bar and the quit will look like it did nothing")
        }
        XCTAssertLessThan(lower.lowerBound, modal.lowerBound,
                          "the level is lowered AFTER the modal runs, which does nothing")
        XCTAssertTrue(body.contains("inspector.panel.level = .normal"),
                      "the inspector sits at .mainMenu + 2 and would cover the alert too")
        XCTAssertTrue(body.contains("defer {") && body.contains("panel.level = barLevel"),
                      "a cancelled quit must leave the bar at its floating level, not at "
                      + ".normal where every other window covers it")
        guard let flag = body.range(of: "model.isPresentingSystemPanel = true") else {
            return XCTFail("without this the alert takes key, onResignKey fires, and the "
                           + "bar slides away mid-question")
        }
        XCTAssertLessThan(flag.lowerBound, modal.lowerBound)
    }

    // MARK: - Relaunch: after approval, never before

    func testTheRelaunchWaitsForThisProcessToExit() {
        let cmd = AppLifecycle.relaunchCommand(pid: 4242,
                                               bundleURL: URL(fileURLWithPath: "/Applications/Cliphoard.app"))
        guard let cmd else { return XCTFail("a .app bundle must be relaunchable") }
        XCTAssertTrue(cmd.contains("kill -0 4242"),
                      "the reopen must WAIT for this pid: `open -n` before terminate puts a "
                      + "second instance on the same sqlite/WAL and keychain item")
        guard let wait = cmd.range(of: "kill -0"), let open = cmd.range(of: "/usr/bin/open") else {
            return XCTFail("missing wait or open")
        }
        XCTAssertLessThan(wait.lowerBound, open.lowerBound)
        XCTAssertTrue(cmd.contains("'/Applications/Cliphoard.app'"), "the path must be quoted")
    }
    func testADevBuildIsNotRelaunched() {
        XCTAssertNil(AppLifecycle.relaunchCommand(pid: 1,
                                                  bundleURL: URL(fileURLWithPath: "/x/.build/debug")),
                     "`open` on a bare executable's directory opens Finder")
    }
    func testACancelledRelaunchCannotResurrectTheApp() {
        AppLifecycle.cancelRelaunch()
        XCTAssertFalse(AppLifecycle.performRelaunchIfRequested(),
                       "a quit the user cancelled must leave no watcher behind")
    }
    func testTheRelaunchRunsOnlyAfterTerminationIsApproved() throws {
        let src = try source("Sources/Cliphoard/App/AppDelegate.swift")
        guard let will = src.range(of: "func applicationWillTerminate") else {
            return XCTFail("the relaunch moved out of applicationWillTerminate, which is the "
                           + "only hook that runs AFTER shouldTerminate has said yes")
        }
        XCTAssertTrue(String(src[will.upperBound...].prefix(300))
                        .contains("AppLifecycle.performRelaunchIfRequested()"))
    }
    func testExactlyOneRelaunchImplementationExists() throws {   // drop with S7(b)
        let settings = try source("Sources/Cliphoard/UI/SettingsView.swift")
        XCTAssertFalse(settings.contains("/usr/bin/open"),
                       "SettingsView's Accessibility relaunch still spawns its own copy, "
                       + "before terminate — the race this consolidation removes")
    }

    // MARK: - The affordances are on screen

    func testTheSafeModeBannerOffersTheRecoveryItsOwnTextPromises() throws {
        let ui = try source("Sources/Cliphoard/UI/ContentView.swift")
        guard let start = ui.range(of: "private var safeModeBanner") else {
            return XCTFail("safeModeBanner was renamed")
        }
        let body = String(ui[start.upperBound...].prefix(2200))
        XCTAssertTrue(body.contains("AppLifecycle.quit()"),
                      "the banner tells the user to quit and gives them nothing to press — "
                      + "with the status item hidden there is no other way out")
        XCTAssertTrue(body.contains("AppLifecycle.requestRelaunch()"),
                      "'Quit and reopen' is the instruction; Relaunch is that instruction "
                      + "as a button")
        guard let gate = body.range(of: "if store.safeMode"),
              let quit = body.range(of: "AppLifecycle.quit()") else { return XCTFail("no gate") }
        XCTAssertLessThan(gate.lowerBound, quit.lowerBound,
                          "quit buttons outside the safe-mode gate would sit in the chrome "
                          + "of every healthy summon")
    }

    func testTheFooterTeachesTheQuitKeyInBothStates() throws {
        let ui = try source("Sources/Cliphoard/UI/ContentView.swift")
        XCTAssertEqual(ui.components(separatedBy: "hint(\"⌘Q\", \"Quit\")").count - 1, 2,
                       "expected the hint in BOTH footer branches. The settings branch is "
                       + "the one a user reaches by clicking the gear looking for a way out.")
    }

    func testSettingsCarriesAMouseReachableQuit() throws {
        let s = try source("Sources/Cliphoard/UI/SettingsView.swift")
        XCTAssertTrue(s.contains("Text(\"Quit Cliphoard\")") && s.contains("AppLifecycle.quit()"),
                      "with the status item hidden by Ice and the keyboard hint unread, the "
                      + "gear is the surface the owner actually opens")
    }
}
