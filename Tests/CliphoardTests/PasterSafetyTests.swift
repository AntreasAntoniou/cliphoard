import XCTest
import AppKit
@testable import Cliphoard

/// `Paster` cleared the clipboard BEFORE it knew it could refill it.
///
/// `writeToPasteboard` opened with an unconditional `pb.clearContents()` and then entered
/// an if-let chain — payload filename, file read, decrypt, `NSImage(data:)` — any link of
/// which can fail. On failure nothing was written, so picking a clip whose payload had gone
/// missing or become undecryptable DESTROYED whatever the user had on the clipboard and put
/// nothing back. Not a failed paste: a silent theft of unrelated content.
///
/// This is not a newly-imagined hazard. `AUDIT.md:164` described it exactly — "a silent
/// no-op paste" — and it survived the audit that named it, because nothing executable
/// pinned it. Hence this file.
///
/// The undecryptable case is the one that matters in practice: a store sealed under a key
/// the process can no longer reach (the safe-mode path, an ephemeral key that died with a
/// previous process) reads back as bytes that `Crypto.open` refuses. The clip is still
/// listed, still looks pastable, and picking it wipes the clipboard.
///
/// Everything is driven against a NAMED pasteboard. A test that clobbered
/// `NSPasteboard.general` would destroy the developer's clipboard on every run, which is
/// the same discourtesy this file exists to fix.
@MainActor
final class PasterSafetyTests: XCTestCase {
    private var tempDir: URL!
    private var store: ClipStore!
    private var pb: NSPasteboard!

    override func setUp() {
        super.setUp()
        Feedback.soundEnabled = false
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoPasterTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = ClipStore(directory: tempDir)
        pb = NSPasteboard(name: .init("io.antreas.cliphoard.tests.\(UUID().uuidString)"))
    
    }

    override func tearDown() {
        pb.releaseGlobally()
        try? FileManager.default.removeItem(at: tempDir)
        store = nil; pb = nil
        super.tearDown()
    }

    /// Seed the pasteboard with something the user would be upset to lose.
    private func seedPriorContents() {
        pb.clearContents()
        pb.setString("the user was in the middle of something", forType: .string)
    }

    private func pngBytes() -> Data {
        let img = NSImage(size: NSSize(width: 8, height: 8))
        img.lockFocus(); NSColor.systemPink.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill(); img.unlockFocus()
        let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }

    // MARK: - The bug

    /// A payload file that is not on disk at all.
    func testAMissingPayloadDoesNotWipeTheClipboard() throws {
        try skipIfKeychainUnreachable()
        seedPriorContents()

        let item = ClipItem(kind: .image, text: "Image 8×8")
        item.payloadFile = "definitely-not-on-disk.png"

        let outcome = Paster.writeToPasteboard(item, store: store, to: pb)

        XCTAssertEqual(outcome, .payloadUnreadable,
                       "the outcome must say WHY it failed: the caller promises the user "
                       + "their clipboard is unchanged, which is only true for this case")
        XCTAssertEqual(pb.string(forType: .string),
                       "the user was in the middle of something",
                       "picking a clip whose payload is missing CLEARED the clipboard and "
                       + "wrote nothing in its place — the user lost content that had "
                       + "nothing to do with the clip they picked (AUDIT.md:164)")
    }

    /// The case that actually happens: the payload exists but cannot be decrypted.
    func testAnUndecryptablePayloadDoesNotWipeTheClipboard() throws {
        try skipIfKeychainUnreachable()
        seedPriorContents()

        // Bytes that are not a valid `enc1:` ciphertext — what a payload sealed under a
        // now-unreachable key looks like to this process.
        let name = "undecryptable.png"
        try Data("enc1:not actually a valid sealed payload".utf8)
            .write(to: tempDir.appendingPathComponent(name))

        let item = ClipItem(kind: .image, text: "Image 8×8")
        item.payloadFile = name

        let outcome = Paster.writeToPasteboard(item, store: store, to: pb)

        XCTAssertEqual(outcome, .payloadUnreadable)
        XCTAssertEqual(pb.string(forType: .string),
                       "the user was in the middle of something",
                       "an undecryptable payload wiped the clipboard. This is the realistic "
                       + "form of the bug: a clip sealed under a key this process can no "
                       + "longer reach still LISTS and still looks pastable.")
    }

    /// A file clip with no path must not wipe either — same shape, different branch.
    func testAFileClipWithNoPathDoesNotWipeTheClipboard() throws {
        try skipIfKeychainUnreachable()
        seedPriorContents()
        let item = ClipItem(kind: .file, text: "somewhere")
        item.filePath = nil

        XCTAssertEqual(Paster.writeToPasteboard(item, store: store, to: pb), .payloadUnreadable)
        XCTAssertEqual(pb.string(forType: .string),
                       "the user was in the middle of something",
                       "the .file branch clears before checking filePath, so a clip whose "
                       + "path went missing wipes the clipboard too")
    }

