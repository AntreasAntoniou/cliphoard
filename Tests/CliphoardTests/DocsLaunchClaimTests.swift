import XCTest

/// T2: the three launch documents — `README.md`, `PRIVACY.md`, `docs/index.html` — must
/// describe what 1.0.0 actually does, and only that.
///
/// Three claims are pinned here because each was false, or about to become false, at the
/// moment of release:
///
///   (a) the source-app name is encrypted. 1.0.0 seals it (`Crypto.sealStrict(app)` in
///       `Database.swift`); every doc that lists what is encrypted must include it, and the
///       code must actually do it — a doc claim with no code behind it is the defect this
///       repo keeps re-learning.
///   (b) the pre-1.0.0 sync and skip wording is gone. "Point the store at a synced folder"
///       told users to do something the Secure-Enclave-bound key makes useless; "skipped
///       automatically" / "never stored in the first place" described password-manager
///       clips as dropped when they are stored encrypted and quarantined; "you get nothing"
///       from `strings` was an overclaim while timestamps and flags are in the clear.
///   (c) each doc says what is *not* in 1.0.0 — an export/import for moving history to a
///       new Mac — and names the release it is planned for (1.0.1).
///
/// The (a) code assertion lands in a parallel branch; in a worktree that carries only the
/// docs it fails, and it passes once both are merged. That is the point of it.
final class DocsLaunchClaimTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CliphoardTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Lowercased, with Markdown emphasis and HTML `<b>`/`<i>` tags removed and all
    /// whitespace runs collapsed to one space, so a needle never fails on a line wrap or on
    /// bold markers — the docs wrap prose at ~88 columns and the site bolds mid-sentence.
    private func flat(_ path: String) throws -> String {
        var s = try read(path).lowercased()
        for tag in ["<b>", "</b>", "<i>", "</i>", "**", "*"] {
            s = s.replacingOccurrences(of: tag, with: "")
        }
        return s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private let docs = ["README.md", "PRIVACY.md", "docs/index.html"]

    // MARK: - (a) the source app is encrypted, in the code and in every doc

    func testDatabaseSealsTheSourceAppName() throws {
        // Comment lines dropped: Database.swift already discusses `sealStrict` in prose, and
        // a match on a comment is the trap `ForgetOrderingTests` documents.
        let db = try read("Sources/Cliphoard/Clipboard/Database.swift")
            .split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertTrue(db.contains("Crypto.sealStrict(app)"),
                      "Database.swift does not seal the source-app name with "
                      + "Crypto.sealStrict(app) — the docs say it is encrypted, so the code must do it")
    }

    func testEveryLaunchDocSaysTheSourceAppIsEncrypted() throws {
        // One anchor per document, each tying the app name to the encryption claim in the
        // same sentence — a bare mention of "source app" would also match the migration
        // note that says older builds stored it IN THE CLEAR.
        let anchors: [String: [String]] = [
            "README.md": ["the name of the app you copied from — is encrypted at rest"],
            "PRIVACY.md": ["encrypted at rest with aes-gcm: clip content",
                           "the name of the app each clip came from, in the database"],
            "docs/index.html": ["the app you copied from, images and the semantic search index — is sealed with authenticated aes-gcm"],
        ]
        for doc in docs {
            let text = try flat(doc)
            for anchor in anchors[doc] ?? [] {
                XCTAssertTrue(text.contains(anchor),
                              "\(doc) no longer says the source-app name is encrypted (missing: \(anchor))")
            }
        }
    }

    // MARK: - (b) the pre-1.0.0 wording is gone

    func testNoStaleSyncOrSkipWordingSurvives() throws {
        let stale = [
            "point the store",
            "synced folder",
            "never stored in the first place",
            "you get nothing",
            "skipped automatically",
        ]
        for doc in docs {
            let text = try flat(doc)
            for needle in stale {
                XCTAssertFalse(text.contains(needle),
                               "\(doc) still carries pre-1.0.0 wording: \"\(needle)\"")
            }
        }
    }

    // MARK: - (c) each doc names what is deferred, and to which release

    func testEveryLaunchDocNamesTheExportPlanAndItsRelease() throws {
        for doc in docs {
            let text = try flat(doc)
            XCTAssertTrue(text.contains("1.0.1"), "\(doc) does not name 1.0.1")
            XCTAssertTrue(text.contains("export"),
                          "\(doc) does not tell users there is no export yet")
        }
    }
}
