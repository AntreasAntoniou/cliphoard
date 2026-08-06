import Foundation

/// Headless tag-quality audit (invoked with `--analyze-tags <outfile>`): scores
/// every stored clip against the active basket's tag vocabulary under the
/// open-ogma-small embedder and reports whether the automatic tags actually
/// separate the user's real clipboard or are just least-bad argmax noise.
///
/// Read-only: it never mutates the store. It writes a full per-clip report to
/// `outfile` and prints an aggregate summary to stdout (no full clip contents —
/// only short previews, and only in the on-disk report the user owns).
enum TagAudit {
    @MainActor
    static func run(outputPath: String) {
        // General basket; model chosen by CLIPHOARD_AUDIT_LEVEL (default = normal =
        // open-ogma-small). ogma tiers load synchronously; HF tiers (MiniLM/Gemma)
        // load async on the main run loop, so spin it until the embedder swaps in.
        TagBaskets.overlayID = nil
        DeepSearch.detail = .full1024
        let level = DeepSearchLevel(rawValue: ProcessInfo.processInfo.environment["CLIPHOARD_AUDIT_LEVEL"] ?? "normal") ?? .normal
        EmbedderProvider.configure(level: level)
        let wantModel = level.modelName ?? ""
        let deadline = Date().addingTimeInterval(120)
        while EmbedderProvider.active.signature == "hashing-256", !wantModel.isEmpty, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
        }
        let embedder = EmbedderProvider.active
        let sig = embedder.signature
        guard sig != "hashing-256" else { err("embedder \(wantModel) failed to load (still hashing)"); exit(2) }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dbPath = appSupport.appendingPathComponent("Ditto/ditto.sqlite").path
        guard let db = Database(path: dbPath) else { err("cannot open DB at \(dbPath)"); exit(2) }
        let clips = db.loadAll()
        guard !clips.isEmpty else { err("no clips found"); exit(2) }

        let names = TagSpace.names
        let tagVecs = TagSpace.vectors(using: embedder)
        let dimNames = TagBaskets.active.dimensions.map { $0.name }
        let dimCount = dimNames.count
        let topicalR = TagSpace.topicalRange
        let floor: Float = TagSpace.assignmentThreshold

        var axisBest = Array(repeating: [Float](), count: dimCount)   // argmax cosine per axis
        var axisMargin = Array(repeating: [Float](), count: dimCount) // top1 − top2 per axis
        var axisAssigned = Array(repeating: [String: Int](), count: dimCount)
        var topicalTop1 = [Float]()
        var overallBest = [Float]()
        var rows = [(best: Float, line: String)]()
        var missing = 0

        for clip in clips {
            let vec = clip.embeddings[sig]?.vector ?? embedder.embed(SemanticRanker.searchText(clip))
            guard vec.count == embedder.dimension else { missing += 1; continue }
            var best: Float = -2
            var parts = [String]()
            for d in 0..<dimCount {
                let r = TagSpace.range(ofDimension: d)
                var scored = r.map { (names[$0], SemanticRanker.cosine(vec, tagVecs[$0])) }
                scored.sort { $0.1 > $1.1 }
                let top = scored[0]
                let margin = top.1 - (scored.count > 1 ? scored[1].1 : 0)
                axisBest[d].append(top.1); axisMargin[d].append(margin)
                axisAssigned[d][top.0, default: 0] += 1
                best = max(best, top.1)
                parts.append("\(dimNames[d])=\(top.0)(\(f2(top.1)))")
            }
            if !topicalR.isEmpty {
                var ts = topicalR.map { (names[$0], SemanticRanker.cosine(vec, tagVecs[$0])) }
                ts.sort { $0.1 > $1.1 }
                if let t = ts.first {
                    topicalTop1.append(t.1); best = max(best, t.1)
                    parts.append("topical=\(t.0)(\(f2(t.1)))")
                }
            }
            overallBest.append(best)
            let preview = String(SemanticRanker.searchText(clip).prefix(48))
                .replacingOccurrences(of: "\n", with: "⏎")
            rows.append((best, "[\(clip.kind)] best=\(f2(best)) | \(parts.joined(separator: " ")) | \"\(preview)\""))
        }

        // ---------- aggregate ----------
        var out = "# Cliphoard tag audit — \(sig), General basket\n\n"
        out += "Clips scored: \(overallBest.count) (skipped \(missing) without a usable vector)\n"
        out += "Confidence floor τ (assignmentThreshold): \(f2(floor))\n\n"

