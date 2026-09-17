import XCTest
import AppKit
@testable import Cliphoard

/// The surface: the two buttons, the gate they consult, the modal dance they need, and the
/// one thing the passphrase sheet must never do.
///
/// Most of these are source-text assertions, the `PanelModalDismissalTests` / `ImportUITests`
/// idiom, because the behaviour they pin needs a live floating `NSPanel` resigning key to a
/// modal — which cannot be driven headlessly. Asserting nothing here would leave the actual
/// fix untested, which is how the file-picker bug reached a release.
///
/// The last test is not about the UI at all. It lives here because it is the one that fails
/// if someone later "helpfully" adds a plaintext summary so the preview can be shown without
/// a passphrase.
@MainActor
final class HistoryArchiveUITests: ArchiveTestCase {

    private var section: String { (try? source("Sources/Cliphoard/UI/MoveToNewMacSection.swift")) ?? "" }

    // MARK: - 26

    func testBothButtonsAreDisabledInSafeModeWithAVisibleReason() throws {
        let src = section
        XCTAssertEqual(src.components(separatedBy: "store.safeMode").count - 1, 2,
                       "safe mode must be consulted where the buttons are enabled AND "
                       + "again at the commit button — not once, and not in five places")
        let reason = try XCTUnwrap(body(of: "static func gateReason", in: src),
                                   "gateReason was renamed — move this test with it")
        XCTAssertTrue(reason.contains("store.safeMode"),
                      "the gate no longer consults safe mode")
        XCTAssertTrue(reason.lowercased().contains("nothing has been deleted"),
                      "the reason must say what has NOT happened; safe mode is the state "
                      + "that makes every clip render as gibberish, so it manufactures the "
                      + "motive to delete data that is fully recoverable")
        // Disabled AND explained. A control that looks live and does nothing is the defect
        // `FrozenControlsTests` exists for.
        XCTAssertEqual(src.components(separatedBy: ".disabled(gateReason != nil").count - 1, 2,
                       "both buttons must be gated by the same reason")
        XCTAssertTrue(src.contains("if let gateReason {"),
                      "the reason must be RENDERED, not only computed")

        // And the model refuses even if a caller reaches past the disabled button.
        for name in ["func beginExport", "func beginImport"] {
            let body = try XCTUnwrap(self.body(of: name, in: src))
            XCTAssertTrue(body.contains("Self.gateReason(store) == nil"),
                          "\(name) does not re-check the gate, so a keyboard equivalent or "
                          + "a future call site bypasses it")
        }
    }

    // MARK: - 27

