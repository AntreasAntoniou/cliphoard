import XCTest
@testable import Cliphoard

/// Regression tests for the hand-rolled ogma tokenizer (audit H3 / BL-T3).
/// Uses a tiny checked-in tokenizer fixture (vocab: [CLS]=2, [SEP]=3, ▁foo/▁bar/
/// ▁baz/▁hello/▁world; n_special_tokens offset = 7).
final class OgmaTokenizerTests: XCTestCase {
    private func tokenizer() throws -> OgmaTokenizer {
        let folder = Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures/ogma-mini")
        return try XCTUnwrap(OgmaTokenizer(folder: folder), "fixture tokenizer should load")
    }

    private let unkOffset = 1 + 7   // unk_id 1 + n_special_tokens offset
    private let cls = 2 + 7
    private let sep = 3 + 7

    func testSingleLineEncodesWithClsSepAndOffset() throws {
        let tok = try tokenizer()
        // foo bar -> [CLS, ▁foo(4), ▁bar(5), SEP] + 7
        XCTAssertEqual(tok.encode("foo bar"), [cls, 4 + 7, 5 + 7, sep])
    }

    func testMultiLineDoesNotProduceUnkRuns() throws {
        let tok = try tokenizer()
        // The H3 bug: "foo\nbar\tbaz" was one metaspace word -> not in vocab -> UNK.
        let ids = tok.encode("foo\nbar\tbaz")
        XCTAssertEqual(ids, [cls, 4 + 7, 5 + 7, 6 + 7, sep], "newline/tab split like spaces")
        XCTAssertFalse(ids.contains(unkOffset), "no spurious UNK ids for multi-line input")
    }

    func testCollapsesRepeatedAndMixedWhitespace() throws {
        let tok = try tokenizer()
        XCTAssertEqual(tok.encode("  foo \n\t  bar  "), [cls, 4 + 7, 5 + 7, sep])
    }

    func testUnknownWordFallsBackToUnk() throws {
        let tok = try tokenizer()
        let ids = tok.encode("zzqq")           // not in the tiny vocab
        XCTAssertEqual(ids.first, cls)
        XCTAssertEqual(ids.last, sep)
        XCTAssertTrue(ids.contains(unkOffset), "OOV content yields UNK")
    }

    func testMissingFolderReturnsNil() {
        XCTAssertNil(OgmaTokenizer(folder: URL(fileURLWithPath: "/no/such/dir")))
    }

    /// CP-01: a large whitespace-free clip (base64/minified blob) used to become
    /// one giant metaspace word and drive an O(n^2) Viterbi that hung the main
    /// actor. The encode-time prefix cap + windowed Viterbi must keep both the
    /// work and the emitted id count bounded — NOT proportional to the input.
    func testLargeWhitespaceFreeInputIsBounded() throws {
        let tok = try tokenizer()
        let n = 200_000
        let blob = String(repeating: "a", count: n)   // no whitespace, all OOV -> UNK path

        let start = Date()
        let ids = tok.encode(blob)
        let elapsed = Date().timeIntervalSince(start)

        // Bounded by the internal 4096-Character prefix cap (+ metaspace + CLS/SEP),
        // decisively less than the 200k-scale count the O(n^2) path would imply.
        XCTAssertLessThan(ids.count, 4_200, "id count must track the cap, not the input length")
        XCTAssertLessThan(ids.count, n / 10, "id count must not be proportional to input size")
        XCTAssertEqual(ids.first, cls)
        XCTAssertEqual(ids.last, sep)
        // Comfortably fast; the un-capped O(n^2) path would take many seconds.
        XCTAssertLessThan(elapsed, 2.0, "encoding a large blob must stay fast")
    }
}
