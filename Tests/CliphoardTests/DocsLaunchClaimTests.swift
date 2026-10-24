import XCTest
@testable import Cliphoard

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
///   (c) each doc describes the export that ships in 1.0.1, and warns that the passphrase
///       is the only key and cannot be recovered.
///
///       This claim INVERTED, and the test that pinned it stayed green through the
///       inversion — which is the whole reason it is written the way it now is. The old
///       assertion was "the doc contains 1.0.1 and contains export", and both substrings
///       survive the rewrite in all three documents ("1.0.1" also appears independently at
///       README.md:81,83, PRIVACY.md:156,160 and docs/index.html:158). A doc that had
///       stopped saying what the test was written to pin would have reported no failure at
///       all. The positives below are therefore anchored on the SENTENCES that carry the
///       claim, and the retired wording is added to the stale-needle list.
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
            "docs/index.html": ["aes-gcm protects stored content, images, thumbnails, source-app names and search indexes"],
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
            // Retired by 1.0.1. EXPORT-SPECIFIC, deliberately: a bare "is planned for
            // 1.0.1" would turn the suite red on correct documents, because PRIVACY.md
            // still says "hiding is planned for 1.0.1" and "(a Settings UI is planned for
            // 1.0.1)" — both legitimate, both still true.
            "encrypted export/import is planned",
            "there is no export or import",
            "there is no export yet",
            "export/import is planned for 1.0.1",
        ]
        for doc in docs {
            let text = try flat(doc)
            for needle in stale {
                XCTAssertFalse(text.contains(needle),
                               "\(doc) still carries pre-1.0.0 wording: \"\(needle)\"")
            }
        }
    }

    // MARK: - (c) each doc describes the export that ships, and its one hard warning

    func testEveryLaunchDocDescribesTheShippedExport() throws {
        // One anchor per document tying the export to the PASSPHRASE, and one stating that
        // there is no recovery. Both are sentences rather than words, because "export" and
        // "1.0.1" appear in every one of these files for unrelated reasons — which is
        // exactly how the previous version of this test survived the claim inverting.
        let passphraseAnchors: [String: String] = [
            "README.md": "key stretched from your passphrase with pbkdf2-hmac-sha256",
            "PRIVACY.md": "the key comes from your passphrase by pbkdf2-hmac-sha256",
            "docs/index.html": "key derived from your passphrase using pbkdf2-hmac-sha256",
        ]
        let noRecoveryAnchors: [String: [String]] = [
            "README.md": ["nothing is escrowed, a lost passphrase cannot be recovered"],
            "PRIVACY.md": ["there is no recovery. no escrow, no backup key, no reset link",
                           "its only protection is your passphrase"],
            "docs/index.html": ["the passphrase is the only key; there is no recovery or escrow"],
        ]
        for doc in docs {
            let text = try flat(doc)
            // The homepage advertises the current release; the longer reference
            // documents retain the version that introduced encrypted export.
            let release = doc == "docs/index.html" ? "1.0.2" : "1.0.1"
            XCTAssertTrue(text.contains(release), "\(doc) does not name the release")
            XCTAssertTrue(text.contains("export"), "\(doc) does not mention the export")
            let anchor = try XCTUnwrap(passphraseAnchors[doc])
            XCTAssertTrue(text.contains(anchor),
                          "\(doc) no longer ties the export to the passphrase it is "
                          + "protected by (missing: \(anchor))")
            for anchor in noRecoveryAnchors[doc] ?? [] {
                XCTAssertTrue(text.contains(anchor),
                              "\(doc) no longer warns that a lost passphrase cannot be "
                              + "recovered (missing: \(anchor))")
            }
        }
        // The two algorithm names, where the documents actually make the cryptographic
        // claim. If the numbers in PRIVACY.md are going to be specific, they have to be
        // checkable.
        for doc in ["PRIVACY.md", "docs/index.html"] {
            let text = try flat(doc)
            XCTAssertTrue(text.contains("aes-256-gcm"), "\(doc) does not name the cipher")
            XCTAssertTrue(text.contains("pbkdf2"), "\(doc) does not name the KDF")
            XCTAssertTrue(text.contains("600,000"),
                          "\(doc) does not state the iteration floor")
        }
    }

    /// …and the code behind the claim, on the (a) discipline: a doc claim with no code
    /// behind it is the defect this repo keeps re-learning.
    func testTheExportCodeMatchesWhatTheDocsClaimAboutIt() throws {
        // Comment lines dropped: HistoryArchive.swift discusses PBKDF2 at length in prose,
        // and a match on a comment is the trap `ForgetOrderingTests` documents.
        let archive = try read("Sources/Cliphoard/Support/HistoryArchive.swift")
            .split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertTrue(archive.contains("CCKeyDerivationPBKDF"),
                      "the docs say the key is stretched with PBKDF2-HMAC-SHA256, so the "
                      + "code must actually call it")
        XCTAssertTrue(archive.contains("kCCPRFHmacAlgSHA256"),
                      "PBKDF2 with some other PRF is not what the docs claim")
        XCTAssertTrue(archive.contains("AES.GCM.seal"),
                      "the docs say AES-256-GCM")
        XCTAssertGreaterThanOrEqual(
            HistoryArchive.kdfRoundsFloor, 600_000,
            "PRIVACY.md and the site both promise at least 600,000 iterations. The floor "
            + "is a compiled-in constant precisely so that number cannot drift away from "
            + "the binary.")
        XCTAssertEqual(SymmetricKeySizeProbe.exportKeyBytes, 32,
                       "AES-256 means a 32-byte key")
    }
}

/// A tiny indirection so the assertion above reads as a fact about the shipped format
/// rather than as a literal repeated from it.
private enum SymmetricKeySizeProbe {
    static var exportKeyBytes: Int { HistoryArchive.fileKeyLength }
}
