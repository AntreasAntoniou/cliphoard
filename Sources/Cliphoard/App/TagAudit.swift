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
    /// What this tool's exit status MEANS.
    ///
    /// `2` used to mean six different things: "cannot open DB", "ARCHIVE FAILED", "ARCHIVE
    /// VERIFICATION FAILED", "no clips found", "embedder failed to load", and — added by a
    /// safety fix — "I refused because the history could not be read in full". A wrapper
    /// could not tell "your data is fine and I declined" from "I crashed", which is the one
    /// distinction that matters after the incident this tool serves.
    ///
    /// An enum rather than a documented convention, so a future collision is a BUILD error
    /// ("raw value for enum case is not unique") instead of something review has to catch.
    enum ExitCode: Int32 {
        case ok = 0
        /// Could not START: no database, no embedder, no clips.
        case environment = 2
        /// REFUSED, data intact — this PROCESS is degraded. Retry awake and unlocked.
        case refusedKeychainUnreachable = 3
        /// REFUSED, data intact — the stored history could not be read in full.
        case refusedIncompleteRead = 4
        /// FAILED part-way, and stopped BEFORE deleting anything.
        case operationFailed = 5
    }

    static func stop(_ code: ExitCode) -> Never { exit(code.rawValue) }

    /// What `--archive-unreadable` should do, as a pure function of the three facts.
    ///
    /// Extracted because the entry point reads the real Application Support directory and
    /// calls `exit`, so its ORDERING could not be asserted — which is how a completeness
    /// guard came to sit above the archive step and silently disable the non-destructive
    /// dry run in exactly the incident this tool exists for.
    ///
    /// The asymmetry is deliberate. A short read still tells the truth about the rows it
    /// DID load, so their ciphertext is worth preserving, labelled partial. An unreachable
    /// keychain makes EVERY row look unreadable, so the archive would be a file full of
    /// perfectly healthy clips — a false positive with no salvage value.
    enum ArchivePlan: Equatable {
        case refuseKeychainUnreachable
        case archive(partial: Bool, thenDelete: Bool)
    }

    static func archivePlan(keychainReachable: Bool, readComplete: Bool,
                            deleteRequested: Bool) -> ArchivePlan {
        guard keychainReachable else { return .refuseKeychainUnreachable }
        return .archive(partial: !readComplete, thenDelete: readComplete && deleteRequested)
    }

    /// Which audit to run, from `CLIPHOARD_AUDIT_MODE`. The default is the
    /// original vocabulary audit — an unset (or unrecognised) variable must never
    /// change what `--analyze-tags` has always done.
    enum Mode: String {
        case vocabulary
        case topics

        static var fromEnvironment: Mode {
            Mode(rawValue: ProcessInfo.processInfo.environment["CLIPHOARD_AUDIT_MODE"] ?? "") ?? .vocabulary
        }
    }

    /// Diagnostic: load through the SAME path the UI uses (ClipStore, including
    /// its migrations) and report whether any clip's text is still sealed. The
    /// plain `Database.loadAll` path can decrypt correctly while the UI shows
    /// `enc1:` if a migration re-seals already-sealed text, so the two must be
    /// compared rather than assumed identical.
    @MainActor
    static func dumpUIText() {
        let sealed = "enc1:"
        let db = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ditto/ditto.sqlite").path
        let direct = Database(path: db)?.loadAll() ?? []
        let directBad = direct.filter { $0.text.hasPrefix(sealed) }.count
        print("Database.loadAll     : \(direct.count) clips, \(directBad) still sealed")

        let store = ClipStore()
        let storeBad = store.items.filter { $0.text.hasPrefix(sealed) }.count
        print("ClipStore (UI path)  : \(store.items.count) clips, \(storeBad) still sealed")
        if storeBad > 0 {
            print("SEALED SAMPLES (first 3):")
            for item in store.items.filter({ $0.text.hasPrefix(sealed) }).prefix(3) {
                print("  [\(item.kind)] \(item.text.prefix(40))…  flags=\(item.flags.rawValue)")
            }
        }
        print(storeBad > directBad ? "VERDICT: a ClipStore MIGRATION is corrupting text (double-seal)."
              : storeBad > 0 ? "VERDICT: sealed at load — decryption failing for these rows."
              : "VERDICT: UI path decrypts cleanly.")
    }

    /// Archive every clip whose content can no longer be decrypted, then delete
    /// those rows.
    ///
    /// ARCHIVE FIRST, DELETE SECOND, and only delete what was verifiably written:
    /// the export keeps each row's metadata *and its raw ciphertext*, so if a key
    /// is ever recovered the content can still be restored. Deleting without that
    /// export would turn "unreadable" into "gone".
    @MainActor
    static func archiveUnreadable(to path: String, delete: Bool) {
        let dbPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ditto/ditto.sqlite").path
        // REFUSE when this process cannot reach the keychain.
        //
        // This is the tool someone reaches for DURING an incident — and an incident is
        // exactly when the keychain is unreadable. In that state every clip looks
        // unreadable, because the key is missing rather than the data, so `--delete`
        // would archive and destroy the ENTIRE history on the strength of a diagnosis
        // that is about the process, not the data. It consulted nothing: no canary, no
        // health signal, no safe mode.
        Crypto.verifyCanary()
        // `ensureKeyResolved()`, not the raw flag. The flag is set as a side effect of key
        // resolution, so reading it directly can see a stale false — and this is the one
        // tool that DELETES rows. It happened to be safe only because the other two
        // disjuncts caught the case; correct by over-determination is not correct.
        if Crypto.ensureKeyResolved() || !Crypto.decryptionHealthy || Crypto.keychainAccessDenied {
            err("REFUSING: this process cannot reach the keychain, so EVERY clip looks "
                + "unreadable — that is a property of this process, not of your data. "
                + "Running with --delete here would destroy your whole history. Try again "
                + "on an awake, unlocked Mac; if clips are still unreadable then, the "
                + "diagnosis is real.")
            stop(.refusedKeychainUnreachable)
        }

        guard let db = Database(path: dbPath) else { err("cannot open DB"); stop(.environment) }
        // READ FIRST, DECIDE SECOND — the two halves of this tool must diverge here.
        //
        // Preserving ciphertext is the SAFE half, and it is the half a degraded database
        // needs MOST. The previous shape refused everything on a short read, which meant
        // `--archive-unreadable` with no `--delete` wrote nothing in exactly the incident
        // it exists for: the "I could not read it" / "there is nothing there" substitution
        // wearing a safety hat. A short read still tells the truth about the rows it DID
        // load, so their ciphertext is worth keeping — labelled partial.
        let status = db.loadAllStatus()
        let proof: Database.CompleteHistory?
        let items: [ClipItem]
        if case .complete(let rows, let token) = status { items = rows; proof = token }
        else { items = db.loadAll(); proof = nil }
        let unreadable = items.filter { Crypto.isSealed($0.text) }
        if proof == nil {
            err("WARNING: the stored history could not be read in full (\(status)). The "
                + "archive below is PARTIAL — it contains only the rows this process could "
                + "load — and --delete will be refused.")
        }
        print("clips: \(items.count) · unreadable: \(unreadable.count)"
              + (proof == nil ? " · PARTIAL READ" : ""))
        guard !unreadable.isEmpty else { print("nothing to archive"); return }

        let iso = ISO8601DateFormatter()
        let rows: [[String: Any]] = unreadable.map { item in
            [
                "id": item.id.uuidString,
                "kind": item.kind.rawValue,
                "sourceApp": item.sourceApp ?? "",
                "createdAt": iso.string(from: item.createdAt),
                "lastUsedAt": iso.string(from: item.lastUsedAt),
                "useCount": item.useCount,
                "pinned": item.pinned,
                "characters": item.text.count,
                // The still-sealed bytes, retained verbatim so a future key recovery can
                // decrypt them.
                "ciphertext": item.text,
                // EVERYTHING ELSE THAT MAKES A CLIP RECOVERABLE. The archive used to keep
                // only the text ciphertext and claimed "this is why deletion is safe" —
                // it was not. Dropping `payloadFile` was the worst of it: with no
                // clip→file mapping, the next healthy launch sees the PNGs unreferenced
                // and `sweepOrphanPayloads` deletes the image bytes, so even a SUCCESSFUL
                // key recovery restores nothing for an image clip. The row survived and
                // the picture did not.
                "payloadFile": item.payloadFile ?? "",
                "imageHash": item.imageHash ?? "",
                "rtfBase64": item.rtf?.base64EncodedString() ?? "",
                "filePath": item.filePath ?? "",
                "colorHex": item.colorHex ?? "",
                "ocrText": item.ocrText ?? "",
                "userTags": item.userTags,
                "flags": item.flags.rawValue,
                "shape": item.shape ?? "",
            ]
        }
        let payload: [String: Any] = [
            "exportedAt": iso.string(from: Date()),
            "reason": "content sealed with a key that no longer exists (see CHRONICLE 2026-08-06)",
            "count": rows.count,
            "clips": rows,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.prettyPrinted, .sortedKeys]),
              (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil else {
            err("ARCHIVE FAILED — refusing to delete anything"); stop(.operationFailed)
        }
        // Verify the archive is readable and complete BEFORE deleting.
        guard let check = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let parsed = try? JSONSerialization.jsonObject(with: check) as? [String: Any],
              (parsed["clips"] as? [[String: Any]])?.count == rows.count else {
            err("ARCHIVE VERIFICATION FAILED — refusing to delete anything"); stop(.operationFailed)
        }
        print("archived \(rows.count) clips → \(path) (\(check.count) bytes, verified)")

        guard delete else { print("dry run: no rows deleted (pass --delete to remove them)"); return }
        // The token, consumed at the ONLY line in this file that destroys anything.
        guard let proof else {
            err("REFUSING TO DELETE: the stored history could not be read in full. The "
                + "archive above is PARTIAL and has been kept. A partial read cannot tell "
                + "'unreadable' from 'not loaded', so deleting on it would destroy rows "
                + "this process never saw — and the archive would not contain them either.")
            stop(.refusedIncompleteRead)
        }
        deleteArchivedRows(db, ids: unreadable.map { $0.id }, loadedCount: items.count,
                           provenBy: proof)
    }

    /// The delete half, separated so it CANNOT be called without proof the read was whole.
    ///
    /// `provenBy` is a witness: it is never read, it is required. `CompleteHistory.init` is
    /// fileprivate to Database.swift, so the only way to obtain one is a `loadAllStatus`
    /// that returned `.complete` — which makes reverting this call site to `db.loadAll()` a
    /// COMPILE ERROR rather than a silent regression. Reverting it silently is exactly what
    /// a mutation test showed the suite could not detect.
    ///
    /// The victim ids are cross-checked against the token's own answer rather than trusted:
    /// two populations computed separately have already drifted apart once in this file.
    @MainActor
    private static func deleteArchivedRows(_ db: Database, ids: [UUID], loadedCount: Int,
                                           provenBy proof: Database.CompleteHistory) {
        guard Set(ids).isSubset(of: proof.unreadableClipIDs) else {
            err("REFUSING TO DELETE: the rows selected for deletion are not a subset of the "
                + "rows the completed read found unreadable. Two populations disagree; "
                + "nothing has been deleted.")
            stop(.operationFailed)
        }
        db.delete(ids: ids)
        let after = db.loadAll()
        print("deleted \(loadedCount - after.count) rows · remaining: \(after.count) "
              + "· still unreadable: \(after.filter { Crypto.isSealed($0.text) }.count)")
    }

    @MainActor
    static func cryptoDiagnostics() {
        let db = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ditto/ditto.sqlite").path
        let items = Database(path: db)?.loadAll() ?? []
        let sealed = items.filter { $0.text.hasPrefix("enc1:") }
        print("CRYPTO DIAGNOSTICS")
        print("  usesSecureEnclave : \(Crypto.usesSecureEnclave)")
        print("  legacyKeyAvailable: \(Crypto.legacyKeyAvailable)")
        print("  clips             : \(items.count)")
        print("  still sealed      : \(sealed.count)")
        if let first = sealed.first {
            print("  sample            : \(first.text.prefix(30))…")
            print("  unseal probe      : \(Crypto.unsealProbe(first.text))")
        }
    }

    @MainActor
    static func run(outputPath: String) {
        switch Mode.fromEnvironment {
        case .vocabulary: runVocabularyAudit(outputPath: outputPath)
        case .topics: runTopicsAudit(outputPath: outputPath)
        }
    }

    // MARK: - Default mode: the basket vocabulary audit

    @MainActor
    private static func runVocabularyAudit(outputPath: String) {
        let embedder = loadEmbedder()
        let sig = embedder.signature
        let clips = loadStoredClips()

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
        var sensitiveExcluded = 0

        for clip in clips {
            // NEVER embed inside the audit: the old `?? embed(...)` fallback fired
            // precisely on vetoed clips (they have no stored vector by design),
            // pushing secrets through CoreML on every run.
            guard !clip.isIndexVetoed else { sensitiveExcluded += 1; continue }
            guard let vec = clip.embeddings[sig]?.vector else { missing += 1; continue }
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
            // NO CLIP CONTENT IN THE REPORT. This file is written unencrypted to
            // disk by a product whose entire storage layer is sealed; a 48-char
            // plaintext preview of every clip undid that. A non-content descriptor
            // is enough to identify a row while auditing.
            let preview = "[\(clip.kind)] chars=\(clip.text.count) id=\(clip.id.uuidString.prefix(8))"
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

    // MARK: - Shared setup

    /// Bring up the audit embedder exactly as the vocabulary audit always has.
    /// General basket; model chosen by CLIPHOARD_AUDIT_LEVEL (default = normal =
    /// open-ogma-small). ogma tiers load synchronously; HF tiers (MiniLM/Gemma)
    /// load async on the main run loop, so spin it until the embedder swaps in.
    @MainActor
    private static func loadEmbedder() -> TextEmbedder {
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
        guard embedder.signature != "hashing-256" else {
            err("embedder \(wantModel) failed to load (still hashing)"); stop(.environment)
        }
        return embedder
    }

    /// The real corpus: every stored clip, read-only. Both audits are gates on
    /// the user's ACTUAL clipboard — never a synthetic sample — so an empty or
    /// unreadable store is a hard failure, not an empty report.
    @MainActor
    private static func loadStoredClips() -> [ClipItem] {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dbPath = appSupport.appendingPathComponent("Ditto/ditto.sqlite").path
        guard let db = Database(path: dbPath) else { err("cannot open DB at \(dbPath)"); stop(.environment) }
        let clips = db.loadAll()
        guard !clips.isEmpty else { err("no clips found"); stop(.environment) }
        return clips
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

// MARK: - Coarse Topic (§3.11) validation harness

/// One candidate Coarse-Topic bucket as the harness needs to see it: a name and
/// its unit-length centroid **in the active embedder's space**.
///
/// The harness deliberately takes centroids rather than the example phrases that
/// produced them. Recomputing them here would validate the harness's own idea of
/// a bucket instead of the one the app would ship, and the gate is only
/// meaningful if it scores the exact vectors the runtime classifier would use.
struct TopicBucketProbe: Sendable {
    let name: String
    let centroid: [Float]

    init(name: String, centroid: [Float]) {
        self.name = name
        self.centroid = centroid
    }
}

/// The seam between this harness and the Coarse-Topic implementation (§3.11).
///
/// Coarse Topic is *probationary*: §7 says it "stays behind the harness gate and
/// ships only for buckets that clear floor+margin on the real corpus", and it
/// lands separately from this harness. So the harness must build and run whether
/// or not the bucket library exists yet — it reaches the library through this
/// registration point instead of a hard reference to a symbol that may not be
/// compiled in. When the classifier ships, it installs `provider` (one line at
/// launch / in the audit entry point) and the gate starts scoring for real; until
/// then `--analyze-tags` in topics mode says so and exits 0.
@MainActor
enum TopicBucketSource {
    /// Installed by the Coarse-Topic classifier when it exists. Returns the
    /// candidate buckets already projected into `embedder`'s space.
    static var provider: ((TextEmbedder) -> [TopicBucketProbe])?

    /// The candidate buckets, or nil when Coarse Topic is not in this build.
    /// An empty library counts as absent — there is nothing to validate.
    static func buckets(for embedder: TextEmbedder) -> [TopicBucketProbe]? {
        guard let provider else { return nil }
        let buckets = provider(embedder)
        return buckets.isEmpty ? nil : buckets
    }
}

extension TagAudit {
    /// Whether there is anything to validate at all.
    enum TopicsGate {
        case available([TopicBucketProbe])
        /// Coarse Topic is not in this build; the message explains it in full.
        case unavailable(String)
    }

    /// Thresholds the gate is run at. Every one is overridable from the
    /// environment so the gate can be re-run at a different bar without a
    /// rebuild — but the DEFAULTS are the spec's, so an un-parameterised run is
    /// the one that decides whether Coarse Topic ships.
    struct TopicsGateConfig: Sendable {
        /// Minimum top-1 cosine for a clip to count as assigned to a bucket
        /// (§3.11 `absoluteFloor`).
        var floor: Float
        /// δ: minimum (top1 − top2) a bucket's assignments must average.
        var marginThreshold: Float
        /// A bucket assigned fewer clips than this has not been measured, and an
        /// unmeasured bucket FAILS — the gate can only clear on evidence.
        var minSamples: Int

        init(floor: Float, marginThreshold: Float = 0.06, minSamples: Int = 4) {
            self.floor = floor
            self.marginThreshold = marginThreshold
            self.minSamples = minSamples
        }

        @MainActor
        static func fromEnvironment() -> TopicsGateConfig {
            let env = ProcessInfo.processInfo.environment
            func float(_ key: String, _ fallback: Float) -> Float {
                guard let raw = env[key], let value = Float(raw) else { return fallback }
                return value
            }
            func int(_ key: String, _ fallback: Int) -> Int {
                guard let raw = env[key], let value = Int(raw), value > 0 else { return fallback }
                return value
            }
            return TopicsGateConfig(
                floor: float("CLIPHOARD_TOPIC_FLOOR", TagSpace.assignmentThreshold),
                marginThreshold: float("CLIPHOARD_TOPIC_MARGIN", 0.06),
                minSamples: int("CLIPHOARD_TOPIC_MIN_SAMPLES", 4))
        }
    }

    /// What the corpus said about one candidate bucket.
    struct TopicBucketVerdict: Sendable {
        let name: String
        /// Clips whose nearest bucket was this one, at or above the floor.
        let assigned: Int
        let meanTop1: Float
        /// The number the whole gate turns on: mean (top1 − top2) over this
        /// bucket's assignments. A bucket that coin-flips against its neighbour
        /// sits near zero here however high its absolute cosine looks.
        let meanMargin: Float
        /// Assignments that would ALSO clear the per-clip margin rule — i.e. what
        /// the shipped classifier would actually label rather than blank.
        let acceptedPerClip: Int
        let passed: Bool
        /// Why it passed or failed, in one clause, for the recommendation line.
        let reason: String
    }

    /// The full gate result. `render` turns it into the report body; the caller
    /// prints the table and writes the whole thing to the output file.
    struct TopicsReport: Sendable {
        let config: TopicsGateConfig
        let verdicts: [TopicBucketVerdict]
        /// Clips that carried a usable vector and were scored.
        let scored: Int
        /// Clips skipped because they had no usable vector for this embedder.
        let unusable: Int
        /// Clips skipped because they are `.secret`/`.quarantined` — §3.11:
        /// "sensitive-flagged clips are excluded from the embedding index
        /// entirely", so they are not part of the population being validated
        /// either.
        let sensitiveExcluded: Int
        /// Scored clips whose top-1 never reached the floor: no bucket at all.
        let unassigned: Int

        var passing: [TopicBucketVerdict] { verdicts.filter { $0.passed } }
        var failing: [TopicBucketVerdict] { verdicts.filter { !$0.passed } }

        /// The one line a human needs: what ships and what gets cut.
        var recommendation: String {
            guard !verdicts.isEmpty else { return "RECOMMENDATION: no buckets scored — do not ship Coarse Topic." }
            let ship = passing.map(\.name).sorted()
            let drop = failing.map(\.name).sorted()
            if ship.isEmpty {
                return "RECOMMENDATION: SHIP NOTHING — no bucket clears margin ≥ \(TagAudit.f2(config.marginThreshold)); drop Coarse Topic entirely (drop: \(drop.joined(separator: ", ")))."
            }
            if drop.isEmpty {
                return "RECOMMENDATION: ship all \(ship.count) buckets (\(ship.joined(separator: ", "))) — every one clears margin ≥ \(TagAudit.f2(config.marginThreshold))."
            }
            return "RECOMMENDATION: ship \(ship.joined(separator: ", ")) · DROP BEFORE SHIP \(drop.joined(separator: ", ")) (margin < \(TagAudit.f2(config.marginThreshold)) or too few assignments to judge)."
        }
    }

    /// Score a corpus of clip vectors against the candidate buckets.
    ///
    /// Pure and side-effect free (no store, no embedder, no I/O) so the gate's
    /// arithmetic is unit-testable without a real clipboard.
    ///
    /// **Assignment is by argmax over the floor only — never by margin.** Mean
    /// margin measured over the clips that already passed a margin test would be
    /// circular, and would report every bucket as clearing whatever bar it was
    /// filtered at. `acceptedPerClip` reports the margin-passing subset
    /// separately, as information, not as the denominator.
    static func scoreTopics(vectors: [[Float]],
                            buckets: [TopicBucketProbe],
                            config: TopicsGateConfig,
                            unusable: Int = 0,
                            sensitiveExcluded: Int = 0) -> TopicsReport {
        var top1s = [[Float]](repeating: [], count: buckets.count)
        var margins = [[Float]](repeating: [], count: buckets.count)
        var accepted = [Int](repeating: 0, count: buckets.count)
        var unassigned = 0

        for vector in vectors {
            var scored: [(index: Int, cosine: Float)] = []
            scored.reserveCapacity(buckets.count)
            for (index, bucket) in buckets.enumerated() {
                scored.append((index, SemanticRanker.cosine(vector, bucket.centroid)))
            }
            scored.sort { $0.cosine > $1.cosine }
            guard let best = scored.first, best.cosine >= config.floor else { unassigned += 1; continue }
            // With a single candidate bucket there is no runner-up to beat, so
            // the margin is the full top-1 — an honest reading: nothing competes.
            let runnerUp = scored.count > 1 ? scored[1].cosine : 0
            let margin = best.cosine - runnerUp
            top1s[best.index].append(best.cosine)
            margins[best.index].append(margin)
            if margin >= config.marginThreshold { accepted[best.index] += 1 }
        }

        let verdicts = buckets.enumerated().map { index, bucket -> TopicBucketVerdict in
            let n = top1s[index].count
            let meanMargin = mean(margins[index])
            let passed = n >= config.minSamples && meanMargin >= config.marginThreshold
            let reason: String
            if n == 0 {
                reason = "no clip in the corpus lands here — unvalidated"
            } else if n < config.minSamples {
                reason = "only \(n) assignment(s) (< \(config.minSamples)) — not enough evidence to judge"
            } else if !passed {
                reason = "mean margin \(f2(meanMargin)) < δ \(f2(config.marginThreshold)) — coin-flips against its neighbour"
            } else {
                reason = "mean margin \(f2(meanMargin)) ≥ δ \(f2(config.marginThreshold)) over \(n) clips"
            }
            return TopicBucketVerdict(name: bucket.name, assigned: n,
                                      meanTop1: mean(top1s[index]), meanMargin: meanMargin,
                                      acceptedPerClip: accepted[index], passed: passed, reason: reason)
        }

        return TopicsReport(config: config, verdicts: verdicts, scored: vectors.count,
                            unusable: unusable, sensitiveExcluded: sensitiveExcluded,
                            unassigned: unassigned)
    }

    /// The per-bucket table, shared by stdout and the on-disk report so the two
    /// can never disagree about what the gate said.
    static func topicsTable(_ report: TopicsReport) -> String {
        var out = "bucket           |     n | mean top1 | mean margin | per-clip accept | verdict\n"
        out += "-----------------|-------|-----------|-------------|-----------------|--------\n"
        for v in report.verdicts {
            let name = v.name.padding(toLength: 16, withPad: " ", startingAt: 0)
            let n = String(v.assigned).leftPadded(to: 5)
            let acc = "\(v.acceptedPerClip)/\(v.assigned)".leftPadded(to: 15)
            out += "\(name) | \(n) |      \(f2(v.meanTop1)) |        \(f2(v.meanMargin)) | \(acc) | \(v.passed ? "PASS" : "FAIL")\n"
        }
        return out
    }

    /// `CLIPHOARD_AUDIT_MODE=topics`: the §3.11 gate. Scores every stored clip
    /// against the candidate topic buckets on the REAL corpus and reports, per
    /// bucket, whether it separates anything — the decision on whether Coarse
    /// Topic ships at all.
    @MainActor
    static func topicsGate(embedder: TextEmbedder) -> TopicsGate {
        guard let buckets = TopicBucketSource.buckets(for: embedder) else {
            return .unavailable(topicsUnavailableMessage)
        }
        return .available(buckets)
    }

    /// What the harness says when there is nothing to validate. Deliberately
    /// spells out the exit code: a CI step that runs the gate before the Coarse
    /// Topic wave lands must read "not built yet", never "gate failed".
    static let topicsUnavailableMessage = """
        TOPICS AUDIT: no candidate topic buckets in this build.
        Coarse Topic (design §3.11) is probationary and ships separately; nothing to validate yet.
        Install `TopicBucketSource.provider` from the bucket library and re-run:
          CLIPHOARD_AUDIT_MODE=topics Cliphoard --analyze-tags <outfile>
        Exiting 0 — an absent gate is not a failed gate.
        """

    @MainActor
    static func runTopicsAudit(outputPath: String) {
        // Checked BEFORE anything expensive: with no bucket library there is
        // nothing to validate, so the harness must not spend two minutes loading
        // a CoreML model (or fail on a machine that has no model at all) only to
        // then say so. Degrade first, work second.
        guard TopicBucketSource.provider != nil else {
            print(topicsUnavailableMessage)
            stop(.ok)
        }
        let embedder = loadEmbedder()
        let buckets: [TopicBucketProbe]
        switch topicsGate(embedder: embedder) {
        case .unavailable(let message):
            print(message)
            stop(.ok)
        case .available(let found):
            buckets = found
        }

        let config = TopicsGateConfig.fromEnvironment()
        let clips = loadStoredClips()
        let sig = embedder.signature
        var vectors = [[Float]]()
        var unusable = 0
        var sensitive = 0
        // Previews are for the on-disk report only (the user owns that file), and
        // never for a clip we refused to embed.
        var rows = [(bucket: String, top1: Float, margin: Float, preview: String)]()

        for clip in clips {
            // Fail closed: a flagged clip is out of the embedding index (§3.11),
            // so the audit must not embed it either — not even to score it.
            guard !clip.isIndexVetoed else { sensitive += 1; continue }
            // NEVER embed inside the audit. A vetoed clip has no stored vector BY
            // DESIGN, so the old `?? embed(...)` fallback fired precisely on
            // secrets — pushing them through CoreML on every audit run, which is
            // the exact invariant the veto exists to hold.
            // NEVER embed here either — same reasoning as the vocabulary audit.
            guard let vec = clip.embeddings[sig]?.vector else { unusable += 1; continue }
            guard vec.count == embedder.dimension else { unusable += 1; continue }
            vectors.append(vec)

            var scored = buckets.enumerated().map { ($0.element.name, SemanticRanker.cosine(vec, $0.element.centroid)) }
            scored.sort { $0.1 > $1.1 }
            // NO CLIP CONTENT IN THE REPORT. This file is written unencrypted to
            // disk by a product whose entire storage layer is sealed; a 48-char
            // plaintext preview of every clip undid that. A non-content descriptor
            // is enough to identify a row while auditing.
            let preview = "[\(clip.kind)] chars=\(clip.text.count) id=\(clip.id.uuidString.prefix(8))"
                .replacingOccurrences(of: "\n", with: "⏎")
            if let best = scored.first, best.1 >= config.floor {
                rows.append((best.0, best.1, best.1 - (scored.count > 1 ? scored[1].1 : 0), preview))
            } else {
                rows.append(("—", scored.first?.1 ?? 0, 0, preview))
            }
        }

        let report = scoreTopics(vectors: vectors, buckets: buckets, config: config,
                                 unusable: unusable, sensitiveExcluded: sensitive)
        let table = topicsTable(report)

        var out = "# Cliphoard Coarse Topic gate (§3.11) — \(sig)\n\n"
        out += "Clips scored: \(report.scored) (skipped \(report.unusable) without a usable vector, "
        out += "\(report.sensitiveExcluded) sensitive-flagged and excluded from the index)\n"
        out += "Floor: \(f2(config.floor)) · margin δ: \(f2(config.marginThreshold)) · min samples: \(config.minSamples)\n"
        out += "Unassigned (top-1 below floor → blank, which is a valid result): \(pct(report.unassigned, max(report.scored, 1)))\n\n"
        out += "## Per bucket\n\n" + table + "\n"
        out += "## Why\n"
        for v in report.verdicts { out += "• \(v.name): \(v.passed ? "PASS" : "FAIL") — \(v.reason)\n" }
        out += "\n" + report.recommendation + "\n"
        out += "\n## Every clip (assigned bucket, top-1, margin)\n"
        for r in rows { out += "  \(r.bucket) top1=\(f2(r.top1)) margin=\(f2(r.margin)) | \"\(r.preview)\"\n" }
        try? out.write(toFile: outputPath, atomically: true, encoding: .utf8)

        print("=== COARSE TOPIC GATE (\(sig)) — \(report.scored) clips ===")
        print("floor=\(f2(config.floor)) · δ=\(f2(config.marginThreshold)) · min n=\(config.minSamples) · unassigned \(pct(report.unassigned, max(report.scored, 1)))")
        print(table, terminator: "")
        print(report.recommendation)
        print("Full report → \(outputPath)")
    }
}

private extension String {
    /// Right-align a short numeric cell in the fixed-width gate table.
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
