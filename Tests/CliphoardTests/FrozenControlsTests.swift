import XCTest
import AppKit
import SwiftUI
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

    // MARK: - The mechanism the section gate rests on

    /// `.disabled` on a container really does reach its descendants — MEASURED, not assumed.
    ///
    /// A previous comment in `ClipDetailView` asserted this was unverifiable headlessly and
    /// used that to justify six per-control gates as "belt and braces". It is verifiable, and
    /// the claim was false anyway: the per-tag Remove had no gate of its own and rested on
    /// inheritance regardless. This test is the evidence the rewritten comment cites, so one
    /// gate on the section is a mechanism rather than a hope.
    func testDisabledPropagatesThroughAGroupBoxToItsDescendants() {
        final class Probe { var seen: [Bool] = [] }
        struct Reader: View {
            @Environment(\.isEnabled) private var isEnabled
            let probe: Probe
            var body: some View {
                Color.clear.onAppear { probe.seen.append(isEnabled) }
            }
        }
        func render(disabled: Bool) -> [Bool] {
            let probe = Probe()
            let view = GroupBox("Tags") { Reader(probe: probe) }.disabled(disabled)
            let host = NSHostingView(rootView: AnyView(view))
            host.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            return probe.seen
        }
        XCTAssertEqual(render(disabled: true), [false],
                       "a descendant of a .disabled container reported itself ENABLED — the "
                       + "section gate is the only thing standing between a frozen store and "
                       + "a live tag editor")
        XCTAssertEqual(render(disabled: false), [true],
                       "and the converse, so this cannot pass by never rendering: an empty "
                       + "list fails the equality")
    }

    /// The end-to-end path, and the only control whose live state can be READ rather than
    /// asserted about text: garbage sqlite → `!storageComplete` → `safeMode` →
    /// `historyIsMutable` false → the tag field is inert.
    ///
    /// Selected by placeholder and asserted to match EXACTLY ONE field, deliberately. The
    /// same view renders several `NSTextField`s for the selectable metadata rows, which are
    /// correctly enabled — so a naive probe fails against correct code, and a zero-match
    /// probe would pass vacuously.
    func testTheInspectorTagFieldIsInertOnAFrozenStore() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoInspector-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0xFF, count: 100)
            .write(to: dir.appendingPathComponent("ditto.sqlite"))
        let store = ClipStore(directory: dir)
        XCTAssertTrue(store.safeMode, "precondition: an unreadable database freezes the store")

        let item = ClipItem(kind: .text, text: "hello")
        item.userTags = ["invoice"]
        let view = ClipDetailView(item: item, store: store, focusTags: true,
                                  onPaste: {}, onCopy: {}, onClose: {})
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        func fields(_ v: NSView) -> [NSTextField] {
            (v as? NSTextField).map { [$0] } ?? [] + v.subviews.flatMap(fields)
        }
        let tagFields = fields(host).filter { $0.placeholderString == "Add a tag" }
        // If this is ever 0, check whether SwiftUI still backs TextField with NSTextField and
        // still exposes `placeholderString`, BEFORE concluding the gate regressed. The
        // exactly-one assertion is what makes an OS change fail loudly instead of vacuously.
        XCTAssertEqual(tagFields.count, 1,
                       "expected exactly one 'Add a tag' field; 0 means the probe can no "
                       + "longer see the control (an OS change, not necessarily a regression)")
        XCTAssertEqual(tagFields.first?.isEnabled, false,
                       "the inspector's tag field is LIVE on a frozen store. Its labels are "
                       + "the row's ciphertext parsed as tags, and saving them would seal "
                       + "that garbage over the user's real labels")
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
        let detail = try String(contentsOf: root.appendingPathComponent(
            "Sources/Cliphoard/UI/ClipDetailView.swift"), encoding: .utf8)

        XCTAssertTrue(card.contains("let historyIsMutable: Bool"),
                      "`let` with no default — `var historyIsMutable = true` would let the "
                      + "next call site silently ship a live Delete on a frozen store")
        XCTAssertTrue(card.contains(".disabled(!historyIsMutable)"),
                      "the per-card Delete lost its gate")
        // EXACTLY ONE occurrence, and that is the repair. This assertion previously read
        // `contains(...)` and was satisfied by whichever call site happened to have it — so
        // `historyIsMutable: true` on the OTHER one passed all 435 tests while shipping a
        // live editor on a frozen store. ClipDetailView now DERIVES the fact and has no
        // argument at all, so the single remaining occurrence is the card's.
        XCTAssertEqual(content.components(separatedBy: "historyIsMutable: !store.safeMode").count - 1,
                       1,
                       "expected exactly one call site to pass this fact (the card's). A "
                       + "file-wide `contains` is satisfiable by an unrelated call site, "
                       + "which is precisely how the inspector's gate went untested.")
        XCTAssertFalse(detail.contains("let historyIsMutable"),
                       "ClipDetailView must DERIVE the fact from the store it already "
                       + "observes — a parameter is a positional fact a call site can get "
                       + "wrong, and this one was got wrong three rounds running")
    }
}
