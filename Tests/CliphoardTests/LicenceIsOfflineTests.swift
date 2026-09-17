import XCTest
@testable import Cliphoard

/// THE TEST THAT KEEPS THREE SENTENCES HONEST.
///
/// `README.md:41` and `PRIVACY.md:208` say "zero network calls". `docs/index.html` says it
/// twice more. Those sentences are the strongest thing this project has to say, and a licence
/// check is the single most likely place for them to quietly stop being true: every other
/// paid app on the platform phones home, so "just call the server" is the path of least
/// resistance for any future change here.
///
/// So this is a SOURCE scan, not a behavioural one. A behavioural test ("no connection was
/// made during this run") passes on every run that happens not to take the branch; a source
/// scan fails the moment the capability enters the file, which is the moment the sentence
/// stops being true.
///
/// The scan is over CODE LINES ONLY, and that detail cost a run already: `Licence.swift`'s
/// doc comment legitimately explains why the Keychain is NOT used, and the first version of
/// this scan matched its own prose — the trap `ForgetOrderingTests` documents in this repo,
/// met again here. Comments are stripped; the ban is on what the compiler sees.
final class LicenceIsOfflineTests: XCTestCase {

    /// Anything that would make the app itself open a socket. `NSWorkspace.open` is
    /// deliberately NOT on this list and deliberately mentioned: handing a URL to the user's
    /// browser is the buy button, and it is not a request this app makes.
    private let networkAPIs = ["URLSession", "URLRequest", "NSURLConnection", "CFReadStream",
                               "NWConnection", "Network.framework", "URLDownload",
                               "dataTask", "downloadTask", "uploadTask", "WebSocket"]

    private func root() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: root().appendingPathComponent(path), encoding: .utf8)
    }

    /// Comments stripped, so prose ABOUT an API is not mistaken for a use of it.
    private func codeLines(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testLicenceSwiftTouchesNoNetworkAndNoKeychain() throws {
        let code = codeLines(try source("Sources/Cliphoard/Support/Licence.swift"))
        for forbidden in networkAPIs + ["SecItem", "SecItemCopyMatching", "SecItemAdd",
                                        "kSecClass", "Keychain", "FileManager", "Process("] {
            XCTAssertFalse(code.contains(forbidden),
                           "Licence.swift references \(forbidden). The key is verified on the "
                           + "user's Mac against a public key compiled in; the moment this "
                           + "file can reach a network or the Keychain, README.md:41, "
                           + "PRIVACY.md:208 and two lines of docs/index.html become false.")
        }
        // Storage is UserDefaults ON PURPOSE — STATUS.md records a keychain incident that put
        // this maintainer's own install into read-only safe mode, and a licence must keep
        // working when the store is frozen. The key is public data signed by a private key,
        // so it has no confidentiality requirement, and a forged `defaults write` fails the
        // signature. That is an argued choice, so it is pinned rather than left to drift.
        XCTAssertTrue(code.contains("UserDefaults.standard"),
                      "licence storage moved off UserDefaults — if it moved to the Keychain, "
                      + "read STATUS.md first: a paying customer locked out by a keychain "
                      + "fault is a refund and a support burden, not a security win")
        XCTAssertEqual(Licence.publicKey.count, 32, "an Ed25519 public key is exactly 32 bytes")
    }

    /// The six gate sites. A licence check that stays offline while a GATE reaches out —
    /// "just check the order id" — leaks exactly the same promise.
    func testNoGateSiteIntroducesANetworkCall() throws {
        for path in ["Sources/Cliphoard/Support/Licence.swift",
                     "Sources/Cliphoard/Search/DeepSearch.swift",
                     "Sources/Cliphoard/Clipboard/ClipStore.swift",
                     "Sources/Cliphoard/UI/SettingsView.swift",
                     "Sources/Cliphoard/UI/ContentView.swift",
                     "Sources/Cliphoard/UI/ImportPanel.swift",
                     "Sources/Cliphoard/UI/ProUpsell.swift"] {
            let code = codeLines(try source(path))
            for forbidden in networkAPIs {
                XCTAssertFalse(code.contains(forbidden),
                               "\(path) now references \(forbidden) — no gate site may make a "
                               + "network call. Buying is a URL handed to the browser, never a "
                               + "request this app sends.")
            }
        }
    }

    /// The buy button opens a URL in the user's browser and that is the ONLY outbound thing
    /// the paid split adds. Pinned in both directions: the mechanism must be `NSWorkspace`,
    /// and the destination must be `Licence.buyURL` rather than a literal that drifts.
    func testBuyingHandsAURLToTheBrowserRatherThanCallingOut() throws {
        let upsell = codeLines(try source("Sources/Cliphoard/UI/ProUpsell.swift"))
        XCTAssertTrue(upsell.contains("NSWorkspace.shared.open(Licence.buyURL)"),
                      "the Get Pro button no longer opens Licence.buyURL through NSWorkspace")
        for path in ["Sources/Cliphoard/UI/SettingsView.swift",
                     "Sources/Cliphoard/UI/ProUpsell.swift"] {
            let code = codeLines(try source(path))
            XCTAssertFalse(code.contains("https://") && !code.contains("Licence.buyURL"),
                           "\(path) hard-codes a checkout URL instead of using Licence.buyURL")
        }
    }

    /// `verify` is pure and total: no input crashes it, and the same input always gives the
    /// same answer. Offline is not only about sockets — a gate that threw, hung or varied
    /// would be a licence check that can lock a paying customer out of their own clipboard.
    func testVerifyIsTotalAndDeterministic() {
        let inputs = ["", " ", "CLIP1-", "CLIP1-.", "CLIP1-a.b", "CLIP2-a.b", "not a key",
                      "CLIP1-" + String(repeating: "A", count: 5000) + ".B",
                      "CLIP1-💥.💥", String(repeating: "\u{0}", count: 64)]
        for input in inputs {
            let first = Licence.verify(input)
            let second = Licence.verify(input)
            XCTAssertFalse(first.isPro, "'\(input.prefix(16))' must not verify")
            XCTAssertEqual(first, second, "verify is not deterministic for '\(input.prefix(16))'")
        }
    }
}
