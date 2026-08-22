import XCTest
@testable import Cliphoard

/// The Settings surface for imports.
///
/// The engine shipped weeks before any way to reach it: it was a command-line flag that had
/// to be run from inside the `.app` bundle. Meanwhile the site advertised "bring your
/// history". A feature nobody can find is not shipped, however well it is tested.
///
/// What these pin is the SAFETY SHAPE, not the pixels. Nine of the ten adapters have never
/// been executed against a real store — none of those apps is installed on the machine they
/// were written on — so a one-click Import would take an untested parser and write its
/// output straight into someone's history. The preview step is the whole point, and it is
/// the first thing a well-meaning simplification would remove.
@MainActor
final class ImportUITests: XCTestCase {

    private func tempStore() -> ClipStore {
        ClipStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("DittoImportUI-\(UUID().uuidString)"))
    }

    /// A scan lists only sources whose store EXISTS here. Ten rows for someone who uses one
    /// clipboard manager is nine invitations to click something that cannot work.
    func testScanOnlyOffersSourcesPresentOnThisMachine() {
        let model = ImportModel()
        model.scan()
        for candidate in model.candidates {
            XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path),
                          "\(candidate.source.id) was offered but its store is not at "
                          + "\(candidate.path) — the row cannot do anything")
        }
    }

    /// Nothing is written before a preview. This is the assertion that matters most: it is
    /// the difference between "you saw what an untested parser produced" and "an untested
    /// parser edited your clipboard history".
    func testAPreviewWritesNothing() throws {
        try skipIfKeychainUnreachable()
        let store = tempStore()
        try XCTSkipIf(store.safeMode, "frozen store here")
        // Against the REAL Paste export, not against whatever happens to be installed.
        // `scan()` only looks where an app would install its store, so on a machine with no
        // clipboard manager this test skipped — and a skipped test is indistinguishable
        // from a passing one in a summary line. The export is the verified fixture: 7,775
        // rows of genuine Core Data, the same data the adapter was developed against.
        let export = ("~/exports-2026-06-26/paste-export/com.wiheads.paste-setapp/db.sqlite"
                      as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: export),
              let paste = ClipImporters.all.first(where: { $0.id == "paste" }) else {
            throw XCTSkip("the Paste export fixture is not on this machine, so there is no "
                          + "real store to preview against. Not a pass.")
        }
        let model = ImportModel()
        let candidate = ImportModel.Candidate(source: paste, path: export)
        let before = store.items.count
        model.dryRun(candidate, store: store)
        XCTAssertEqual(store.items.count, before,
                       "a preview added clips to the store. The preview exists precisely so "
                       + "an untested adapter can be inspected BEFORE it writes anything.")
        XCTAssertNotNil(model.preview, "the preview produced no tally to inspect")
    }

    /// The preview must carry a per-kind breakdown, because that breakdown IS the check.
    /// A misreading adapter shows up as everything arriving under one kind — visible at a
    /// glance here, invisible in a progress bar or a bare total.
    func testThePreviewReportsAKindBreakdownNotJustATotal() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Cliphoard/UI/ImportPanel.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains("let byKind:"),
                      "the preview no longer carries a per-kind breakdown, so a parser "
                      + "misreading a store looks identical to one reading it correctly")
        XCTAssertTrue(source.contains("ForEach(preview.byKind"),
                      "the breakdown is computed but never shown — the user sees a total "
                      + "and has nothing to judge it by")
    }

    /// Unverified adapters must SAY SO in the interface. The user is consenting to run a
    /// parser that has never been executed; that fact belongs on screen, not in a comment.
    func testUnverifiedAdaptersAreLabelledInTheUI() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Cliphoard/UI/ImportPanel.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains("confidence != .verified"),
                      "the UI no longer distinguishes a verified importer from one that has "
                      + "never been run — the CLI refuses to write without --force for "
                      + "exactly this reason, and the UI must not be the lax path")
        XCTAssertTrue(source.contains("untested importer"),
                      "the warning text is gone; `confidence` is checked but says nothing")
    }

    /// A frozen store must not be importable into. Every write path in this app refuses in
    /// safe mode; an import that bypassed it would be the largest such write there is.
    func testImportControlsRefuseWhileTheStoreIsFrozen() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Cliphoard/UI/ImportPanel.swift"),
            encoding: .utf8)
        XCTAssertEqual(source.components(separatedBy: "store.safeMode").count - 1, 2,
                       "expected BOTH the Preview and the Import buttons to be disabled in "
                       + "safe mode; found a different number of guards")
    }

    /// Imported batches stay reversible: the marker is what makes "undo this import" a
    /// single query rather than an archaeology exercise.
    func testEveryImportIsTaggedWithItsSourceMarker() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Cliphoard/UI/ImportPanel.swift"),
            encoding: .utf8)
        XCTAssertEqual(source.components(separatedBy: #"marker: "import-\("#).count - 1, 2,
                       "both the preview and the commit must use the same per-source marker, "
                       + "or the preview's dedup count will not match what the import does")
    }
}