    // MARK: - The fix must not break the working path

    /// A healthy image still writes, and now offers PNG as well as TIFF.
    func testAHealthyImageWritesBothPNGAndTIFF() throws {
        try skipIfKeychainUnreachable()
        let png = pngBytes()
        let sealed = try XCTUnwrap(Crypto.seal(png), "could not seal the fixture")
        let name = "healthy.png"
        try sealed.write(to: tempDir.appendingPathComponent(name))

        let item = ClipItem(kind: .image, text: "Image 8×8")
        item.payloadFile = name

        XCTAssertEqual(Paster.writeToPasteboard(item, store: store, to: pb), .wrote)
        XCTAssertNotNil(pb.data(forType: .tiff),
                        "TIFF is what every previous build wrote and what the user's "
                        + "working paste path relies on — it must not regress")
        XCTAssertNotNil(pb.data(forType: .png),
                        "PNG must now be offered too: writeObjects([NSImage]) declares TIFF "
                        + "and nothing else, so Cliphoard's own output was as flavour-poor "
                        + "as the pasteboards it exists to rescue. The PNG bytes are already "
                        + "on disk; not offering them was free breakage for PNG-preferring "
                        + "targets (Chromium, Electron).")
    }

    /// Both flavours must live on ONE item.
    ///
    /// `writeObjects` always APPENDS a new pasteboard item and `dataForType:` resolves
    /// against the FIRST item carrying the type. Mixing `writeObjects([NSImage])` with
    /// `setData` therefore yields two items where the reader may resolve TIFF from one and
    /// PNG from the other — a pasteboard whose two representations can disagree, with
    /// nothing in the API surfacing the split.
    func testTheImageIsWrittenAsExactlyOnePasteboardItem() throws {
        try skipIfKeychainUnreachable()
        let sealed = try XCTUnwrap(Crypto.seal(pngBytes()))
        let name = "one-item.png"
        try sealed.write(to: tempDir.appendingPathComponent(name))
        let item = ClipItem(kind: .image, text: "Image 8×8")
        item.payloadFile = name

        XCTAssertEqual(Paster.writeToPasteboard(item, store: store, to: pb), .wrote)
        XCTAssertEqual(pb.pasteboardItems?.count, 1,
                       "the image was split across multiple pasteboard items; a reader can "
                       + "resolve PNG and TIFF from different items")
    }

    /// Text is untouched by all of this.
    func testATextClipStillWrites() throws {
        try skipIfKeychainUnreachable()
        let item = ClipItem(kind: .text, text: "hello")
        XCTAssertEqual(Paster.writeToPasteboard(item, store: store, to: pb), .wrote)
        XCTAssertEqual(pb.string(forType: .string), "hello")
    }

    // MARK: - BUG 2: the suppression must not be spent on a write that never happened

