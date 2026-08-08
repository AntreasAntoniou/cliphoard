import XCTest
import AppKit
@testable import Cliphoard

/// Controls that look live and silently do nothing.
///
/// This is a HONESTY defect, not a data-loss one — the store already refuses (`delete`,
/// `clearUnpinned`, `trim`, `forgetImageUnderstanding` all guard on `safeMode`), so
/// nothing here was at risk of loss. It still matters: a Delete that appears to work and
/// doesn't reads as a broken app, and the next thing someone tries when the app looks
/// broken is to clear it.
///
/// One exception, which IS a loss path and is covered below: `updateUserTags` had no
/// guard at all.
@MainActor
final class FrozenControlsTests: XCTestCase {

    private func tempStore() -> ClipStore {
        ClipStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoFrozen-\(UUID().uuidString)"))
    }

    // MARK: - The AppKit mechanism

    /// Which of two mechanisms actually disables a status-bar item, established by
    /// observation rather than argument — the two independent proposals contradicted each
    /// other and only one can be right.
    ///
    /// Under automatic enabling (the default, and what this app runs) `NSMenu.update()`
    /// recomputes `isEnabled` before every display, so a manual `isEnabled = false` is
    /// DISCARDED — while an item whose action is nil is disabled by AppKit's own rule.
    /// That is why `destructiveAction` drops the selector instead of setting a flag.
    /// A nil action wins over an explicit attempt to enable the item.
    ///
    /// Asserted this way round on purpose. The complementary fact — that under automatic
    /// enabling a manual `isEnabled = false` is DISCARDED, which is why this app gates by
    /// dropping the selector rather than setting the flag — was established by probing a
    /// process with a live responder chain, and is NOT reproducible in xctest: headless,
    /// `update()` disables targeted items too, for an unrelated reason. Asserting it here
    /// would pass for the wrong reason. What IS environment-independent is the property
    /// the gating actually rests on, and it is the stronger one: nil action means
    /// disabled, and no one can override it by accident.
    func testANilActionIsDisabledEvenIfSomethingTriesToEnableIt() {
        let menu = NSMenu()
        XCTAssertTrue(menu.autoenablesItems, "precondition: this is AppKit's default")

        let gated = NSMenuItem(title: "gated", action: nil, keyEquivalent: "")
        gated.isEnabled = true          // an author, or a future refactor, insisting
        menu.addItem(gated)

        menu.update()

        XCTAssertFalse(gated.isEnabled,
                       "a nil action must be disabled by AppKit's own rule even against an "
                       + "explicit isEnabled = true — this is the mechanism the safe-mode "
                       + "gating depends on")
    }

    func testDestructiveActionDropsItsSelectorWhenRefused() {
        XCTAssertNil(AppDelegate.destructiveAction(#selector(NSApplication.terminate(_:)),
                                                   enabled: false))
        XCTAssertNotNil(AppDelegate.destructiveAction(#selector(NSApplication.terminate(_:)),
                                                      enabled: true),
                        "the converse: a healthy store must still get a working item")
    }

    // MARK: - The one control here that was a genuine loss path

    /// `Crypto.open(String)` fails OPEN, so an unreadable row's `userTags` in memory are
    /// its `enc1:` ciphertext parsed as labels. Under the RATIO safe-mode term the key is
    /// healthy and `sealStrict` SUCCEEDS, so an edit writes that garbage over the user's
    /// real labels — permanently, and undetectably afterwards.
    func testUserTagsCannotBeRewrittenWhileFrozen() throws {
        let store = tempStore()
        try XCTSkipUnless(store.safeMode,
                          "no frozen store to exercise on this machine — the converse "
                          + "below covers the healthy direction")
        let item = ClipItem(kind: .text, text: "hello")
        item.userTags = ["real-label"]

        XCTAssertFalse(store.updateUserTags(item, to: ["overwritten"]),
                       "a frozen store must refuse a tag write")
        XCTAssertEqual(item.userTags, ["real-label"],
                       "the labels themselves must be untouched, not merely unsaved")
        XCTAssertFalse(store.dismissSuggestedUserTag("x", for: item),
                       "a dismissal is keyed by ciphertext-derived text on an unreadable "
                       + "row, so it must not be persisted either")
    }

    /// The converse, so the fix cannot pass by disabling tagging outright. Asserts what
    /// the method actually CHANGES — not `items.count`, which `updateUserTags` never
    /// touches and which would therefore pass against an empty implementation.
    func testAHealthyStoreStillWritesUserTags() throws {
        try skipIfKeychainUnreachable()
        let store = tempStore()
        try XCTSkipIf(store.safeMode, "frozen here")
        let item = ClipItem(kind: .text, text: "hello")
        store.add(item)

        XCTAssertTrue(store.updateUserTags(item, to: ["invoice"]),
                      "tagging must still WORK")
        XCTAssertEqual(item.userTags, ["invoice"])
        XCTAssertFalse(store.filtered(kind: nil, query: "#invoice", pinnedOnly: false).isEmpty,
                       "and the label must reach the index, not just the object")
    }

    // MARK: - Structure

    /// The primary destructive control is the per-card Delete in the main grid. It was the
    /// one left live while three secondary surfaces were gated — so this pins that the
    /// card takes the fact at all, and that the parameter has NO DEFAULT, which is what
    /// forces the next call site to answer.
    func testTheCardDeleteIsGatedAndTheParameterHasNoDefault() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let card = try String(contentsOf: root.appendingPathComponent(
            "Sources/Cliphoard/UI/ClipCardView.swift"), encoding: .utf8)
        let content = try String(contentsOf: root.appendingPathComponent(
            "Sources/Cliphoard/UI/ContentView.swift"), encoding: .utf8)

        XCTAssertTrue(card.contains("let historyIsMutable: Bool"),
                      "`let` with no default — `var historyIsMutable = true` would let the "
                      + "next call site silently ship a live Delete on a frozen store")
        XCTAssertTrue(card.contains(".disabled(!historyIsMutable)"),
                      "the per-card Delete lost its gate")
        XCTAssertTrue(content.contains("historyIsMutable: !store.safeMode"),
                      "the call site stopped passing the real state")
    }
}
