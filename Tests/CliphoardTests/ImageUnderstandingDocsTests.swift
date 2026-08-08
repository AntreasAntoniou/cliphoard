import XCTest
@testable import Cliphoard

/// TP-18: the privacy policy must not be able to drift away from the code.
///
/// Reading text out of a user's screenshots is a capability people would reasonably want
/// disclosed, and PRIVACY.md now discloses it — including two specific promises: a
/// setting that turns it off, and a button that erases what has already been read. A
/// policy that promises a control which does not exist is worse than one that says
/// nothing, so those promises are pinned here in both directions: the document must make
/// the claims, AND the code must implement them.
///
/// Follows the `#filePath` idiom already used by DocsEncryptionClaimTests.
final class ImageUnderstandingDocsTests: XCTestCase {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(name), encoding: .utf8)
    }

    /// Disclosure, not burial. If recognition ships, the policy has to say so.
    func testPrivacyPolicyDisclosesReadingTextFromImages() throws {
        let lower = try read("PRIVACY.md").lowercased()
        XCTAssertTrue(lower.contains("reads the text inside your images")
                      || lower.contains("read text in images"),
                      "PRIVACY.md must state plainly that Cliphoard reads text inside images")
        XCTAssertTrue(lower.contains("vision"),
                      "PRIVACY.md must name the framework doing the recognition")
        XCTAssertTrue(lower.contains("on your mac") || lower.contains("no network"),
                      "PRIVACY.md must state recognition happens locally")
    }

    /// The document must describe the withholding, because that is the entire reason the
    /// feature is defensible — and it must not be vaguer than the code.
    func testPrivacyPolicyDescribesWhatIsWithheld() throws {
        let lower = try read("PRIVACY.md").lowercased()
        for needle in ["credential", "one-time code", "entropy", "address"] {
            XCTAssertTrue(lower.contains(needle),
                          "PRIVACY.md must say that '\(needle)'-like text is not stored — "
                          + "ClipItem.ocrWithholdFlags withholds on it")
        }
    }

    /// The known gap must be stated. It would be easy and dishonest to describe the
    /// one-time-code protection without saying it misses the commonest case.
    func testPrivacyPolicyAdmitsTheAuthenticatorGap() throws {
        let lower = try read("PRIVACY.md").lowercased()
        XCTAssertTrue(lower.contains("authenticator"),
                      "PRIVACY.md must disclose that authenticator-style codes (two short "
                      + "digit groups, no keyword) are NOT reliably withheld — detectOTP "
                      + "structurally cannot see them")
    }

    /// Both promised controls must exist in code. This is the direction that actually
    /// catches drift: someone deleting the button would otherwise leave the policy
    /// promising it forever.
    func testPromisedControlsExistInCode() throws {
        let settings = try read("Sources/Cliphoard/UI/SettingsView.swift")
        XCTAssertTrue(settings.contains("Read text in images"),
                      "PRIVACY.md promises a 'Read text in images' setting; it is missing")
        XCTAssertTrue(settings.contains("Forget recognised text"),
                      "PRIVACY.md promises a 'Forget recognised text' button; it is missing")

        let store = try read("Sources/Cliphoard/Clipboard/ClipStore.swift")
        XCTAssertTrue(store.contains("func forgetImageUnderstanding()"),
                      "the Forget button has no implementation behind it")
        XCTAssertTrue(store.contains("static var imageUnderstandingEnabled"),
                      "the toggle has no backing setting")

        let db = try read("Sources/Cliphoard/Clipboard/Database.swift")
        XCTAssertTrue(db.contains("func forgetAllImageUnderstanding()"),
                      "Forget has no on-disk erasure")
        // Without the compaction, "forget" leaves the words recoverable in free pages —
        // a delete button that does not delete.
        let forgetBody = db.range(of: "func forgetAllImageUnderstanding()")
            .map { String(db[$0.lowerBound...].prefix(300)) } ?? ""
        XCTAssertTrue(forgetBody.contains("vacuum()"),
                      "forgetAllImageUnderstanding must VACUUM — otherwise the erased text "
                      + "lingers in free pages and the promise is false")
    }

    /// The withhold set the policy describes must be the one the code uses. If someone
    /// narrows the code, this fails rather than letting the document quietly overclaim.
    func testCodeWithholdsEverythingThePolicyClaims() {
        let withhold = ClipItem.ocrWithholdFlags
        for (name, flag) in [("secret", ClipFlags.secret),
                             ("high-entropy", .secretEntropy),
                             ("one-time code", .otp),
                             ("payment/bank", .financial),
                             ("postal address", .piiSensitive),
                             ("quarantined origin", .quarantined)] {
            XCTAssertTrue(withhold.contains(flag),
                          "PRIVACY.md tells users \(name) text is not stored, but "
                          + "ocrWithholdFlags no longer withholds on it")
        }
    }
}
