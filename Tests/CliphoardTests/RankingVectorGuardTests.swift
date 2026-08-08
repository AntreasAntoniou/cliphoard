import XCTest
@testable import Cliphoard

/// TP-14: the veto must not be re-implementable by hand.
///
/// `SemanticRanker.rankingVector(for:embedder:)` is the single sanctioned way to get a
/// clip's vector for ranking: cache, then veto, then model. Before it existed, all
/// three ranking modes carried their own copy of that sequence — and an earlier build
/// shipped the bug that follows from duplication: the fallback `embedder.embed(
/// searchText(item))` ran unguarded, so a `.secret` clip went through the model on
/// EVERY keystroke instead of never.
///
/// The accessor fixes today's three sites. This file is about tomorrow's fourth. It is
/// deliberately a SOURCE assertion rather than a type-level one: a wrapper type with a
/// private initialiser was considered and rejected, because `isIndexVetoed` reads
/// `flags`, which mutates after capture — a token proving "not vetoed at time T" can
/// outlive its own truth and still compile. Reading the predicate at the moment of use
/// is the safer design, and this test is what protects it.
///
/// Honest about its limits: this greps source text. It cannot catch a call spelled
/// differently, and it is not a proof. It is a tripwire, and a tripwire that names the
/// rule when it fires beats a convention nobody reads. The `#filePath` idiom is already
/// used in this suite by `DocsEncryptionClaimTests`.
final class RankingVectorGuardTests: XCTestCase {

    /// Records every string handed to the model. The whole point of the veto is that a
    /// vetoed clip's text is NEVER offered — asserting "no vector was stored" is weaker,
    /// because the text could still have made the round trip.
    private final class SpyEmbedder: TextEmbedder {
        var signature: String { "spy-8" }
        var dimension: Int { 8 }
        private(set) var sawTexts: [String] = []
        private let unit: Bool
        init(unit: Bool = false) { self.unit = unit }
        func embed(_ text: String) -> [Float] {
            sawTexts.append(text)
            var v = [Float](repeating: 0, count: 8)
            if unit { v[0] = 1 }
            return v
        }
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CliphoardTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(path), encoding: .utf8)
    }

    /// The raw "embed this clip's text" idiom may appear ONLY inside `rankingVector`.
    /// Anywhere else it is a ranking path that forgot the veto.
    func testClipTextIsOnlyEmbeddedInsideRankingVector() throws {
        let deepSearch = try source("Sources/Cliphoard/Search/DeepSearch.swift")
        let offenders = deepSearch
            .components(separatedBy: .newlines)
            .enumerated()
            .filter { _, line in
                line.contains("embed(searchText(")
                    && !line.contains("///")            // the doc comment quotes it
                    && !line.contains("return embedder.embed(searchText(item))")
            }
            .map { "  DeepSearch.swift:\($0.offset + 1): \($0.element.trimmingCharacters(in: .whitespaces))" }

        XCTAssertTrue(offenders.isEmpty, """
            A clip's text is being embedded outside SemanticRanker.rankingVector.

            That is how the veto was defeated before: a ranking mode that embeds
            `searchText(item)` directly will push a `.secret` or `.quarantined` clip
            through the model on every query. Call `rankingVector(for:embedder:)`
            instead — it does cache → veto → model in the right order.

            Offending lines:
            \(offenders.joined(separator: "\n"))
            """)
    }

    /// The accessor must actually contain the guard, not merely exist. A refactor that
    /// kept the name and dropped the check would pass the test above trivially.
    func testRankingVectorItselfStillCarriesTheVeto() throws {
        let deepSearch = try source("Sources/Cliphoard/Search/DeepSearch.swift")
        guard let body = deepSearch.range(of: "static func rankingVector(for item: ClipItem")
            .map({ String(deepSearch[$0.lowerBound...].prefix(400)) })
        else { return XCTFail("rankingVector is gone — the veto has no single home any more") }

        XCTAssertTrue(body.contains("guard !item.isIndexVetoed"),
                      "rankingVector no longer guards on isIndexVetoed, so every ranking "
                      + "mode that trusts it is now embedding vetoed clips")
        XCTAssertTrue(body.contains("item.embeddings[embedder.signature]"),
                      "rankingVector no longer checks the cache first, so ranking re-embeds "
                      + "every clip on every keystroke")
    }

    /// Behavioural companion to the source checks: a vetoed clip yields nothing, and the
    /// embedder is never asked. Proves the rule, where the greps only protect it.
    func testVetoedClipIsNeverOfferedToTheEmbedder() {
        let spy = SpyEmbedder()
        let secret = ClipItem(kind: .text, text: "AKIA" + "IOSFODNN7EXAMPLE")
        secret.flags = [.secret]
        XCTAssertTrue(secret.isIndexVetoed, "precondition: .secret must veto indexing")

        let vec = SemanticRanker.rankingVector(for: secret, embedder: spy)

        XCTAssertTrue(vec.isEmpty, "a vetoed clip must rank with no vector at all")
        XCTAssertTrue(spy.sawTexts.isEmpty,
                      "the vetoed clip's text reached the embedder: \(spy.sawTexts)")
    }

    /// The other half — an ordinary clip must still be embedded, or the guard has been
    /// widened into a silent search regression.
    func testOrdinaryClipIsStillEmbedded() {
        let spy = SpyEmbedder(unit: true)
        let ordinary = ClipItem(kind: .text, text: "git rebase --onto main")

        let vec = SemanticRanker.rankingVector(for: ordinary, embedder: spy)

        XCTAssertEqual(vec.count, 8)
        XCTAssertEqual(spy.sawTexts, ["git rebase --onto main"])
    }
}
