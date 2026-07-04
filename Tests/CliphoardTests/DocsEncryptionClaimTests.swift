import XCTest

/// T8: README.md and PRIVACY.md must honestly describe at-rest encryption now
/// that image payloads + thumbnails are sealed (T3). No stale "image clips are
/// plaintext" caveat may survive, and the full-at-rest-encryption claim must be
/// present and internally consistent across both docs.
final class DocsEncryptionClaimTests: XCTestCase {

    /// Repo root, located relative to this source file:
    /// .../Tests/CliphoardTests/DocsEncryptionClaimTests.swift → up three components.
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CliphoardTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    private func read(_ name: String) throws -> String {
        let url = repoRoot().appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Phrases that signal the obsolete "images aren't encrypted yet" caveat.
    /// Each must be absent from both README.md and PRIVACY.md.
    private let caveatNeedles = [
        "plaintext png",
        "plaintext pngs",
        "not yet encrypted",
        "for now — see",
        "plaintext for now",
        "encrypting them is on",
        "encrypting image payloads is on the roadmap",
    ]

    func testReadmeHasNoImagePlaintextCaveat() throws {
        let lower = try read("README.md").lowercased()
        for needle in caveatNeedles {
            XCTAssertFalse(lower.contains(needle),
                           "README.md still carries the image-plaintext caveat: \(needle)")
        }
    }

    func testPrivacyHasNoImagePlaintextCaveat() throws {
        let lower = try read("PRIVACY.md").lowercased()
        for needle in caveatNeedles {
            XCTAssertFalse(lower.contains(needle),
                           "PRIVACY.md still carries the image-plaintext caveat: \(needle)")
        }
        // The specific honest-caveat sentence must be gone.
        XCTAssertFalse(lower.contains("honest caveat"),
                       "PRIVACY.md still has the honest-caveat paragraph about images")
    }

    /// Both docs must positively state that image clips AND thumbnails are
    /// encrypted at rest (AES-GCM), like text.
    func testDocsClaimImagesAndThumbnailsEncryptedAtRest() throws {
        for name in ["README.md", "PRIVACY.md"] {
            let lower = try read(name).lowercased()
            XCTAssertTrue(lower.contains("encrypted at rest"),
                          "\(name) must claim encryption at rest")
            XCTAssertTrue(lower.contains("image") && lower.contains("thumbnail"),
                          "\(name) must mention images and thumbnails together")
        }
    }

    /// PRIVACY.md must keep the implementation-accurate detail: AES-GCM and a
    /// Secure-Enclave-bound key cover image payloads too.
    func testPrivacyDescribesImageEncryptionAccurately() throws {
        let text = try read("PRIVACY.md")
        let lower = text.lowercased()
        XCTAssertTrue(lower.contains("aes-gcm"), "PRIVACY.md must name AES-GCM")
        XCTAssertTrue(lower.contains("secure enclave"), "PRIVACY.md must name the Secure Enclave")
        XCTAssertTrue(lower.contains("image clips") && lower.contains("thumbnail"),
                      "PRIVACY.md must say image clips and thumbnails are encrypted")
    }

    /// We must not overclaim: the docs may acknowledge that live/in-memory and
    /// pasteboard contents are necessarily unencrypted, but must NOT claim the
    /// pasteboard itself is encrypted.
    func testDocsDoNotOverclaimPasteboardEncryption() throws {
        for name in ["README.md", "PRIVACY.md"] {
            let lower = try read(name).lowercased()
            XCTAssertFalse(lower.contains("pasteboard is encrypted"),
                           "\(name) overclaims pasteboard encryption")
            XCTAssertFalse(lower.contains("encrypted pasteboard"),
                           "\(name) overclaims pasteboard encryption")
        }
    }
}