        out += "## Overall: how well does ANY tag match a clip?\n"
        out += statLine("best-tag cosine", overallBest)
        out += "  below τ: \(pct(overallBest.filter { $0 < floor }.count, overallBest.count)) · below 0.35: \(pct(overallBest.filter { $0 < 0.35 }.count, overallBest.count))\n\n"

        out += "## Per axis (is the axis informative, or noise?)\n"
        for d in 0..<dimCount {
            let fired = pct(axisBest[d].filter { $0 >= floor }.count, axisBest[d].count)
            let top = axisAssigned[d].sorted { $0.value > $1.value }.first
            let dom = top.map { "\($0.key) \(pct($0.value, axisBest[d].count))" } ?? "—"
            out += "• \(dimNames[d]): median cos \(f2(median(axisBest[d]))), mean margin \(f2(mean(axisMargin[d]))), fires ≥τ \(fired), distinct values \(axisAssigned[d].count)/8, dominant → \(dom)\n"
        }
        out += "\n## Topical tail\n"
        out += statLine("top-1 topical cosine", topicalTop1)
        out += "  fires ≥ τ: \(pct(topicalTop1.filter { $0 >= floor }.count, max(topicalTop1.count,1)))\n\n"

        let sorted = rows.sorted { $0.best < $1.best }
        out += "## Worst 15 matches (clips the taxonomy has no real opinion on)\n"
        for r in sorted.prefix(15) { out += "  \(r.line)\n" }
        out += "\n## Best 15 matches\n"
        for r in sorted.suffix(15).reversed() { out += "  \(r.line)\n" }
        out += "\n## Every clip\n"
        for r in rows { out += "  \(r.line)\n" }

        try? out.write(toFile: outputPath, atomically: true, encoding: .utf8)

        // ---------- stdout: aggregates + a few examples (no full dump) ----------
        print("=== TAG AUDIT (\(sig) · General) — \(overallBest.count) clips ===")
        print("τ=\(f2(floor))")
        print("OVERALL best-tag cosine: " + statInline(overallBest) + " | below τ: \(pct(overallBest.filter { $0 < floor }.count, overallBest.count)) | below 0.35: \(pct(overallBest.filter { $0 < 0.35 }.count, overallBest.count))")
        for d in 0..<dimCount {
            let fired = pct(axisBest[d].filter { $0 >= floor }.count, axisBest[d].count)
            let top = axisAssigned[d].sorted { $0.value > $1.value }.first
            let dom = top.map { "\($0.key)=\(pct($0.value, axisBest[d].count))" } ?? "—"
            print("AXIS \(dimNames[d]): med \(f2(median(axisBest[d]))) | margin \(f2(mean(axisMargin[d]))) | ≥τ \(fired) | distinct \(axisAssigned[d].count)/8 | dominant \(dom)")
        }
        print("TOPICAL top-1: " + statInline(topicalTop1) + " | ≥τ \(pct(topicalTop1.filter { $0 >= floor }.count, max(topicalTop1.count,1)))")
        print("--- 6 worst matches ---")
        for r in sorted.prefix(6) { print("  " + r.line) }
        print("--- 6 best matches ---")
        for r in sorted.suffix(6).reversed() { print("  " + r.line) }
        print("Full report → \(outputPath)")
    }

    // ---- helpers ----
    private static func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
    private static func f2(_ x: Float) -> String { String(format: "%.2f", x) }
    private static func mean(_ a: [Float]) -> Float { a.isEmpty ? 0 : a.reduce(0, +) / Float(a.count) }
    private static func median(_ a: [Float]) -> Float { percentile(a, 0.5) }
    private static func percentile(_ a: [Float], _ p: Double) -> Float {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted(); return s[min(s.count - 1, max(0, Int(p * Double(s.count - 1) + 0.5)))]
    }
    private static func pct(_ n: Int, _ d: Int) -> String { d == 0 ? "0%" : "\(Int((100.0 * Double(n) / Double(d)).rounded()))%" }
    private static func statLine(_ label: String, _ a: [Float]) -> String {
        "  \(label): median \(f2(median(a))) · mean \(f2(mean(a))) · p10 \(f2(percentile(a, 0.10))) · p90 \(f2(percentile(a, 0.90)))\n"
    }
    private static func statInline(_ a: [Float]) -> String {
        "median \(f2(median(a))) · p10 \(f2(percentile(a, 0.10))) · p90 \(f2(percentile(a, 0.90)))"
    }
}