    func testTheGateIsASingleCheckAtEveryEntryPoint() throws {
        var sites: [String] = []
        let manager = FileManager.default
        let sources = sourceRoot.appendingPathComponent("Sources")
        let walker = try XCTUnwrap(manager.enumerator(at: sources,
                                                      includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" {
            // The declaration itself is not a call site.
            guard url.lastPathComponent != "ProGate.swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let hits = text.components(separatedBy: "ProGate.allowsHistoryArchive").count - 1
            sites.append(contentsOf: Array(repeating: url.lastPathComponent, count: hits))
        }
        XCTAssertEqual(sites.sorted(),
                       ["Main.swift", "Main.swift",
                        "MoveToNewMacSection.swift", "MoveToNewMacSection.swift"],
                       "the gate must be consulted at exactly four sites — the two buttons "
                       + "and the two command-line flags. The CLI must carry it or the gate "
                       + "is a one-flag bypass, which is not a gate. Found: \(sites)")

        // It ships free, and the file says why rather than leaving a bare `true`.
        let gate = try source("Sources/Cliphoard/Support/ProGate.swift")
        XCTAssertTrue(gate.contains("static var allowsHistoryArchive: Bool { true }"),
                      "the seam must stay one line")
        XCTAssertTrue(ProGate.allowsHistoryArchive)
    }

    // MARK: - 28

    func testTheSystemPanelFlagIsSetAndClearedOnEveryPathIncludingCancel() throws {
        let helper = try source("Sources/Cliphoard/Support/SystemPanel.swift")
        let run = try XCTUnwrap(body(of: "static func run<T>", in: helper))
        XCTAssertTrue(run.contains("isPresentingSystemPanel = true"),
                      "the helper no longer suspends hide-on-resign")
        XCTAssertTrue(run.contains("defer {"),
                      "clearing must happen in a `defer`. Every caller returns early on "
                      + "cancel; a plain assignment after runModal() is skipped by that "
                      + "path and strands the flag at true, which leaves the bar "
                      + "permanently un-dismissable — quieter than the original bug and "
                      + "worse.")
        let deferBody = String(run[try XCTUnwrap(run.range(of: "defer {")).upperBound...]
                                .prefix(300))
        XCTAssertTrue(deferBody.contains("isPresentingSystemPanel = false"))
        XCTAssertTrue(deferBody.contains("onRequestFocus"),
                      "the panel stays visible but loses key focus to the modal, so focus "
                      + "must be asked back or the interface is on screen and inert")

        let runAlert = try XCTUnwrap(body(of: "static func runAlert<T>", in: helper))
        XCTAssertTrue(runAlert.contains("$0.level = .normal"),
                      "NSAlert.runModal() overwrites its own window level with .modalPanel "
                      + "(8) while the bar sits at .mainMenu + 1 (25), so without lowering "
                      + "our windows the user never sees the prompt")
        XCTAssertTrue(runAlert.contains("defer { for (window, level) in saved"),
                      "the levels must be restored on every path")
        XCTAssertTrue(runAlert.contains("return run(model, body)"),
                      "the alert path must still carry the flag, not only the levels")

        // Every new panel goes through the helper…
        let src = section
        for name in ["func beginExport", "func beginImport"] {
            XCTAssertTrue(try XCTUnwrap(body(of: name, in: src)).contains("SystemPanel.run("),
                          "\(name) opens a system window without the exemption")
        }
        XCTAssertTrue(try XCTUnwrap(body(of: "static func ask", in: src))
                        .contains("SystemPanel.runAlert("),
                      "the passphrase sheet needs the window-level dance as well as the flag")

        // …and so does the one that never had it. `ImportPanel.chooseStore` called
        // `runModal()` with NO guard at all, so opening it hid the bar underneath.
        let importPanel = try source("Sources/Cliphoard/UI/ImportPanel.swift")
        let chooseStore = try XCTUnwrap(body(of: "func chooseStore", in: importPanel))
        XCTAssertTrue(chooseStore.contains("SystemPanel.run("),
                      "chooseStore still opens an NSOpenPanel with no exemption")

        // The flag itself still defaults to NOT suppressing.
        let model = PanelViewModel(store: ClipStore(directory: directory("panel")))
        XCTAssertFalse(model.isPresentingSystemPanel)
    }

    // MARK: - 29

    func testTheGenerateButtonNeverTouchesThePasteboard() throws {
        let src = section
        XCTAssertFalse(src.contains("NSPasteboard"),
                       "this is a CLIPBOARD MANAGER. A generated passphrase placed on the "
                       + "pasteboard would be captured into the very history it protects.")
        let generate = try XCTUnwrap(body(of: "@objc private func generate", in: src))
        XCTAssertTrue(generate.contains("field.stringValue = generated"))
        XCTAssertTrue(generate.contains("confirmField.stringValue = generated"),
                      "Generate must fill BOTH fields, or it hands the user a passphrase "
                      + "they then have to retype from a field they cannot read")

        // And capture is suspended for the lifetime of either sheet, so a passphrase
        // pasted in from a password manager is not captured either.
        XCTAssertTrue(try XCTUnwrap(body(of: "static func ask", in: src))
                        .contains("ClipboardMonitor.withCaptureSuspended"),
                      "the sheet does not stand the monitor down")
        let monitor = try source("Sources/Cliphoard/Clipboard/ClipboardMonitor.swift")
        XCTAssertTrue(monitor.contains("if Self.captureSuspensions > 0 {"),
                      "poll() does not honour the suspension, so standing the monitor down "
                      + "does nothing")
        ClipboardMonitor.withCaptureSuspended {
            XCTAssertEqual(ClipboardMonitor.captureSuspensions, 1)
            ClipboardMonitor.withCaptureSuspended {
                XCTAssertEqual(ClipboardMonitor.captureSuspensions, 2,
                               "a COUNTER, not a flag: two overlapping sheets must not have "
                               + "the first to finish re-arm capture underneath the second")
            }
            XCTAssertEqual(ClipboardMonitor.captureSuspensions, 1)
        }
        XCTAssertEqual(ClipboardMonitor.captureSuspensions, 0)
    }

    // MARK: - 30 — the negative-space test

    func testTheHeaderRevealsNothingAboutTheHistory() throws {
        try skipIfKeychainUnreachable()
        let marker = "ZQXJWVKUMBRAVOCADOSENTINEL7743"
        var rows: [ArchiveFixture.Row] = (0..<137).map { n in
            ArchiveFixture.Row(kind: .text, text: "clip body number \(n)",
                               createdAt: 700_000_000 + Double(n),
                               lastUsedAt: 700_000_000 + Double(n))
        }
        rows.append(ArchiveFixture.Row(kind: .text, text: marker,
                                       createdAt: 700_000_500, lastUsedAt: 700_000_500,
                                       sourceApp: "com.example.SecretApp"))
        let dir = directory("negative-space")
        try ArchiveFixture.write(rows, to: dir)
        let store = ClipStore(directory: dir)
        XCTAssertEqual(store.items.count, 138)

        let file = tempRoot.appendingPathComponent("negative.cliphoard")
        let report = try store.exportArchive(to: file, passphrase: "a long enough passphrase").get()
        let bytes = try Data(contentsOf: file)
        let header = Data(bytes.prefix(HistoryArchive.headerLength))
        XCTAssertEqual(header.count, 48)

        func absent(_ needle: Data, _ what: String, in haystack: Data, _ where_: String) {
            guard !needle.isEmpty else { return }
            XCTAssertNil(haystack.range(of: needle),
                         "\(what) is readable in \(where_). The header carries no clip "
                         + "count, no dates, no machine name and no sizes — the ONLY "
                         + "description of this history is the sealed summary, and opening "
                         + "it IS the passphrase check.")
        }

        absent(Data(marker.utf8), "a clip's text", in: bytes, "the file at all")
        absent(Data("com.example.SecretApp".utf8), "an app name", in: bytes, "the file at all")
        absent(Data(report.summary.machineName.utf8), "the machine name", in: header, "the header")
        absent(Data(report.summary.exportedAt.utf8), "the export date", in: header, "the header")
        // The clip count, in every encoding wide enough to be a signal rather than a
        // coincidence. A two-byte needle in twenty random bytes is a coin flip, not evidence.
        absent(Data("138".utf8), "the clip count in decimal", in: header, "the header")
        absent(HistoryArchive.be32(138), "the clip count, 4-byte big-endian", in: header, "the header")
        absent(HistoryArchive.be64(138), "the clip count, 8-byte big-endian", in: header, "the header")
        absent(Data([138, 0, 0, 0]), "the clip count, 4-byte little-endian", in: header, "the header")
        // A plausible timestamp.
        absent(HistoryArchive.be32(700_000_500), "a clip date", in: header, "the header")
        absent(withUnsafeBytes(of: Double(700_000_500).bitPattern) { Data($0) },
               "a clip date as a double", in: header, "the header")

        // The summary block is the CONSTANT 1040 bytes whatever the history looks like.
        XCTAssertEqual(HistoryArchive.readBE32(header, at: 40), 1040)
        var tiny = report.summary
        tiny.clipCount = 1
        tiny.machineName = "a"
        tiny.byKind = ["text": 1]
        var huge = report.summary
        huge.clipCount = 9_999_999
        huge.machineName = String(repeating: "a very long machine name ", count: 200)
        XCTAssertEqual(try tiny.paddedPlaintext().count, 1024)
        XCTAssertEqual(try huge.paddedPlaintext().count, 1024,
                       "a machine name long enough to overflow must be TRUNCATED, not "
                       + "allowed to grow the block — a variable-length summary leaks its "
                       + "own length, which correlates with the name and the clip count")
        XCTAssertEqual(Int(HistoryArchive.summaryLength), 1024 + 16)
    }
}