    /// The historical defect: the method was `suppressNextChange()` and set
    /// `ignoreChangeCount = changeCount + 1` — a PREDICTION that the next pasteboard change
    /// would be ours — and both call sites armed it BEFORE the write. When the write failed
    /// the pasteboard never changed, so the prediction sat waiting and was spent by the
    /// user's NEXT REAL COPY, which `poll()` then discarded as "our own paste". A failed
    /// paste silently ate the following clip.
    ///
    /// It is now `suppressOwnWrite()`, it reads the ACTUAL post-write `changeCount` rather
    /// than predicting it, and it is armed only behind a successful-write guard. This test
    /// pins the ordering half; `testTheSuppressionReadsTheActualChangeCount` pins the other.
    ///
    /// Asserted at the source: the alternative is driving AppDelegate's full commit path,
    /// which needs a panel, a frontmost app and the Accessibility permission.
    func testTheSuppressionIsArmedOnlyAfterASuccessfulWrite() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Cliphoard/App/AppDelegate.swift"),
            encoding: .utf8)

        for fn in ["private func commit(", "private func copyToClipboard("] {
            guard let start = source.range(of: fn) else {
                return XCTFail("\(fn) was renamed — move this test with it")
            }
            let rest = source[start.upperBound...]
            // EARLIEST of the plausible next-member markers, not the first one that happens
            // to match. `commit` is followed by `static func failureMessage`, so keying only
            // on "\n    private " overran 3635 chars into the next member — silently.
            let end = ["\n    private ", "\n    static func ", "\n    func ", "\n    // MARK:"]
                .compactMap { rest.range(of: $0)?.lowerBound }.min()
            let body = String(rest[..<(end ?? rest.endIndex)])

            guard let suppress = body.range(of: "monitor.suppressOwnWrite()"),
                  let write = body.range(of: "Paster.writeToPasteboard(") else {
                return XCTFail("\(fn) no longer both writes and suppresses")
            }
            XCTAssertLessThan(
                write.lowerBound, suppress.lowerBound,
                "\(fn) arms the suppression BEFORE the write. If the write fails the "
                + "pasteboard never changes, so the armed prediction is spent by the user's "
                + "NEXT REAL COPY — which poll() then skips as our own paste. A failed "
                + "paste silently swallows the following clip.")
        }
    }

    /// The other half of BUG 2: no prediction anywhere.
    func testTheSuppressionReadsTheActualChangeCount() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Cliphoard/Clipboard/ClipboardMonitor.swift"),
            encoding: .utf8)
        guard let start = source.range(of: "func suppressOwnWrite()") else {
            return XCTFail("suppressOwnWrite was renamed — move this test with it")
        }
        let body = String(source[start.upperBound...].prefix(200))
        XCTAssertTrue(body.contains("changeCount"), "it must still record a changeCount")
        XCTAssertFalse(body.contains("changeCount + 1"),
                       "the +1 PREDICTION is back. It is only correct if exactly one change "
                       + "lands; reading the value the write actually produced cannot drift.")
        XCTAssertFalse(source.contains("func suppressNextChange"),
                       "the old name is back — its ordering requirement is not expressed by "
                       + "the name, which is how it came to be called before the write")
    }

    // MARK: - D3: a failed pick must not count as a use

    /// These two pin the OUTCOME CONTRACT only — that the write reports
    /// `.payloadUnreadable` and that a caller honouring it leaves `useCount` alone. They do
    /// NOT pin AppDelegate's wiring: they re-implement the guard locally, so moving
    /// `store.markUsed(item)` back above the guard in `commit` would leave both green.
    /// `testMarkUsedHappensOnlyAfterTheWriteGuard` is what actually pins that, and this
    /// docstring exists so nobody mistakes these for the real protection.
    ///
    /// Why it matters: a clip that could not be written was never used, and bumping its
    /// count reorders history (recency sort) so the BROKEN clip climbs toward the top and
    /// keeps being offered first.
    func testAFailedPickDoesNotCountAsAUse() throws {
        try skipIfKeychainUnreachable()
        let item = ClipItem(kind: .image, text: "Image 8×8")
        item.payloadFile = "definitely-not-on-disk.png"
        store.add(item)
        let before = item.useCount

        // The guard AppDelegate applies: markUsed only on success.
        let outcome = Paster.writeToPasteboard(item, store: store, to: pb)
        if outcome.succeeded { store.markUsed(item) }

        XCTAssertEqual(item.useCount, before,
                       "an unwritable clip was counted as used, so recency sorting floats "
                       + "the broken clip toward the top of the user's history")
    }

    /// The mirror: a successful pick must still count, or the fix has traded one silent
    /// wrongness for another.
    func testASuccessfulPickStillCountsAsAUse() throws {
        try skipIfKeychainUnreachable()
        let sealed = try XCTUnwrap(Crypto.seal(pngBytes()))
        let name = "counts.png"
        try sealed.write(to: tempDir.appendingPathComponent(name))
        let item = ClipItem(kind: .image, text: "Image 8×8")
        item.payloadFile = name
        store.add(item)
        let before = item.useCount

        let outcome = Paster.writeToPasteboard(item, store: store, to: pb)
        if outcome.succeeded { store.markUsed(item) }

        XCTAssertEqual(outcome, .wrote)
        XCTAssertGreaterThan(item.useCount, before, "a real pick must still count as a use")
    }

    /// The wiring, pinned executably. `markUsed` must appear only AFTER the failed-write
    /// guard returns, in both call sites.
    ///
    /// Written because the two tests above looked like coverage and were not: they ran the
    /// guard themselves and then asserted their own `if` had worked. This file's header
    /// condemns exactly that — a defect surviving "because nothing executable pinned it" —
    /// and the first version of these tests reproduced it.
    func testMarkUsedHappensOnlyAfterTheWriteGuard() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Cliphoard/App/AppDelegate.swift"),
            encoding: .utf8)
        for fn in ["private func commit(", "private func copyToClipboard("] {
            guard let start = source.range(of: fn) else { return XCTFail("\(fn) renamed") }
            let rest = source[start.upperBound...]
            let end = ["\n    private ", "\n    static func ", "\n    func ", "\n    // MARK:"]
                .compactMap { rest.range(of: $0)?.lowerBound }.min()
            let body = String(rest[..<(end ?? rest.endIndex)])

            guard let guardRange = body.range(of: "guard outcome.succeeded else {") else {
                return XCTFail("\(fn) no longer guards on the write outcome")
            }
            guard let mark = body.range(of: "store.markUsed(item)") else {
                return XCTFail("\(fn) no longer marks the clip used at all")
            }
            // The guard's own closing brace: everything before it is the failure arm.
            let afterGuard = body[guardRange.upperBound...]
            guard let close = afterGuard.range(of: "\n        }") else {
                return XCTFail("could not find the end of \(fn)'s failure arm")
            }
            XCTAssertGreaterThan(
                mark.lowerBound, close.upperBound,
                "\(fn) marks the clip used BEFORE the failed-write guard returns. A clip "
                + "that could not be written was never used; counting it reorders history "
                + "so the broken clip floats to the top and keeps being offered first.")
        }
    }

    // MARK: - D1: the failure must actually reach the user

    /// The message must not promise something that is only true in one of the two failure
    /// modes. AppKit requires clearing before declaring, so a pasteboard-refused write has
    /// already emptied the clipboard; a payload that never loaded has not.
    func testOnlyTheUntouchedFailureClaimsTheClipboardIsIntact() {
        XCTAssertTrue(AppDelegate.failureMessage(for: .payloadUnreadable).contains("unchanged"),
                      "the payload-load failure leaves the clipboard alone and should say so")
        XCTAssertFalse(AppDelegate.failureMessage(for: .pasteboardRefused).contains("unchanged"),
                       "a refused write has ALREADY cleared the clipboard — promising it is "
                       + "unchanged would be a lie told at the worst moment")
    }

    /// A failed pick must NOT dismiss the panel. The banner renders only inside the panel
    /// (ContentView.swift), so setting it and then hiding put the message on screen for the
    /// 0.2s of the slide-out and no longer — and `show()` did not clear it, so it resurfaced
    /// on an unrelated later summon. The panel staying put IS the notification.
    func testAFailedPickDoesNotDismissThePanel() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Cliphoard/App/AppDelegate.swift"),
            encoding: .utf8)
        for fn in ["private func commit(", "private func copyToClipboard("] {
            guard let start = source.range(of: fn) else { return XCTFail("\(fn) renamed") }
            let rest = source[start.upperBound...]
            // EARLIEST of the plausible next-member markers, not the first one that happens
            // to match. `commit` is followed by `static func failureMessage`, so keying only
            // on "\n    private " overran 3635 chars into the next member — silently.
            let end = ["\n    private ", "\n    static func ", "\n    func ", "\n    // MARK:"]
                .compactMap { rest.range(of: $0)?.lowerBound }.min()
            let body = String(rest[..<(end ?? rest.endIndex)])
            guard let guardRange = body.range(of: "guard outcome.succeeded else {") else {
                return XCTFail("\(fn) no longer guards on the write outcome")
            }
            // Bounded by the guard's OWN closing brace, not by a character count. A fixed
            // window is what broke `ForgetOrderingTests` and `MatchImageControlTests` when
            // the code they watched grew — the same mistake this repo already documents
            // twice. The guard body is indented 12 spaces, so its close is the first
            // 8-space `}` after it.
            let after = body[guardRange.upperBound...]
            let close = after.range(of: "\n        }")
            let failureArm = String(after[..<(close?.lowerBound ?? after.endIndex)])
            // Match the CALL form `hide(paste:`, not the bare word. The failure arm's own
            // comment explains why hide() is no longer called, and a substring search cannot
            // tell prose from a call — precisely the trap `ForgetOrderingTests` documents.
            XCTAssertFalse(failureArm.contains("hide(paste:"),
                           "\(fn) still dismisses the panel on a failed pick. The banner "
                           + "lives inside the panel, so hiding makes the failure invisible "
                           + "at the moment it happens.")
            XCTAssertTrue(failureArm.contains("Feedback.playFailure()"),
                          "\(fn) gives no audible signal on failure, so a failed pick sounds "
                          + "exactly like a successful one")
        }
    }

    /// A banner must never outlive the summon that produced it.
    func testShowClearsAStaleBanner() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Cliphoard/App/AppDelegate.swift"),
            encoding: .utf8)
        guard let start = source.range(of: "private func show() {") else {
            return XCTFail("show() was renamed")
        }
        // Bounded by show()'s OWN closing brace. The first version took `.prefix(1400)` —
        // the very fixed-window pattern the test below condemns — and the needle sat at
        // offset 981, so ~420 characters of added comment would have turned this green for
        // nothing. Two tests in one file cannot disagree about their own stated rule.
        let rest = source[start.upperBound...]
        let close = rest.range(of: "\n    }")
        let body = String(rest[..<(close?.lowerBound ?? rest.endIndex)])
        XCTAssertTrue(body.contains("pasteStatus.blockedMessage = nil"),
                      "show() resets every other piece of per-summon state but not the "
                      + "banner, so a failure message from earlier surfaces on an unrelated "
                      + "later open, describing something the user is no longer doing")
    }
}
