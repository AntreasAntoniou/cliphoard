import XCTest
@testable import Cliphoard

final class SensitiveClipRevealTests: XCTestCase {
    func testGrantRequiresSuccessfulExactPendingRequest() {
        var state = SensitiveRevealState()
        let id = UUID()
        let request = state.begin(id: id, fingerprint: "original")
        XCTAssertFalse(state.permits(id: id, fingerprint: "original", now: 10))
        state.complete(request, success: false, fingerprint: "original", now: 10)
        XCTAssertFalse(state.permits(id: id, fingerprint: "original", now: 10))
        let next = state.begin(id: id, fingerprint: "original")
        state.complete(next, success: true, fingerprint: "original", now: 10)
        XCTAssertTrue(state.permits(id: id, fingerprint: "original", now: 10))
        XCTAssertFalse(state.permits(id: UUID(), fingerprint: "original", now: 10))
        XCTAssertFalse(state.permits(id: id, fingerprint: "changed", now: 10))
    }
    func testExpiryAndRelockFenceLateSuccess() {
        var state = SensitiveRevealState()
        let id = UUID()
        let first = state.begin(id: id, fingerprint: "a")
        state.lock()
        state.complete(first, success: true, fingerprint: "a", now: 10)
        XCTAssertFalse(state.permits(id: id, fingerprint: "a", now: 10))
        let second = state.begin(id: id, fingerprint: "a")
        state.complete(second, success: true, fingerprint: "a", now: 10)
        XCTAssertTrue(state.permits(id: id, fingerprint: "a", now: 69.9))
        XCTAssertFalse(state.permits(id: id, fingerprint: "a", now: 70))
    }
    func testReplacementRequestAndContentChangeFailClosed() {
        var state = SensitiveRevealState()
        let id = UUID()
        let stale = state.begin(id: id, fingerprint: "a")
        let current = state.begin(id: id, fingerprint: "b")
        state.complete(stale, success: true, fingerprint: "a", now: 10)
        XCTAssertFalse(state.permits(id: id, fingerprint: "a", now: 10))
        state.complete(current, success: true, fingerprint: "changed", now: 10)
        XCTAssertFalse(state.permits(id: id, fingerprint: "b", now: 10))
    }
    func testProtectiveAndUnknownFlagsConcealedButContactInformational() {
        XCTAssertTrue(SensitiveClipPolicy.requiresAuthentication(flags: [.secretEntropy]))
        XCTAssertTrue(SensitiveClipPolicy.requiresAuthentication(flags: [.secret]))
        XCTAssertTrue(SensitiveClipPolicy.requiresAuthentication(flags: [.financial, .pii]))
        XCTAssertTrue(SensitiveClipPolicy.requiresAuthentication(flags: ClipFlags(rawValue: 1 << 20)))
        XCTAssertFalse(SensitiveClipPolicy.requiresAuthentication(flags: [.pii]))
        XCTAssertFalse(SensitiveClipPolicy.requiresAuthentication(flags: []))
    }
    func testStoredUnflaggedStripeTokensAreProtected() {
        for prefix in ["whsec_", "rk_live_", "rk_test_", "sk_test_"] {
            let item = ClipItem(kind: .text, text: prefix + "A1b2C3d4E5f6G7h8I9j0")
            XCTAssertTrue(SensitiveClipPolicy.requiresAuthentication(item))
            XCTAssertEqual(item.flags, [], "rendering does not mutate history")
        }
    }
    func testOCRAndPathAreCoveredByFreshDetection() {
        let item = ClipItem(kind: .image, text: "photo")
        item.ocrText = "whsec_" + "A1b2C3d4E5f6G7h8I9j0"
        XCTAssertTrue(SensitiveClipPolicy.requiresAuthentication(item))
        let prior = SensitiveClipPolicy.fingerprint(item)
        item.ocrText = "changed"
        XCTAssertNotEqual(prior, SensitiveClipPolicy.fingerprint(item))
    }
    func testActualEntropyClassificationIsConcealed() {
        let item = ClipItem(kind: .text, text: "mQ7xP2vL9aR5kT8wB3nY6cF1dH4sJ0zV")
        XCTAssertTrue(Detectors.scan(text: item.text, kind: item.kind, sourceApp: nil).flags.contains(.secretEntropy))
        XCTAssertTrue(SensitiveClipPolicy.requiresAuthentication(item))
    }
    func testStandaloneGeneratedPasswordsRequireAuthenticationOnCaptureAndLegacyDisplay() {
        // Invented browser clips, including a shorter password with punctuation
        // outside the API-key alphabet and a longer one with an @ character.
        let examples = ["Q4!zT7#pV2&rK9$x", "fR3@qV7%sB2(Mk9!pX4^wL6}"]
        for example in examples {
            let item = ClipItem(kind: .text, text: example)
            item.sourceApp = "Google Chrome"
            XCTAssertTrue(Detectors.scan(text: example, kind: .text, sourceApp: item.sourceApp)
                .flags.contains(.secretEntropy))
            XCTAssertTrue(SensitiveClipPolicy.requiresAuthentication(item))
            XCTAssertTrue(item.flags.isEmpty)
        }
    }

    func testPasswordHeuristicLeavesCommonBrowserTextVisible() {
        for example in ["Invoice Q4! Ready for pickup #73", "John.Smith+Q4@example.com",
                        "https://Example.org/A4?x=7&tag=Release", "build/Release-24/Test!Data.json",
                        "if(A1!=B2){return(C3+D4);}", "0b6ec23e1a41e67680e6ee1466591357"] {
            let item = ClipItem(kind: .text, text: example)
            item.sourceApp = "Google Chrome"
            XCTAssertFalse(SensitiveClipPolicy.requiresAuthentication(item))
        }
    }

    func testZeroOrNonfiniteClockCannotReviveGrant() {
        var state = SensitiveRevealState()
        let id = UUID()
        let request = state.begin(id: id, fingerprint: "a")
        state.complete(request, success: true, fingerprint: "a", now: 100)
        XCTAssertFalse(state.permits(id: id, fingerprint: "a", now: 99))
        XCTAssertFalse(state.permits(id: id, fingerprint: "a", now: .nan))
        XCTAssertFalse(state.permits(id: id, fingerprint: "a", now: .infinity))
    }

    func testAlternateRichContentRequiresAuthenticationWithoutParsing() {
        let item = ClipItem(kind: .text, text: "ordinary text")
        item.rtf = Data("synthetic alternate rich representation".utf8)
        XCTAssertTrue(SensitiveClipPolicy.requiresAuthentication(item))
        item.rtf = Data()
        XCTAssertFalse(SensitiveClipPolicy.requiresAuthentication(item))
    }
    func testProtectedTagsCannotEscapeThroughAnotherClipSuggestions() {
        let secret = ClipItem(kind: .text, text: "private fixture")
        secret.flags = [.secretEntropy]
        secret.userTags = ["private-label"]
        let ordinary = ClipItem(kind: .text, text: "shopping list")
        ordinary.userTags = ["groceries"]
        XCTAssertEqual(SensitiveClipPolicy.visibleUserTags(in: [secret, ordinary]), ["groceries"])
    }

    func testFingerprintSeparatesTagSequenceFromRichPayload() {
        let item = ClipItem(kind: .text, text: "ordinary text")
        item.userTags = ["label"]
        let before = SensitiveClipPolicy.fingerprint(item)
        item.userTags = []
        item.rtf = Data("5:label".utf8)
        XCTAssertNotEqual(before, SensitiveClipPolicy.fingerprint(item))
    }

}
