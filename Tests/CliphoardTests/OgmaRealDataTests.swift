import XCTest
import CoreML
@testable import Cliphoard

/// REAL-DATA proof that the on-device ogma model does genuine SEMANTIC retrieval,
/// not lexical matching. It loads the actual `ogma-small` CoreML model, embeds a
/// corpus of realistic clipboard entries, and runs natural-language queries whose
/// wording deliberately shares (almost) no words with the target clip — then
/// checks the model still ranks the right clip at the top, through the very same
/// `SemanticRanker.neural` / `.smart` functions the app uses.
///
/// The `.mlpackage` models are gitignored, so this SKIPS cleanly in a fresh clone.
/// Run against a restored model with:
///   CLIPHOARD_OGMA_MODEL_DIR="$PWD/tools/models" swift test --filter OgmaRealDataTests
final class OgmaRealDataTests: XCTestCase {

    // MARK: Model resolution (tools/models/open-ogma-small.mlpackage + sibling tokenizer)

    private var modelsDir: URL {
        if let d = ProcessInfo.processInfo.environment["CLIPHOARD_OGMA_MODEL_DIR"], !d.isEmpty {
            return URL(fileURLWithPath: d)
        }
        return URL(fileURLWithPath: #filePath)          // …/Tests/CliphoardTests/OgmaRealDataTests.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools/models")
    }

    private func resolve() -> (mlpackage: URL, tokenizer: URL)? {
        let fm = FileManager.default
        let pkg = modelsDir.appendingPathComponent("open-ogma-small.mlpackage")
        let tok = modelsDir.appendingPathComponent("open-ogma-small")
        guard fm.fileExists(atPath: pkg.path),
              fm.fileExists(atPath: tok.appendingPathComponent("tokenizer.json").path) else { return nil }
        return (pkg, tok)
    }

    private func load(_ url: URL) throws -> MLModel {
        if let m = try? MLModel(contentsOf: url) { return m }
        return try MLModel(contentsOf: MLModel.compileModel(at: url))
    }

    // MARK: Realistic corpus

    private func makeItem(_ text: String, _ kind: ClipKind, _ embedder: OgmaEmbedder) -> ClipItem {
        let it = ClipItem(kind: kind, text: text)
        let vec = embedder.embed(SemanticRanker.searchText(it))
        it.embeddings[embedder.signature] = ModelEmbedding(vector: vec, tags: [])
        return it
    }

    private let corpus: [(String, ClipKind)] = [
        ("git reset --soft HEAD~1", .text),
        ("kubectl rollout restart deployment/web", .text),
        ("docker compose up -d --build", .text),
        ("SELECT * FROM users WHERE created_at > now() - interval '7 days'", .text),
        ("def quicksort(a): return a if len(a) < 2 else quicksort([x for x in a[1:] if x < a[0]]) + [a[0]] + quicksort([x for x in a[1:] if x >= a[0]])", .text),
        ("Grandma's banana bread: 3 ripe bananas, 2 cups flour, bake at 350F for 55 minutes", .text),
        ("225 Baker Street, London NW1 6XE, United Kingdom", .text),
        ("npm install --save-dev typescript", .text),
        ("The mitochondrion is the powerhouse of the cell", .text),
        ("Meet Sarah 3pm Thursday to review the Q3 roadmap", .text),
        ("https://github.com/AntreasAntoniou/cliphoard", .link),
        ("rgba(63, 214, 200, 1.0)", .color),
    ]

    // MARK: The proof

    @MainActor
    func testOgmaSemanticRetrievalOnRealData() throws {
        guard let r = resolve() else {
            throw XCTSkip("open-ogma-small model not present — restore via tools/restore-models.sh")
        }
        let model = try load(r.mlpackage)
        let tokenizer = try XCTUnwrap(OgmaTokenizer(folder: r.tokenizer))
        let embedder = OgmaEmbedder(modelName: "open-ogma-small", model: model,
                                    tokenizer: tokenizer, dimension: 384)

        let items = corpus.map { makeItem($0.0, $0.1, embedder) }
        XCTAssertTrue(items.allSatisfy { ($0.embeddings[embedder.signature]?.vector.count ?? 0) == 384 },
                      "every clip embedded to a 384-dim ogma vector")

        // Each query's wording shares little/no vocabulary with its target clip, so
        // a correct top rank can only come from MEANING, not substring overlap.
        let cases: [(query: String, expect: String)] = [
            ("how do I undo my last commit",        "git reset"),
            ("restart a kubernetes pod",            "kubectl"),
            ("spin up my containers",               "docker compose"),
            ("find people who signed up recently",  "SELECT * FROM users"),
            ("algorithm to order a list of numbers","quicksort"),
            ("a sweet treat baked with fruit",      "banana bread"),
            ("where does someone live",             "Baker Street"),
            ("add the TypeScript compiler",         "typescript"),
            ("which organelle makes energy",        "mitochondrion"),
            ("a calendar reminder to meet a coworker", "Meet Sarah"),
        ]
        // NB: the corpus also holds a raw color (rgba(63,214,200)) and a URL as
        // distractors. We don't query the color semantically on purpose — a text
        // model can't recover "teal" from opaque digits, which is exactly why the
        // app keeps exact/tag modes and a dedicated color kind alongside neural.

        print("\n────────── open-ogma-small · NEURAL semantic retrieval on real data ──────────")
        var top1 = 0, top3 = 0
        for c in cases {
            let ranked = SemanticRanker.neural(query: c.query, items: items, embedder: embedder)
            let rank = ranked.firstIndex { $0.text.localizedCaseInsensitiveContains(c.expect) }.map { $0 + 1 } ?? -1
            if rank == 1 { top1 += 1 }
            if rank >= 1 && rank <= 3 { top3 += 1 }
            let podium = ranked.prefix(3).enumerated()
                .map { "\($0.offset + 1). \($0.element.text.prefix(34))" }.joined(separator: "   ")
            print(String(format: "  rank %2d │ %-38@ → %@", rank, c.query as NSString, podium as NSString))
            // Lenient bar for the automated gate: the target must at least surface
            // in the top 3 by pure meaning. (Observed top-1 accuracy printed below.)
            XCTAssertTrue(rank >= 1 && rank <= 3,
                          "\"\(c.query)\" should retrieve “\(c.expect)” in the top 3 by meaning (got rank \(rank))")
        }
        print(String(format: "  ── top-1: %d/%d   top-3: %d/%d ──\n", top1, cases.count, top3, cases.count))

        // Stable gate: overwhelmingly the model puts the right clip at #1 by pure
        // meaning. Allow at most one slip so a single Float16/model quirk can't
        // make the proof flaky, while still failing loudly if retrieval regresses.
        XCTAssertGreaterThanOrEqual(top1, cases.count - 1,
            "ogma should rank the semantically-correct clip #1 for nearly every query")
    }
}
