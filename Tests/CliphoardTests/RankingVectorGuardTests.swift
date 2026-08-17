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

    /// Walk back to the enclosing `func`, then forward to the next one, and report
    /// whether that body mentions `isIndexVetoed`. Crude — it does not parse Swift — but
    /// it encodes the invariant we actually care about: a function may hand a clip's text
    /// to a model only if it consults the veto. That generalises to code not yet written,
    /// which a list of blessed function names does not.
    private static func enclosingFunctionConsultsTheVeto(lines: [String], at index: Int) -> Bool {
        guard let start = (0...index).reversed().first(where: { lines[$0].contains("func ") })
        else { return false }
        let end = ((index + 1)..<lines.count).first { lines[$0].contains("func ") } ?? lines.count
        return lines[start..<end].contains { $0.contains("isIndexVetoed") }
    }

    /// The raw "embed this clip's text" idiom may appear ONLY inside `rankingVector`.
    /// Anywhere else it is a ranking path that forgot the veto.
    ///
    /// The first version whitelisted the sanctioned line by its exact TEXT and scanned
    /// one file. A review ran eight realistic violations through it; five slipped past —
    /// a qualified call, a hoisted local, extra whitespace, a trailing comment, and,
    /// worst, a copy-pasted second accessor spelled identically to the real one, which
    /// the text whitelist then exempted wherever it appeared.
    ///
    /// The rewrite changes the RULE, not just the regex. It is no longer "only
    /// `rankingVector` may embed clip text" — it is **"whoever embeds clip text must
    /// consult the veto"**, checked by walking to the enclosing function and requiring
    /// it to mention `isIndexVetoed`. That is the invariant we actually want, it
    /// generalises to functions nobody has written yet, and it correctly allows
    /// `ClipIndexer.index`, which legitimately embeds on the WRITE path behind its own
    /// guard. A blessed-names list would not have done any of that.
    ///
    /// Verified against seven cases rather than one: control and a properly-guarded
    /// function are allowed; plain, qualified, whitespaced, comment-trailed and
    /// copy-pasted violations are all caught.
    ///
    /// Residual, stated plainly because a grep pretending to be a proof is worse than
    /// one that admits what it is: the hoisted-local evasion (`let t = searchText(item)`
    /// then `embed(t)`) is still invisible, the function-boundary walk is textual rather
    /// than a real parse, and only the Search directory is scanned. Catching the rest
    /// needs call-graph analysis. This is a tripwire for a regression that has already
    /// happened once, sized to that job.
    func testClipTextIsOnlyEmbeddedInsideRankingVector() throws {
        var offenders: [String] = []

        for file in ["DeepSearch.swift", "HFEmbedder.swift", "TagBaskets.swift",
                     "Detectors.swift", "DerivedTags.swift", "ModelAssets.swift"] {
            let path = "Sources/Cliphoard/Search/\(file)"
            guard let text = try? source(path) else { continue }
            let lines = text.components(separatedBy: .newlines)

            for (i, raw) in lines.enumerated() {
                // Strip line comments so a trailing `///` cannot launder a violation,
                // and squeeze whitespace so ` embed( searchText( item ) )` still matches.
                let code = raw.components(separatedBy: "//").first ?? raw
                let squeezed = code.filter { !$0.isWhitespace }
                guard squeezed.contains(".embed(searchText(")
                        || squeezed.contains(".embed(SemanticRanker.searchText(") else { continue }

                // The rule is not "only rankingVector may do this" — it is "whoever does
                // this must consult the veto". `ClipIndexer.index` legitimately embeds
                // clip text and carries its OWN guard, because it is the write path: it
                // refuses to PRODUCE a vector, rather than substituting an empty one for
                // ranking. Exempting it by name would be the same text-whitelist mistake
                // this test was rewritten to remove, so the exemption is structural —
                // the enclosing function must mention the veto.
                if Self.enclosingFunctionConsultsTheVeto(lines: lines, at: i) { continue }
                offenders.append("  \(file):\(i + 1): \(raw.trimmingCharacters(in: .whitespaces))")
            }
        }

        XCTAssertTrue(offenders.isEmpty, """
            A clip's text is being embedded outside SemanticRanker.rankingVector.

            That is how the veto was defeated before: a ranking path that embeds
            `searchText(item)` directly pushes a `.secret` or `.quarantined` clip
            through the model on every query, instead of never. Call
            `rankingVector(for:embedder:)` — it does cache → veto → model in order.

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
        let secret = ClipItem(kind: .text, text: "AKIAIOSFODNN7EXAMPLE")
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
