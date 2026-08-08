import AppKit
import Combine

/// Owns the clipboard history. Durable storage is a SQLite database with
/// incremental row writes (no whole-file rewrites); `items` is the in-memory
/// projection that drives the reactive UI and in-memory search.
@MainActor
final class ClipStore: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    /// The id of the clip most recently added or bumped — lets the bar scroll to
    /// reveal it wherever it lands in the (pinned-first) order.
    @Published private(set) var lastAddedID: UUID?

    /// Inverted index tag-id → entries, for O(1) "tag search" retrieval without
    /// any query-time embedding or per-item dot products.
    private(set) var tagIndex: [Int: [ClipItem]] = [:]
    /// Normalized user-tag → entries. Kept separate from model tag ids because
    /// these labels survive basket and model changes.
    private(set) var userTagIndex: [String: [ClipItem]] = [:]

    /// True when the app could not read its own existing data at launch.
    ///
    /// In safe mode NO migration, re-seal, re-index or bulk rewrite runs — the
    /// history is frozen exactly as found. Adding new clips stays allowed (it is
    /// purely additive and cannot harm existing rows), so the app remains usable
    /// while the user decides what to do. The UI surfaces this; failing silently
    /// is what let a key-loss event compound into permanent damage.
    @Published private(set) var safeMode = false

    /// How many stored clips could not be decrypted at launch. Shown to the user
    /// alongside `safeMode` so the message is specific rather than alarming.
    @Published private(set) var unreadableClipCount = 0

    /// Live progress of a background (re)indexing pass, or nil when idle.
    @Published private(set) var indexing: IndexingProgress?

    struct IndexingProgress {
        var done: Int
        var total: Int
        /// Estimated seconds remaining (from the observed per-item rate).
        var etaSeconds: Double?
        var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    }

    /// Maximum number of unpinned items kept (0 = unlimited). Pinned items are
    /// always kept regardless.
    var historyLimit: Int {
        get { UserDefaults.standard.object(forKey: "historyLimit") as? Int ?? 200 }
        set { UserDefaults.standard.set(newValue, forKey: "historyLimit"); trim() }
    }

    private let dir: URL
    private let db: Database?

    /// The in-flight background indexing pass, if any. A new pass cancels the
    /// previous one so overlapping model/basket changes don't run two passes
    /// that fight over the published `indexing` state.
    private var indexingTask: Task<Void, Never>?

    /// - Parameter directory: storage location. Defaults to
    ///   `~/Library/Application Support/Ditto`; tests inject a temp directory.
    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ditto", isDirectory: true)
        dir = base
        // Owner-only (0700): on a shared/multi-user Mac the store holds plaintext
        // image clips and the SQLite DB, which must not be group/other-readable.
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // Defensively tighten an already-existing dir (created before this change
        // or with a looser umask). Best-effort.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let dbPath = dir.appendingPathComponent("ditto.sqlite").path
        db = Database(path: dbPath)
        // Owner-only (0600) for the DB file itself, best-effort.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: dbPath)
        // CANARY FIRST, before anything can rewrite a row. If this process cannot
        // decrypt what a previous run wrote, every migration below is capable of
        // re-sealing unreadable bytes and making the damage permanent — which is
        // exactly how 202 clips were lost. Safe mode freezes history instead.
        Crypto.verifyCanary()
        migrateLegacyJSONIfNeeded()
        items = db?.loadAll() ?? []
        repairKinds()
        // Second, independent check: even with a healthy canary, if a large share
        // of existing rows will not open, something is wrong that the canary did
        // not model. Refuse to run migrations rather than guess.
        let unreadable = items.filter { Crypto.isSealed($0.text) }.count
        unreadableClipCount = unreadable
        // The canary answers "can this process read what a previous run wrote?" — but it
        // is evidence ABOUT THIS STORE only when this store actually has something it
        // cannot read. If every row opens, the key plainly works here, whatever happened
        // to the canary item itself; freezing then would refuse to run over a keychain
        // hiccup that demonstrably did not affect the data.
        //
        // So the canary gates when it is unhealthy AND at least one row confirms it, and
        // the ratio gate stays independent for the converse case the canary cannot model:
        // the canary opens but the rows do not.
        let canaryContradictedByData = !Crypto.decryptionHealthy && unreadable > 0
        safeMode = canaryContradictedByData
            || (items.count >= 10 && unreadable * 2 > items.count)
        if safeMode {
            let reason = !Crypto.decryptionHealthy
                ? "the startup canary did not open — this process cannot read what a "
                  + "previous run wrote"
                : "\(unreadable)/\(items.count) clips are unreadable"
            NSLog("Cliphoard: SAFE MODE — \(reason). No migration, re-seal or re-index "
                  + "will run; nothing will be deleted.")
            DebugLog.write("SAFE MODE — \(reason)")
            sortStable()
            rebuildTagIndex()
            rebuildUserTagIndex()
            return
        }
        // Ordered BEFORE the index builds below: a clip that turns out to be a
        // secret must have its vectors dropped before anything can put it back
        // into a tag bucket.
        backfillDetectorFlagsIfNeeded()
        encryptExistingRowsIfNeeded()
        reKeyToSecureEnclaveIfNeeded()
        encryptImagePayloadsIfNeeded()
        sortStable()
        rebuildTagIndex()
        rebuildUserTagIndex()
        sweepOrphanPayloads()
        // After the safe-mode early return above, so safe mode is honoured by
        // construction here rather than by remembering a second check.
        scheduleImageUnderstanding()
    }

    /// One-time re-key: when the encryption key gains Secure-Enclave backing, rows
    /// sealed with the old random key (decrypted during loadAll via Crypto's legacy
    /// fallback) are re-sealed under the Enclave-derived key. No data loss even if
    /// interrupted — `Crypto.open` still falls back to the old key for any row not
    /// yet re-sealed. Gated by a flag; only runs on Secure-Enclave Macs.
    private func reKeyToSecureEnclaveIfNeeded() {
        let flag = "reKeySEv2"
        guard Crypto.usesSecureEnclave, !UserDefaults.standard.bool(forKey: flag) else { return }
        for item in items { db?.insert(item) }
        db?.vacuum()
        UserDefaults.standard.set(true, forKey: flag)
    }

    /// One-time migration: rewrite every row so its content is encrypted at rest
    /// (inserts now encrypt). Rows loaded as legacy plaintext are unaffected in
    /// memory; this just re-persists them sealed. Runs once, gated by a flag.
    private func encryptExistingRowsIfNeeded() {
        let key = "dbEncryptedV1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        for item in items { db?.insert(item) }
        db?.vacuum()   // purge stale plaintext from free pages
        UserDefaults.standard.set(true, forKey: key)
    }

    /// One-time, best-effort: seal every on-disk image payload + thumbnail that is
    /// still plaintext, so at-rest bytes carry the `enc1:` marker instead of PNG
    /// magic. New captures are already sealed by ClipboardMonitor.persistImage;
    /// this upgrades PNGs written before encryption. Non-destructive: any `*.png`
    /// already carrying the marker is skipped, so the pass is idempotent and safe
    /// to re-run if interrupted (the read path's Crypto.open still handles any
    /// not-yet-sealed file). The overwrite is atomic (write-temp-then-rename), so
    /// an interrupted/failed write can never leave a torn payload that is neither
    /// valid PNG nor a complete `enc1:` ciphertext — the original plaintext stays
    /// intact and the pass simply re-runs next launch. Filename-based, so T2's `<hash>.png` / `<hash>-thumb.png`
    /// naming and sweepOrphanPayloads/delete paths are unaffected. Gated by a flag.
    private func encryptImagePayloadsIfNeeded() {
        let flag = "imagesEncryptedV1"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) {
            for url in entries where url.pathExtension.lowercased() == "png" {
                guard let raw = try? Data(contentsOf: url), !Crypto.isSealed(raw),
                      let sealed = Crypto.seal(raw), Crypto.isSealed(sealed) else { continue }
                do { try sealed.write(to: url, options: .atomic) } catch { continue }
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
        UserDefaults.standard.set(true, forKey: flag)
    }

    // MARK: Detector backfill

    /// Gate for the one-time detector backfill. The version lives in the key
    /// itself: shipping a materially better detector means adding
    /// `detectorBackfillV2` rather than redefining what an already-set flag
    /// meant, so an upgrade can re-run the pass without a schema change.
    static let detectorBackfillDefaultsKey = "detectorBackfillV1"

    /// True for a clip whose Tier-1 verdict was (as far as we can tell) never
    /// computed — it predates `ClipStore.add`'s detector pass (design §5).
    ///
    /// There is no "scanned" column to consult, so the predicate is deliberately
    /// **over-inclusive**: a scanned prose clip on which nothing fired is
    /// indistinguishable from an unscanned one, and it is re-scanned. That is the
    /// fail-closed direction — a false positive costs one sub-millisecond pure
    /// function call and produces the same empty verdict (the pass is idempotent),
    /// whereas a false negative would leave a secret unscanned, and therefore in
    /// the CoreML index, forever.
    static func needsDetectorBackfill(_ item: ClipItem) -> Bool {
        item.flags.isEmpty && item.shape == nil
    }

    /// One-time backfill: compute `flags` + `shape` for every clip captured
    /// before the detectors existed, persist the verdict, and — critically —
    /// PURGE the vectors of anything that turns out to be `.secret` /
    /// `.quarantined`.
    ///
    /// Why the purge is the point: `add` can veto indexing only for clips it
    /// sees at capture time. Every clip already in history was embedded before
    /// any detector existed, so a password or an API token sitting in the store
    /// today is still a live row in the CoreML index and still reachable by
    /// semantic search. Flagging it without dropping its vector would put a
    /// warning badge on a leak instead of closing it, so the purge is both
    /// in-memory (`embeddings = [:]`) and on-disk (`Database.deleteEmbeddings`),
    /// exactly as `reindexStale` does for a clip that becomes vetoed later.
    ///
    /// Runs at construction, never on the copy hot path — `add` keeps its single
    /// scan of the single clip being captured and never loops over history.
    /// Cheap: pure byte rules over clips that have no verdict yet, one batched
    /// transaction, and a row write only for the clips that actually changed.
    /// Resumable: the completion flag is set only after a whole pass, so an
    /// interrupted (crashed) run simply repeats — the scan is a pure function of
    /// the clip, so re-running it cannot produce a different answer.
    private func backfillDetectorFlagsIfNeeded() {
        let flag = Self.detectorBackfillDefaultsKey
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        let candidates = items.filter(Self.needsDetectorBackfill)
        var scanned = 0
        var purged = 0
        // Only a COMMITTED pass may mark the backfill done. Setting the one-shot
        // flag after a rolled-back transaction would retire the backfill forever
        // while the rows stayed unscanned — and these are precisely the clips
        // captured before detectors existed, so a secret already in the history
        // would keep its vector in the CoreML index with nothing left to catch it.
        var committed = true
        if !candidates.isEmpty {
            committed = db?.transaction {
                for item in candidates {
                    let verdict = Detectors.scan(text: SemanticRanker.searchText(item),
                                                 kind: item.kind, sourceApp: item.sourceApp)
                    item.flags = verdict.flags
                    item.shape = verdict.shape
                    // Same belt-and-braces as `add`: the origin rule is the one
                    // signal that must hold even if the content pass ever bails
                    // early, so OR it in explicitly rather than assume.
                    if Detectors.isSensitiveSource(item.sourceApp) { item.flags.insert(.quarantined) }
                    scanned += 1
                    let vetoed = item.isIndexVetoed
                    if vetoed {
                        item.embeddings = [:]
                        item.imageFeature = nil
                        db?.deleteEmbeddings(clipID: item.id)
                        db?.deleteImageFeature(clipID: item.id)
                        purged += 1
                    }
                    // Nothing fired and no shape: the stored row already reads
                    // back as exactly this verdict, so skip the write entirely.
                    guard vetoed || !item.flags.isEmpty || item.shape != nil else { continue }
                    db?.insert(item)
                }
            } ?? false      // no database open → nothing was persisted
        }
        guard committed else {
            DebugLog.write("detector backfill: transaction rolled back — NOT marking done, will retry")
            return
        }
        UserDefaults.standard.set(true, forKey: flag)
        if scanned > 0 {
            DebugLog.write("detector backfill: scanned \(scanned) unscanned clips, purged vectors from \(purged)")
        }
    }

    /// Heal stored rows: (1) re-derive each text-bearing clip's kind from
    /// deterministic detection, repairing rows a past embedding-based `refineKind`
    /// mis-promoted (e.g. plain words stored as Links); (2) drop image clips whose
    /// payload PNG has vanished, since they render as broken cards in Images.
    /// Idempotent and cheap (O(n)); runs once per launch.
    private func repairKinds() {
        var orphanedImages: [ClipItem] = []
        for item in items {
            if item.kind == .image {
                if let f = item.payloadFile,
                   !FileManager.default.fileExists(atPath: dir.appendingPathComponent(f).path) {
                    orphanedImages.append(item)
                }
                continue
            }
            guard item.payloadFile == nil, item.filePath == nil else { continue }
            let correct = ClipboardMonitor.detectKind(for: item.text)
            guard correct != item.kind else { continue }
            item.kind = correct
            item.colorHex = correct == .color ? item.text.trimmingCharacters(in: .whitespaces) : nil
            db?.updateMeta(item)
        }
        if !orphanedImages.isEmpty {
            let ids = Set(orphanedImages.map { $0.id })
            items.removeAll { ids.contains($0.id) }
            db?.delete(ids: Array(ids))
        }
    }

    /// Best-effort: delete any "*.png" payload files in the store directory that
    /// are no longer referenced by a live item's `payloadFile`. Guards against
    /// images leaking on disk after a crash, an interrupted delete, or a stale
    /// database. Errors are ignored — this is purely housekeeping.
    private func sweepOrphanPayloads() {
        let referenced = Set(items.compactMap { $0.payloadFile })
        // A clip "<uuid>.png" may have a sidecar thumbnail "<uuid>-thumb.png"
        // (ClipboardMonitor.writeThumbnail). Keep a thumbnail whose original is
        // still referenced — otherwise the sweep deletes every thumbnail on launch.
        func isLiveThumbnail(_ name: String) -> Bool {
            guard name.hasSuffix("-thumb.png") else { return false }
            return referenced.contains(String(name.dropLast("-thumb.png".count)) + ".png")
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return }
        for url in entries where url.pathExtension.lowercased() == "png" {
            let name = url.lastPathComponent
            if !referenced.contains(name) && !isLiveThumbnail(name) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Directory where binary payloads (images) live.
    var storeDirectory: URL { dir }

    // MARK: - Image understanding

    /// Bumped on every applied result. `PanelViewModel.ResultsKey` proxies store changes
    /// by `(items.count, lastAddedID)` and its own comment admits an in-place mutation
    /// that touches neither is undetected — recognition landing is exactly that mutation,
    /// so without this the panel shows stale results until the next copy and the feature
    /// looks broken.
    private(set) var imageUnderstandingRevision = 0
    private var imageTask: Task<Void, Never>?
    @Published private(set) var imageProgress: IndexingProgress?

    /// Opt-out. Default ON: the image bytes are already sealed in this database, so
    /// recognition extracts nothing that was not already stored, and it never leaves the
    /// machine. What it changes is REACHABILITY, which is why the withhold rule below is
    /// wider than the ordinary index veto.
    static var imageUnderstandingEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: "imageUnderstandingEnabled") == nil
                ? true : UserDefaults.standard.bool(forKey: "imageUnderstandingEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "imageUnderstandingEnabled") }
    }

    /// Exactly the rows the pass has never looked at. The column IS the marker, so
    /// backfill and steady state are one code path and a crash mid-pass leaves the
    /// remainder untouched — no UserDefaults one-shot flag, which is what forced the
    /// detector backfill's predicate to be deliberately over-inclusive.
    static func needsImageUnderstanding(_ item: ClipItem) -> Bool {
        item.kind == .image && item.payloadFile != nil && item.ocrText == nil
    }

    /// The only place recognised TEXT is ever assigned. (Two other sites write the empty
    /// marker — a vetoed clip and an undecryptable payload, both in the pass below — and
    /// neither has any recognised text to leak; the load initialiser assigns what was
    /// already stored. Saying "the only assignment" would be false 70 lines down.)
    ///
    /// Synchronous from the scan to the assignment, with NO suspension between them.
    ///
    /// That is the whole safety argument, not a style preference. `flags` is mutable and
    /// this is the first thing in the codebase that mutates it after capture; if a
    /// suspension point were introduced between reading the verdict and writing the
    /// decision, the decision would be made against flags that had already moved. Do not
    /// "tidy" an await into this function.
    ///
    /// Order: scan → union → decide → assign → purge → persist → index.
    func applyImageUnderstanding(_ result: ImageUnderstanding.Result, to item: ClipItem) {
        // 1. SCAN FIRST. The recognised string is untrusted content no detector has seen:
        //    the capture-time scan ran against the placeholder caption ("Image 1920×1080")
        //    and necessarily returned nothing, because recognition cannot run on the
        //    sub-second poll path. Nothing else re-scans.
        let verdict = Detectors.scan(text: result.text, kind: item.kind, sourceApp: item.sourceApp)

        // 2. UNION, never assign. `add` assigns (`item.flags = verdict.flags`) and is
        //    safe there only because it re-ORs the origin quarantine immediately after.
        //    Copying that idiom here would clear `.quarantined` from a password-manager
        //    screenshot the instant recognition finished — a total veto bypass, in code
        //    that reads correct.
        item.flags.formUnion(verdict.flags)

        // 3. Decide BEFORE assigning. Withholding is wider than vetoing, deliberately:
        //    see ClipItem.ocrWithholdFlags.
        let withhold = item.isIndexVetoed
            || !item.flags.isDisjoint(with: ClipItem.ocrWithholdFlags)
        item.ocrText = withhold ? "" : result.text

        // 4. If the clip is NOW vetoed, drop everything derived. It was embedded at
        //    capture on its caption, and may hold a print. A perceptual print of a
        //    vault screenshot still confirms the user viewed that exact screen.
        if item.isIndexVetoed {
            item.embeddings = [:]
            item.imageFeature = nil
            db?.deleteEmbeddings(clipID: item.id)
            db?.deleteImageFeature(clipID: item.id)
        } else if !result.featurePrint.isEmpty {
            item.imageFeature = (revision: result.featurePrintRevision, vector: result.featurePrint)
            db?.upsertImageFeature(clipID: item.id, revision: result.featurePrintRevision,
                                   vector: result.featurePrint)
        }

        // 5. Persist the sealed text and the flags together.
        db?.updateOCR(item)

        // 6. ONLY NOW may the model see it — and unconditionally, NOT gated on staleness:
        //    the clip was already embedded at capture on its caption, so it is not stale,
        //    and that worthless vector would never otherwise be replaced.
        if !item.isIndexVetoed && DeepSearch.level != .off {
            ClipIndexer.index(item)
            if let emb = item.embeddings[EmbedderProvider.active.signature] {
                db?.upsertEmbedding(clipID: item.id, model: EmbedderProvider.active.signature,
                                    embedding: emb)
            }
        }
        removeFromTagIndex(item)
        addToTagIndex(item)
        imageUnderstandingRevision &+= 1
        objectWillChange.send()
    }

    /// Recognise text + prints for every never-analysed image, serialized, off the main
    /// actor, resumable.
    ///
    /// NOT on the capture path: recognition costs 100–300 ms and `ClipboardMonitor.poll`
    /// fires every 0.4 s. NOT lazy-on-first-search either — that would put a stall on the
    /// first keystroke after launch and run Vision inside a view body.
    func scheduleImageUnderstanding() {
        // Safe mode is absolute. This pass REWRITES rows that already exist, which is
        // precisely the bulk mutation safe mode exists to forbid. (Belt and braces: the
        // `init` call site already sits after the safe-mode early return, so this is
        // honoured by construction there — but `add` also schedules.)
        // Logged, because a background pass that silently does nothing is indistinguishable
        // from a broken one — and counts/reasons are not content, so this is safe to log.
        func report(_ message: String) {
            NSLog("Cliphoard images: \(message)")
            DebugLog.write("images: \(message)")
        }
        guard !safeMode else { return report("skipped — SAFE MODE") }
        guard Self.imageUnderstandingEnabled else {
            return report("skipped — turned off in Settings")
        }
        guard imageTask == nil else { return }   // already running; not worth a line
        let pending = items.filter(Self.needsImageUnderstanding).count
        report("pass starting — \(pending) unanalysed of "
               + "\(items.filter { $0.kind == .image }.count) image clips")
        imageTask = Task { @MainActor [weak self] in
            defer { self?.imageTask = nil; self?.imageProgress = nil }
            // Failures are remembered for THIS LAUNCH only. A transient decrypt failure
            // must retry next launch rather than be stamped `""` — "analysed, nothing
            // there" — forever.
            var attempted: Set<UUID> = []
            while !Task.isCancelled {
                guard let self else { return }
                let batch = self.items.filter {
                    Self.needsImageUnderstanding($0) && !attempted.contains($0.id)
                }
                guard !batch.isEmpty else { break }   // drains clips added mid-pass
                var done = 0
                self.imageProgress = IndexingProgress(done: 0, total: batch.count)
                for item in batch {
                    if Task.isCancelled { return }
                    attempted.insert(item.id)
                    defer {
                        done += 1
                        self.imageProgress = IndexingProgress(done: done, total: batch.count)
                    }
                    // A clip already vetoed at entry is NEVER analysed. Cheapest possible
                    // protection: the pixels are not even decoded.
                    guard !item.isIndexVetoed else {
                        item.ocrText = ""            // analysed-and-nothing-stored
                        self.db?.updateOCR(item)
                        continue
                    }
                    guard let png = self.decryptedPayload(item) else {
                        // Unreadable payload. The state machine does NOT cover this for
                        // free — `Crypto.open` fails open for strings — so mark it here,
                        // explicitly, rather than leaving it to be retried forever.
                        item.ocrText = ""
                        self.db?.updateOCR(item)
                        continue
                    }
                    // Vision OFF the main actor: the panel must never stall behind it.
                    let analyze = ImageUnderstanding.analyze
                    let result = await Task.detached(priority: .utility) { analyze(png) }.value
                    self.applyImageUnderstanding(result, to: item)
                    // Character COUNT and outcome only — never a character of the text.
                    // The whole point is that some of this is deliberately not stored;
                    // logging it would defeat that more thoroughly than storing it.
                    DebugLog.write("images: \(done + 1)/\(batch.count) — "
                          + "\((item.ocrText ?? "").isEmpty ? "nothing stored" : "\(item.ocrText!.count) chars")"
                          + ", print \(result.featurePrint.isEmpty ? "none" : "\(result.featurePrint.count)-d")")
                    await Task.yield()
                }
            }
        }
    }

    /// How many clips currently hold recognised text. Drives the Settings count, so the
    /// user can see what "forget" would actually erase before pressing it.
    var recognisedImageCount: Int {
        items.filter { !($0.ocrText ?? "").isEmpty }.count
    }

    /// Erase every recognised text and print, in memory and on disk.
    ///
    /// This is what makes the Settings toggle honest. Turning recognition OFF stops
    /// future analysis but cannot un-read what was already read; without this button the
    /// only way to undo it would be deleting the clips themselves.
    ///
    /// Rows go back to NULL, not "": if the user re-enables recognition later, they
    /// should be analysed again rather than being permanently marked "nothing there".
    func forgetImageUnderstanding() {
        imageTask?.cancel()
        imageTask = nil
        for item in items where item.kind == .image {
            item.ocrText = nil
            item.imageFeature = nil
            // The vector was computed FROM the recognised text, so it has to go too —
            // otherwise the words remain reachable through semantic search after the
            // user was told they were forgotten.
            item.embeddings = [:]
        }
        db?.forgetAllImageUnderstanding()
        for item in items where item.kind == .image {
            db?.deleteEmbeddings(clipID: item.id)
        }
        rebuildTagIndex()
        imageUnderstandingRevision &+= 1
        objectWillChange.send()
    }

    /// Images most visually similar to this one, nearest first.
    ///
    /// Cosine on the stored print, which orders the same way as Vision's own distance
    /// because the print is L2-normalised. Only prints from the SAME revision are
    /// comparable — revision 1 emits 2048 floats and revision 2 emits 768 — so a
    /// mismatched row is skipped rather than scored against a different space.
    func similarImages(to item: ClipItem, limit: Int = 12) -> [ClipItem] {
        guard let mine = item.imageFeature, !mine.vector.isEmpty else { return [] }
        return items
            .filter { $0.id != item.id && !$0.isIndexVetoed }
            .compactMap { other -> (ClipItem, Float)? in
                guard let theirs = other.imageFeature,
                      theirs.revision == mine.revision,
                      theirs.vector.count == mine.vector.count else { return nil }
                return (other, ImageUnderstanding.similarity(mine.vector, theirs.vector))
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// Decrypted image bytes, or nil when the payload is missing or unreadable.
    ///
    /// The nil case is why the caller must store the empty marker explicitly: `Crypto.open`
    /// FAILS OPEN for strings, so an unreadable value elsewhere surfaces as ciphertext
    /// rather than as an error. Here we get a real nil and must not mistake it for
    /// "analysed, found nothing".
    func decryptedPayload(_ item: ClipItem) -> Data? {
        guard let file = item.payloadFile,
              let stored = try? Data(contentsOf: dir.appendingPathComponent(file))
        else { return nil }
        return Crypto.open(stored)
    }

    // MARK: Mutations

    func add(_ item: ClipItem) {
        item.userTags = ClipItem.normalizedUserTags(item.userTags)
        // Drop a consecutive duplicate, but bump it to the front instead.
        if let existing = items.first(where: { $0.signature == item.signature }) {
            existing.lastUsedAt = Date()
            move(existing, toFront: true)
            lastAddedID = existing.id
            db?.updateMeta(existing)
            return
        }
        // Tier-1 detector pass (design §5). SYNCHRONOUS, and deliberately ordered
        // BEFORE the CoreML embed and BEFORE the SQLite write: it is sub-millisecond
        // against a tens-of-milliseconds forward pass, and running it first is the
        // only thing that lets a detector VETO indexing of a secret. Exactly one
        // scan per added clip — the dedup path above returns before reaching here,
        // and nothing re-scans in a loop over history.
        let verdict = Detectors.scan(text: SemanticRanker.searchText(item),
                                     kind: item.kind, sourceApp: item.sourceApp)
        item.flags = verdict.flags
        item.shape = verdict.shape
        // Belt and braces: `scan` already applies the §3.9 origin rule, but the
        // quarantine is the one signal that must hold even if the content pass
        // ever bails early, so OR it in explicitly rather than assume.
        if Detectors.isSensitiveSource(item.sourceApp) { item.flags.insert(.quarantined) }

        // Embed + tag at ingest (for the active model) so semantic search is
        // ready immediately. Skipped in the `off` tier, which uses no vectors.
        // NB: the clip's KIND is whatever deterministic detection decided — we no
        // longer let embeddings reclassify it (that put non-URLs into Links).
        if item.isIndexVetoed {
            // Fail closed: a secret or a quarantined clip is excluded from the
            // CoreML index entirely — it is never sent through the model and any
            // vector it somehow arrived with is dropped before it can be stored.
            // The clip is still persisted (sealed) and still shows in history; it
            // simply has no vector, so semantic search cannot surface it.
            item.embeddings = [:]
        } else if DeepSearch.level != .off && ClipIndexer.isStale(item) {
            ClipIndexer.index(item)
        }
        items.insert(item, at: 0)
        trim()
        // Keep the pinned-first / recency order consistent with every other path.
        sortStable()
        // Incrementally index the new item rather than rebuilding the whole map.
        // `trim()` may have evicted other (unpinned) items; drop those too so the
        // index stays in sync with `items`.
        pruneTagIndexToItems()
        addToTagIndex(item)
        pruneUserTagIndexToItems()
        addToUserTagIndex(item)
        lastAddedID = item.id
        db?.insert(item)
        // Recognition runs off the capture path — this only schedules. The dedup branch
        // above returns before reaching here, so a re-copied screenshot never re-analyses.
        if item.kind == .image { scheduleImageUnderstanding() }
        Feedback.playCapture()
    }

    /// Entries pre-classified under a preset tag — O(1) lookup, no dot products.
    func items(taggedWith tagID: Int) -> [ClipItem] { tagIndex[tagID] ?? [] }

    func items(withUserTag tag: String) -> [ClipItem] {
        guard let normalized = ClipItem.normalizedUserTags([tag]).first else { return [] }
        return userTagIndex[normalized] ?? []
    }

    var distinctUserTags: [String] { allUserTags() }

    /// Every distinct user tag currently in use, sorted — the autocomplete source.
    /// Read straight off the index, so it never scans `items`.
    func allUserTags() -> [String] { userTagIndex.keys.sorted() }

    /// Add one user tag to a clip (no-op if already present). Writes through the
    /// sealed DB column first; a refused write leaves both clip and index untouched.
    @discardableResult
    func addUserTag(_ tag: String, to item: ClipItem) -> Bool {
        guard let normalized = ClipItem.normalizedUserTags([tag]).first else { return false }
        guard !item.userTags.contains(normalized) else { return true }
        return updateUserTags(item, to: item.userTags + [normalized])
    }

    /// Remove one user tag from a clip (no-op if absent).
    @discardableResult
    func removeUserTag(_ tag: String, from item: ClipItem) -> Bool {
        guard let normalized = ClipItem.normalizedUserTags([tag]).first else { return false }
        guard item.userTags.contains(normalized) else { return true }
        return updateUserTags(item, to: item.userTags.filter { $0 != normalized })
    }

    /// Suggestion dismissals (spec §5.1) — persisted sealed, so a dismissed tag is
    /// never re-offered for that clip.
    @discardableResult
    func dismissSuggestedUserTag(_ tag: String, for item: ClipItem) -> Bool {
        db?.addUserTagDismissal(tag: tag, clipID: item.id) ?? false
    }

    func dismissedUserTags(for item: ClipItem) -> Set<String> {
        db?.dismissedUserTags(forClip: item.id) ?? []
    }

    /// Replace a clip's user labels and update storage/index atomically from the
    /// caller's perspective. A failed sealed DB write restores the prior labels.
    @discardableResult
    func updateUserTags(_ item: ClipItem, to tags: [String]) -> Bool {
        let old = item.userTags
        removeFromUserTagIndex(item)
        item.userTags = ClipItem.normalizedUserTags(tags)
        guard db?.updateUserTags(item) ?? false else {
            item.userTags = old
            addToUserTagIndex(item)
            return false
        }
        addToUserTagIndex(item)
        objectWillChange.send()
        return true
    }

    /// Entries matching a facet-cube constraint set, in `items` order. Standard
    /// facet semantics: values within the same dimension are OR'd, and different
    /// dimensions are AND'd — e.g. {code, python} means "Content type is code AND
    /// Language is python", while {python, javascript} means "python OR javascript".
    /// Resolved from the tag index (union the buckets per dimension, intersect
    /// across dimensions), so it stays O(selected buckets) — no dot products.
    func items(matchingFacets facets: Set<Int>, userTags: Set<String> = []) -> [ClipItem] {
        guard !facets.isEmpty || !userTags.isEmpty else { return items }
        // Group the selected tag ids by the dimension they belong to. A flat
        // basket (no dimensions) puts every selection in one group → pure OR.
        var byDimension: [Int: Set<Int>] = [:]
        for tag in facets {
            let d = TagSpace.dimension(ofTag: tag) ?? -1
            byDimension[d, default: []].insert(tag)
        }
        var matched: Set<UUID>?
        for (_, selected) in byDimension {
            var union: Set<UUID> = []
            for tag in selected { for it in (tagIndex[tag] ?? []) { union.insert(it.id) } }
            matched = matched.map { $0.intersection(union) } ?? union
            if matched?.isEmpty == true { return [] }
        }
        let normalizedUserTags = ClipItem.normalizedUserTags(Array(userTags))
        if !normalizedUserTags.isEmpty {
            var union: Set<UUID> = []
            for tag in normalizedUserTags {
                for item in userTagIndex[tag] ?? [] { union.insert(item.id) }
            }
            matched = matched.map { $0.intersection(union) } ?? union
            if matched?.isEmpty == true { return [] }
        }
        let keep = matched ?? []
        return items.filter { keep.contains($0.id) }
    }

    /// Idempotent and unconditional: a pure function of (items, active embedder,
    /// active basket) whose only output is this in-memory index. Interrupting it is
    /// harmless because it writes nothing that could later be read as authoritative —
    /// which is why it needs no marker, no one-shot guard and no bounds check.
    func rebuildTagIndex() {
        var index: [Int: [ClipItem]] = [:]
        for item in items {
            for tag in tags(of: item) { index[tag, default: []].append(item) }
        }
        tagIndex = index
    }

    private func rebuildUserTagIndex() {
        var index: [String: [ClipItem]] = [:]
        for item in items {
            item.userTags = ClipItem.normalizedUserTags(item.userTags)
            for tag in item.userTags { index[tag, default: []].append(item) }
        }
        userTagIndex = index
    }

    private func addToUserTagIndex(_ item: ClipItem) {
        var order: [UUID: Int] = [:]
        for (index, candidate) in items.enumerated() { order[candidate.id] = index }
        guard order[item.id] != nil else { return }
        for tag in item.userTags {
            var bucket = userTagIndex[tag] ?? []
            if !bucket.contains(where: { $0.id == item.id }) { bucket.append(item) }
            bucket.sort { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
            userTagIndex[tag] = bucket
        }
    }

    private func removeFromUserTagIndex(_ item: ClipItem) {
        for (tag, bucket) in userTagIndex {
            let pruned = bucket.filter { $0.id != item.id }
            if pruned.isEmpty { userTagIndex[tag] = nil } else { userTagIndex[tag] = pruned }
        }
    }

    private func pruneUserTagIndexToItems() {
        let live = Set(items.map(\.id))
        for (tag, bucket) in userTagIndex {
            let pruned = bucket.filter { live.contains($0.id) }
            if pruned.isEmpty { userTagIndex[tag] = nil } else { userTagIndex[tag] = pruned }
        }
    }

    /// The active-model tag ids attached to a clip, or an empty list.
    /// A clip's tag ids, DERIVED from its cached vector under the active embedder
    /// and the active basket. Never stored.
    ///
    /// This is the fix. An id is a positional index into `TagBaskets.active.tags`, so
    /// a stored id does not become INVALID when the vocabulary changes — it becomes
    /// WRONG, resolving to a different word. Deriving means the ids cannot disagree
    /// with the vocabulary, because there is no second copy to disagree with and no
    /// marker that can claim they are current while they are not.
    ///
    /// A clip with no vector for the active model yields NO tags rather than a wrong
    /// answer. That is also the correct answer during the window before the real
    /// embedder finishes loading — which is why nothing here depends on the order in
    /// which the store and the embedder are constructed. Every ordering yields the
    /// right answer or no answer, never a wrong one.
    ///
    /// The veto is applied HERE, at the single point of derivation, rather than left
    /// to whichever purge happened to run first: a secret must not reach the tag index
    /// even if some future path leaves a vector behind.
    func tags(of item: ClipItem) -> [Int] {
        guard !item.isIndexVetoed,
              let emb = item.embeddings[EmbedderProvider.active.signature] else { return [] }
        return ClipIndexer.tags(for: emb.vector, embedder: EmbedderProvider.active)
    }

    /// Insert `item` into each of its active-model tag buckets at the position
    /// dictated by the current `items` order, so the bucket contents stay
    /// byte-for-byte identical to a full `rebuildTagIndex()`. O(tags · bucket)
    /// instead of O(n · tags).
    ///
    /// Buckets are re-ordered to `items` order on insert. This matters because
    /// other paths (markUsed / togglePin / dedup-bump) reorder `items` *without*
    /// re-indexing — exactly as the original full-rebuild-on-add code did, which
    /// would re-sort the whole bucket on the next add — so a stale relative order
    /// must not survive a new-item add.
    private func addToTagIndex(_ item: ClipItem) {
        // Map every item to its index in `items` so buckets can be kept in the
        // same order a full rebuild (which iterates `items`) would produce.
        var order: [UUID: Int] = [:]
        order.reserveCapacity(items.count)
        for (i, it) in items.enumerated() { order[it.id] = i }
        guard order[item.id] != nil else { return }
        for tag in tags(of: item) {
            var bucket = tagIndex[tag] ?? []
            bucket.append(item)
            bucket.sort { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
            tagIndex[tag] = bucket
        }
    }

    /// Re-sort the buckets containing `item` back into `items` order after a move
    /// reshuffled `items`. Only the moved item's own buckets can be affected, so
    /// this stays cheap (O(itemTags · bucket)).
    private func repositionInTagIndex(_ item: ClipItem) {
        let tags = tags(of: item)
        guard !tags.isEmpty else { return }
        var order: [UUID: Int] = [:]
        order.reserveCapacity(items.count)
        for (i, it) in items.enumerated() { order[it.id] = i }
        for tag in tags {
            guard var bucket = tagIndex[tag], bucket.contains(where: { $0.id == item.id })
            else { continue }
            bucket.sort { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
            tagIndex[tag] = bucket
        }
    }

    /// Remove `item` from every tag bucket it appears in, dropping now-empty
    /// buckets so the map matches a full rebuild (which never holds empty keys).
    private func removeFromTagIndex(_ item: ClipItem) {
        for (tag, bucket) in tagIndex {
            guard bucket.contains(where: { $0.id == item.id }) else { continue }
            let pruned = bucket.filter { $0.id != item.id }
            if pruned.isEmpty { tagIndex[tag] = nil } else { tagIndex[tag] = pruned }
        }
    }

    /// Drop any tag-bucket entries for items no longer in `items` (e.g. evicted by
    /// `trim()`), dropping now-empty buckets. Keeps incremental updates in sync
    /// without a full rebuild.
    private func pruneTagIndexToItems() {
        let live = Set(items.map { $0.id })
        for (tag, bucket) in tagIndex {
            guard bucket.contains(where: { !live.contains($0.id) }) else { continue }
            let pruned = bucket.filter { live.contains($0.id) }
            if pruned.isEmpty { tagIndex[tag] = nil } else { tagIndex[tag] = pruned }
        }
    }

    /// Point the store at the now-active model: rebuild the tag index for its
    /// cached tags and fill in any clips it hasn't embedded yet.
    func refreshForActiveModel() {
        rebuildTagIndex()
        reindexStale()
    }

    /// Embed only the entries the active model hasn't processed yet (a clip the
    /// model already embedded — e.g. on a round-trip model switch — is skipped).
    /// Runs in the background, yields between items so the UI stays responsive,
    /// and is resumable — an interrupted pass leaves the rest for next time.
    func reindexStale() {
        let sig = EmbedderProvider.active.signature
        // A vetoed clip is permanently "stale" (it has no vector and never will),
        // so it must be filtered out HERE rather than skipped inside the loop —
        // otherwise a background pass would both re-offer it to the model and
        // report a total it can never reach. This is the re-index half of the
        // §5 veto: housekeeping must not quietly undo an ingest-time decision.
        // PURGE before filtering: a clip can BECOME vetoed after it was indexed
        // (the denylist grows, a detector improves). Skipping it in later passes
        // stops NEW leaks but leaves the old vector in memory and on disk — the
        // secret stays searchable. Drop those vectors first, then filter.
        for item in items where item.isIndexVetoed && !item.embeddings.isEmpty {
            item.embeddings = [:]
            db?.deleteEmbeddings(clipID: item.id)
        }
        // Prints too, and on their own predicate — a clip can hold a print with no
        // vectors, so folding this into the loop above would silently miss it. A
        // perceptual print of a vault screenshot is not readable text, but it still
        // confirms the user was looking at that exact screen.
        for item in items where item.isIndexVetoed && item.imageFeature != nil {
            item.imageFeature = nil
            db?.deleteImageFeature(clipID: item.id)
        }
        let stale = items.filter { ClipIndexer.isStale($0) && !$0.isIndexVetoed }
        guard !stale.isEmpty else { return }
        let total = stale.count
        let started = Date()
        indexing = IndexingProgress(done: 0, total: total, etaSeconds: nil)
        indexingTask?.cancel()
        indexingTask = Task { @MainActor in
            var done = 0
            for item in stale {
                if Task.isCancelled { break }
                ClipIndexer.index(item)
                if let emb = item.embeddings[sig] {
                    db?.upsertEmbedding(clipID: item.id, model: sig, embedding: emb)
                }
                done += 1
                if done % 8 == 0 || done == total {
                    let elapsed = Date().timeIntervalSince(started)
                    let eta = done > 0 ? elapsed / Double(done) * Double(total - done) : nil
                    indexing = IndexingProgress(done: done, total: total, etaSeconds: eta)
                    rebuildTagIndex()
                    await Task.yield()
                }
            }
            rebuildTagIndex()
            indexing = nil
            indexingTask = nil
            DebugLog.write("reindexed \(done) stale items → \(sig)")
        }
    }

    func togglePin(_ item: ClipItem) {
        item.pinned.toggle()
        sortStable()
        // Toggling the pin moves only this item across the pinned boundary; other
        // items keep their relative order, so repositioning just this item's
        // buckets keeps tagIndex identical to a full rebuild (BL-08 correctness).
        repositionInTagIndex(item)
        rebuildUserTagIndex()
        db?.updateMeta(item)
    }

    func delete(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
        removePayload(item)
        removeFromTagIndex(item)
        removeFromUserTagIndex(item)
        db?.delete(id: item.id)
    }

    /// Clear everything that is not pinned.
    func clearUnpinned() {
        let removed = items.filter { !$0.pinned }
        items.removeAll { !$0.pinned }
        removed.forEach(removePayload)
        rebuildTagIndex()
        rebuildUserTagIndex()
        db?.deleteUnpinned()
    }

    func markUsed(_ item: ClipItem) {
        item.lastUsedAt = Date()
        item.useCount += 1
        move(item, toFront: true)
        rebuildUserTagIndex()
        db?.updateMeta(item)
    }

    // MARK: Querying

    func filtered(kind: ClipKind?, query: String, pinnedOnly: Bool,
                  facets: Set<Int> = [], userTags: Set<String> = [],
                  time: TimeFilter = .any) -> [ClipItem] {
        var result = items
        if pinnedOnly { result = result.filter { $0.pinned } }
        if let kind { result = result.filter { $0.kind == kind } }
        if time.isActive { result = result.filter { time.contains($0.createdAt) } }
        if !facets.isEmpty || !userTags.isEmpty {
            let keep = Set(items(matchingFacets: facets, userTags: userTags).map { $0.id })
            result = result.filter { keep.contains($0.id) }
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            result = result.filter {
                $0.text.lowercased().contains(q)
                || ($0.filePath?.lowercased().contains(q) ?? false)
                || ($0.colorHex?.lowercased().contains(q) ?? false)
                // Recognised image text — this is what lets Exact mode find a screenshot
                // by a word visible inside it, which is most of the feature's value.
                //
                // This filter carries NO veto, deliberately and by long-standing design:
                // a vetoed clip still matches by exact substring, because the veto is
                // about the MODEL, not about retrieval — the user copied that text and can
                // see it in the panel. Recognised text is different, because the user
                // never typed it. What keeps it safe is not a check here but the WRITE: a
                // withheld result is stored as "", and `q` is guaranteed non-empty three
                // lines up, so `"".contains(q)` is always false.
                //
                // Note this reads `ocrText` DIRECTLY, not through `searchText` — unlike
                // the two ranking paths, which get the same protection via searchText's
                // empty-to-caption fallback. Same outcome, two different mechanisms; worth
                // knowing, because changing either one alone would not be obviously wrong.
                || ($0.ocrText?.lowercased().contains(q) ?? false)
                || $0.userTags.contains { $0.contains(q) }
            }
        }
        return result
    }

    func counts() -> [ClipKind: Int] {
        var d: [ClipKind: Int] = [:]
        for item in items { d[item.kind, default: 0] += 1 }
        return d
    }

    // MARK: Helpers

    private func move(_ item: ClipItem, toFront: Bool) {
        guard items.contains(where: { $0.id == item.id }) else { return }
        sortStable()   // pinned-first, then recency — fully determines order
        // Reordering `items` shifts where `item` sits inside its tag buckets.
        // Keep the buckets in `items` order so the index stays identical to a full
        // rebuild without paying for one on every bump (markUsed / dedup).
        repositionInTagIndex(item)
    }

    private func sortStable() {
        items.sort { a, b in
            if a.pinned != b.pinned { return a.pinned && !b.pinned }
            return a.lastUsedAt > b.lastUsedAt
        }
    }

    private func removePayload(_ item: ClipItem) {
        if let f = item.payloadFile {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
            // Remove the sidecar thumbnail too.
            let thumb = (f as NSString).deletingPathExtension + "-thumb.png"
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(thumb))
        }
    }

    private func trim() {
        guard historyLimit > 0 else { return } // 0 = unlimited
        let unpinned = items.filter { !$0.pinned }
        guard unpinned.count > historyLimit else { return }
        let toRemove = Array(unpinned.suffix(unpinned.count - historyLimit))
        toRemove.forEach(removePayload)
        let removeIDs = Set(toRemove.map { $0.id })
        items.removeAll { removeIDs.contains($0.id) }
        db?.delete(ids: toRemove.map { $0.id })
        pruneUserTagIndexToItems()
    }

    // MARK: Migration

    /// One-time import of an old `history.json` into the database, then archive it.
    private func migrateLegacyJSONIfNeeded() {
        let jsonURL = dir.appendingPathComponent("history.json")
        guard (db?.clipCount() ?? 0) == 0,
              let data = try? Data(contentsOf: jsonURL) else { return }
        let decoded: [ClipItem]
        do { decoded = try JSONDecoder().decode([ClipItem].self, from: data) }
        catch {
            NSLog("Cliphoard: legacy history decode failed: \(error) — keeping history.corrupt.json (sealed)")
            // Never leave plaintext clip history on disk. Seal the bytes (enc1:
            // marker) before archiving so at-rest recovery is possible without
            // exposing passwords/tokens the legacy file may contain. Fail CLOSED:
            // if sealing fails we skip the archive rather than write plaintext.
            if let sealed = Crypto.sealStrict(data) {
                try? sealed.write(to: dir.appendingPathComponent("history.corrupt.json"), options: .atomic)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: dir.appendingPathComponent("history.corrupt.json").path)
            }
            return
        }
        for item in decoded {
            // Fold legacy single-vector fields into the per-model cache.
            if item.embeddings.isEmpty, let v = item.vector {
                item.embeddings[item.vectorModel ?? "hashing-256"] =
                    ModelEmbedding(vector: v)
            }
            item.vector = nil; item.vectorModel = nil
        }
        db?.transaction { decoded.forEach { db?.insert($0) } }
        // Archive the JSON so we don't re-import (and as a safety backup), but
        // never as plaintext: this is exactly the upgrade audience at-rest
        // encryption is meant to protect. Seal the bytes (enc1: marker) into
        // history.migrated.json, then remove the original plaintext history.json.
        // Fail CLOSED: only delete the plaintext original once a SEALED archive is
        // safely written — never write a plaintext archive, never delete without one.
        if let sealed = Crypto.sealStrict(data) {
            let archiveURL = dir.appendingPathComponent("history.migrated.json")
            try? sealed.write(to: archiveURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: archiveURL.path)
            try? FileManager.default.removeItem(at: jsonURL)
        }
        DebugLog.write("migrated \(decoded.count) clips from history.json → sqlite (archive sealed)")
    }
}
