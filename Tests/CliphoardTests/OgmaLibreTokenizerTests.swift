import XCTest
@testable import Cliphoard

/// Bit-for-bit parity of the Swift libre tokenizer scheme against reference ids
/// produced by the REAL SentencePiece model (Fixtures/ogma-libre-ref.json, made
/// by tools: `sp.Encode(text)` → +7 → wrap bos=2/eos=3). Loads the actual
/// open-ogma-small tokenizer folder from tools/models; skips when it hasn't
/// been restored (tools/restore-models.sh).
final class OgmaLibreTokenizerParityTests: XCTestCase {
    private var tokenizerDir: URL {
        if let d = ProcessInfo.processInfo.environment["CLIPHOARD_OGMA_MODEL_DIR"], !d.isEmpty {
            return URL(fileURLWithPath: d).appendingPathComponent("open-ogma-small")
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools/models/open-ogma-small")
    }

    private struct RefCase: Decodable { let text: String; let ids: [Int] }

    func testMatchesSentencePieceReferenceBitForBit() throws {
        guard FileManager.default.fileExists(
            atPath: tokenizerDir.appendingPathComponent("tokenizer.json").path) else {
            throw XCTSkip("open-ogma-small tokenizer not present — restore via tools/restore-models.sh")
        }
        let tok = try XCTUnwrap(OgmaTokenizer(folder: tokenizerDir))
        let refURL = try XCTUnwrap(Bundle.module.url(
            forResource: "Fixtures/ogma-libre-ref", withExtension: "json"))
        let cases = try JSONDecoder().decode([RefCase].self, from: Data(contentsOf: refURL))
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            XCTAssertEqual(tok.encode(c.text), c.ids,
                           "libre tokenizer diverged from sp reference for: \(c.text.prefix(60))")
        }
    }

    func testLibreSchemeFramesWithRawBosEos() throws {
        guard FileManager.default.fileExists(
            atPath: tokenizerDir.appendingPathComponent("tokenizer.json").path) else {
            throw XCTSkip("open-ogma-small tokenizer not present")
        }
        let tok = try XCTUnwrap(OgmaTokenizer(folder: tokenizerDir))
        let ids = tok.encode("hello")
        XCTAssertEqual(ids.first, 2, "libre bos is the raw model id 2 (not offset)")
        XCTAssertEqual(ids.last, 3, "libre eos is the raw model id 3 (not offset)")
        XCTAssertTrue(ids.dropFirst().dropLast().allSatisfy { $0 >= 7 },
                      "sp vocab ids sit above the 7 reserved specials")
    }
}
