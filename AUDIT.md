# Cliphoard Audit — Confirmed Findings

macOS clipboard manager. Source at `/tmp/ditto-audit`. This document records only findings the adversary **confirmed** (`confirmed=true`, `corrected_severity != none`), using the **corrected** severity (adjudicated, not averaged). Findings that recur across dimensions are deduplicated (see notes). A refuted/struck appendix follows.

Confirmed tally: **1 Critical, 13 High, 11 Medium, 13 Low** (after cross-dimension dedup of the synchronous-CoreML-on-main-actor finding, which appeared in both Concurrency and Memory — counted once as High).

---

## CRITICAL

### C1. No notarization or hardened runtime — Gatekeeper blocks the app on any other Mac
- **File:** `Scripts/build-app.sh` (lines 64-71); no `.entitlements` anywhere.
- **Evidence:** Signs with a self-signed "Ditto Local Signing" identity or ad-hoc (`codesign --force --deep --sign -`). No `--options runtime`, no `--timestamp`, no `--entitlements`, no `notarytool`/`stapler` step. Repo-wide grep for notariz/hardened/stapler returns only aspirational SPEC.md text. SPEC.md line 113 lists "Developer-ID-signed + notarized build" under PLANNED.
- **Impact:** Any user receiving the `.app` via download/AirDrop/USB hits a hard Gatekeeper block ("Apple cannot check it for malicious software") or it is moved to Trash on first open. Effectively undistributable outside the author's machine — release-blocking for a wide userbase.
- **Recommendation:** Add a Developer ID Application signing path (`--options runtime --timestamp`), ship an entitlements file, and add a notarize+staple step (`xcrun notarytool submit` then `xcrun stapler staple`) to the release flow. Document a prebuilt download in the README.

---

## HIGH

### H1. Synchronous CoreML embedding runs on the main actor — blocks UI on every copy and on every keystroke
*(Dedup: this is the single most-cited defect; reported as Concurrency #1 and Memory #1. Counted once.)*
- **File:** `Sources/Cliphoard/Search/DeepSearch.swift:170` (`model.prediction`), `262-271` (`ClipIndexer.index`), `241` (`TagSpace.vectors`); call sites `Sources/Cliphoard/Clipboard/ClipStore.swift:70-73` (`add()`), `Sources/Cliphoard/UI/PanelViewModel.swift:61,65`.
- **Evidence:** `OgmaEmbedder.run` calls `out = try model.prediction(from: input)` synchronously; `OgmaEmbedder.embed`/`embed(_:query:)` are plain synchronous functions. Every caller is `@MainActor`: `ClipStore.add` runs `ClipIndexer.index` inline on the 0.4s poll path (`ClipboardMonitor.poll` -> `store.add`); `PanelViewModel.results` calls `TagSpace.nearestTag` and `SemanticRanker.essence` on every keystroke; `TagSpace.vectors` embeds all ~100 tag names in a loop (cached per (signature, basket)). Default tier is `.normal` (ogma-small), so this runs out of the box when a model is bundled.
- **Impact:** Copying anything runs a CoreML forward pass plus tag classification inline in the main-actor poll callback (tens-to-hundreds of ms, seconds for large pasted text — tokenizer Viterbi is O(word_len²)). Typing in Tag/Essence mode runs query embedding synchronously per keystroke. Menu bar, panel, and slide animation hitch; the poll timer is delayed so concurrent copies can be missed. (Note: when no `.mlmodelc` is bundled the fast `HashingEmbedder` is used, so the worst case requires the model present.)
- **Recommendation:** Move inference off the main actor — make `OgmaEmbedder` an actor or run `model.prediction` on a dedicated background queue/`MLModel` async API. Insert the clip immediately (kind/text), then embed+classify in a background Task and hop to `@MainActor` only to write `item.embeddings` / update results. The existing `reindexStale` pattern proves the structure works.

### H2. Reindex/reclassify Tasks are mislabeled "background" but execute on @MainActor
- **File:** `Sources/Cliphoard/Clipboard/ClipStore.swift:107` (`reindexStale`), `139` (`reclassifyAllTags`).
- **Evidence:** Both carry the doc comment "Runs in the background … so the UI stays responsive" but spawn `Task { @MainActor in … }` (lines 114, 147). `reindexStale` calls `ClipIndexer.index(item)` which on the ogma tiers runs synchronous CoreML inference; `await Task.yield()` (lines 127/161) merely reschedules on the same main actor. Yield cadence is every 8 items (reindex) / 16 (reclassify), so up to 8 full forward passes run inline before the UI runs. (`reclassifyAllTags` itself is cheap — cosine over cached tag vectors, no per-item embedding — so the stall is driven by `reindexStale`.)
- **Impact:** A model switch over a large history runs N CoreML predictions on the main actor with a yield only every 8 items, producing visible multi-second main-thread stalls despite the "stays responsive" claim.
- **Recommendation:** Run per-item embedding on a background actor/executor; hop to `@MainActor` only to publish `indexing` progress and assign `item.embeddings`. Keep the cooperative yield but move the expensive work off-main.

### H3. Tokenizer splits only on ASCII space — newlines/tabs become UNK runs, corrupting embeddings for multi-line clips
- **File:** `Sources/Cliphoard/Search/OgmaTokenizer.swift:54,71,72` (encode/normalize).
- **Evidence:** `encode()` does `normalize(text).split(separator: " ")` — splits on U+0020 only. `normalize()` never converts `\n`/`\t` to spaces; the double-space collapse touches only literal spaces; `trimmingCharacters(in: .whitespaces)` does not include newlines. Verified runtime repro: `"foo\nbar\tbaz qux"` produces a single metaspace word `▁foo\nbar\tbaz` (newline/tab embedded), not in the 30k vocab, so the Unigram Viterbi falls through to per-char UNK (lines 93-97). HF reference uses a Metaspace pre-tokenizer that splits on all whitespace; the three golden samples in `reference.json` are all single-line, so parity was only ever checked on inputs that hide this bug.
- **Impact:** Clipboard content is overwhelmingly multi-line (code, stack traces, logs, JSON) — exactly what the basket tags target ("stack trace", "json data", "source code", "base64 blob"). UNK-laden id sequences produce near-meaningless embeddings, so Essence search and tag classification silently mis-rank/mis-tag the most important clips. Persisted to SQLite, so the corruption is durable.
- **Recommendation:** Split on all Unicode whitespace (`split(whereSeparator: { $0.isWhitespace })`); in `normalize()` collapse every whitespace run to a single space before trimming with `.whitespacesAndNewlines`. Add a tokenizer unit test feeding multi-line text asserting no spurious UNK ids.

### H4. Search TextField is never made first responder — on a non-activating panel typed keys can go nowhere
- **File:** `Sources/Cliphoard/UI/ContentView.swift:57`; `Sources/Cliphoard/App/AppDelegate.swift:163-182`.
- **Evidence:** `TextField(..., text: $model.query)` has no `@FocusState`/`.focused` binding; project-wide grep for `FocusState|firstResponder|becomeFirstResponder|makeFirstResponder|.focused|focusable` returns nothing. `show()` never focuses the field; it calls `NSApp.activate(ignoringOtherApps:true)` + `panel.slideIn()`. Panel is `.nonactivatingPanel` (FloatingPanel.swift:25) and the app is `.accessory` (Main.swift:11). The `activate()` call raises the odds the panel becomes key (so keys are not guaranteed lost every time), but nothing reliably makes the search field first responder on summon.
- **Impact:** Summon-then-type is the single most common interaction for a clipboard manager. With no code focusing the field on a non-activating panel, keystrokes can be dropped or the field may not receive focus — search appears dead, intermittently, on the primary path.
- **Recommendation:** Add `@FocusState private var searchFocused: Bool`, bind with `.focused($searchFocused)`, and set it true on present (`.onChange(of: model.presentToken)` + `.onAppear`). Verify/force first responder after `slideIn`.

### H5. Entire clipboard history (incl. passwords/tokens) stored as plaintext SQLite — no encryption, no file protection, app not sandboxed
- **File:** `Sources/Cliphoard/Clipboard/Database.swift:13-35`; `Sources/Cliphoard/Clipboard/ClipStore.swift:41-48`; no `.entitlements`.
- **Evidence:** DB opened with only `SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE`; schema stores `text TEXT NOT NULL` plaintext, rtf as raw BLOB. No SQLCipher, no `SecItem`/Keychain. Store at `~/Library/Application Support/Ditto/ditto.sqlite` via `createDirectory` with no `NSFileProtection`/resource-protection key. Images persisted as plain `.png`. No `.entitlements` file exists and Package.swift declares no sandbox, so the app runs unsandboxed. `historyLimit=0` yields unlimited retention.
- **Impact:** Any process running as the user (malware, backup tool, log/collection agent) can read the full history — including credentials TagBaskets even expects — directly from the plaintext DB and PNG files. No encryption-at-rest, no sandbox confinement.
- **Recommendation:** Encrypt sensitive clips at rest (SQLCipher or Keychain-held key), set a restrictive file-protection key on the store directory, adopt App Sandbox with minimal entitlements. At minimum document the behavior and offer an "encrypt history" / auto-expire option.

### H6. Concealed/transient filtering misses most secret copies — secrets are captured and persisted
- **File:** `Sources/Cliphoard/Clipboard/ClipboardMonitor.swift:64-72`.
- **Evidence:** `poll()` skips only on exact match of `org.nspasteboard.TransientType` or `org.nspasteboard.ConcealedType`. No handling of `AutoGeneratedType`, no frontmost-bundle denylist, no SecureField/Keychain detection, no entropy heuristic. `capture()` then reads `.string` and `store.add()` persists. Keychain "Copy Password", SwiftUI/AppKit SecureField, browser password reveal, and CLI token output generally do NOT set the `org.nspasteboard` hints.
- **Impact:** Passwords/tokens from non-cooperating apps are silently recorded into permanent, unencrypted history — exactly what a clipboard manager should avoid retaining.
- **Recommendation:** Add a user-configurable app-exclusion list (by `NSWorkspace.frontmostApplication` bundle id), an option to auto-drop clips from known password managers/Keychain, a heuristic to skip likely-secret high-entropy short strings, and honor `org.nspasteboard.AutoGeneratedType`.

### H7. add() does O(n) full sort and full tagIndex rebuild on every single copy
- **File:** `Sources/Cliphoard/Clipboard/ClipStore.swift:74-80, 87-94, 228-233`.
- **Evidence:** `add()` ends with `items.insert(item, at: 0); trim(); sortStable(); rebuildTagIndex()`. `sortStable()` sorts the whole array; `rebuildTagIndex()` iterates every item × every tag to rebuild the `[Int:[ClipItem]]` map. The dedup-bump path also calls `move`→`sortStable()`. `togglePin`/`delete`/`clearUnpinned`/`markUsed` also rebuild. `historyLimit` can be `0` (Unlimited), so n is unbounded.
- **Impact:** Per-copy cost is O(n log n) sort + O(n·tags) rebuild on the main actor for one new item. At 10k clips × ~5 tags that is ~50k map appends plus a 10k-element sort on every copy.
- **Recommendation:** Maintain the index incrementally (append to tag buckets on add, remove on delete; full rebuild only on model/basket change). Replace the always-full sort with an insertion at the correct position (order is determined by pinned + lastUsedAt). Use Sets/ids in `tagIndex` to avoid O(n) removal scans.

### H8. Full-resolution images decoded inside the SwiftUI card body — no thumbnailing or caching
- **File:** `Sources/Cliphoard/UI/ClipCardView.swift:74-81`; `Sources/Cliphoard/Clipboard/ClipboardMonitor.swift:113-120` (persist).
- **Evidence:** Card body does `NSImage(contentsOf: storeDir.appendingPathComponent(file))` for `.image` clips, no `NSCache`/thumbnail, into a fixed `Theme.cardWidth × cardHeight` frame. `persistImage` writes the original full-resolution PNG (tiff→bitmap→PNG, no downsampling). Each body re-evaluation (selection, hover via `@State hovering`, search keystroke) re-decodes the on-disk PNG.
- **Impact:** A 4K/Retina screenshot is a multi-MB PNG decoded entirely into RAM on each card appearance/re-evaluation. A `LazyHStack` realizes several image cards at once, each a full-res decode; scrolling + re-renders on every keystroke cause repeated decodes and memory spikes/stutter. (LazyHStack limits to roughly the visible window, not all 10k.)
- **Recommendation:** Generate/store a downsampled thumbnail at persist time (`CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceThumbnailMaxPixelSize` ≈ card size); render that in the card; load full-res only on paste. Cache decoded thumbnails in an `NSCache` keyed by `payloadFile` instead of decoding in `body`.

### H9. `results` recomputed multiple times per body pass and per keystroke; Essence dot-products every vector each time
- **File:** `Sources/Cliphoard/UI/PanelViewModel.swift:46-67, 73-121`; `Sources/Cliphoard/UI/ContentView.swift:125,158,240`; `Sources/Cliphoard/Search/DeepSearch.swift:310-321,302-307`.
- **Evidence:** `results` is a plain computed property (no memoization). ContentView reads it in `cards` (125), in `onChange(of: store.lastAddedID)` (158), and twice in `footer` (240). `moveSelection`, `click`, `commitSelection`, `copySelection`, `deleteSelection`, `pinSelection`, `quickSelect` each read it again. For `.essence`, each evaluation calls `SemanticRanker.essence`, mapping over every scoped item computing `cosine()` (scalar dot product) + a lowercased substring scan, then sorting the full list. `PanelViewModel.objectWillChange` re-fires on every `store.objectWillChange` (41-43).
- **Impact:** A single body pass triggers several full re-runs of search; at 10k clips in Essence mode that is tens of thousands of scalar dot products recomputed several times per pass and again per keystroke/arrow key — pinning a CPU core on the main actor and making Essence janky at scale.
- **Recommendation:** Memoize `results` keyed by (query, activeKind, pinnedOnly, mode, store revision); compute once per update and pass the array down. For Essence, precompute a contiguous `[[Float]]` matrix and use vDSP/Accelerate, with a top-K heap instead of a full sort.

### H10. Failed/empty CoreML embedding is cached as a valid embedding and never re-tried
- **File:** `Sources/Cliphoard/Search/DeepSearch.swift:154-185, 266-276`; `Sources/Cliphoard/Clipboard/ClipItem.swift:76`.
- **Evidence:** `OgmaEmbedder.run` returns `[Float](repeating: 0, count: dimension)` on all three failure paths (MLMultiArray alloc fail 161, prediction throw 173, missing "embedding" output 177). `ClipIndexer.index` stores it unconditionally: `item.embeddings[signature] = ModelEmbedding(vector: vec, tags: tags)` (270). Staleness is purely key presence (`isEmbedded` = `embeddings[signature] != nil`; `isStale = !isEmbedded`), so a zero-vector entry counts as embedded and `reindexStale()` filters it out forever. `TagSpace.classify` guards only `vector.isEmpty`, not all-zeros.
- **Impact:** A transient model failure persists a zero vector as Float16 to SQLite. The clip is now "embedded" and never reprocessed; its tags are garbage, it vanishes from Tag search, and in Essence `cosine(q,0)=0` ranks it below threshold. Durable, self-perpetuating corruption across launches with no recovery short of deleting the clip.
- **Recommendation:** Treat a zero/empty vector as failure — have `run()` return `[]` on error, have `index()` skip caching when `vec.isEmpty` (leaving the item stale for retry), and have `isStale` also return true when the cached vector is all-zeros or wrong length for the active dimension.

### H11. SQLite write failures are swallowed while the in-memory store has already mutated — silent memory/disk divergence
- **File:** `Sources/Cliphoard/Clipboard/Database.swift:109,122,132,138,149-151,155-166`; `Sources/Cliphoard/Clipboard/ClipStore.swift:59-81,169-196`.
- **Evidence:** Every write helper discards `sqlite3_step`'s return (insert 109, updateMeta 122, upsertEmbedding 132, delete 138). `exec()` only NSLogs (155-159). `prepare()` NSLogs and returns **without** calling `body` on prepare failure — silently skipping the write (161-166). `transaction()` runs `BEGIN; body(); COMMIT;` with no error check and no `ROLLBACK`. ClipStore mutates `items` first then calls `db?.…` with no success check (add 74-80, togglePin 169-173, markUsed 191-196, delete, clearUnpinned).
- **Impact:** On any write failure (disk full, WAL/locked contention, read-only DB, corruption), the UI shows the change for the session but `loadAll()` reverts it next launch. A pinned clip the user trusted to persist silently vanishes; a "cleared" history can reappear; `transaction()` can COMMIT a partially-applied batch with no rollback. Core durability promise broken.
- **Recommendation:** Have write helpers return Bool/throw on `sqlite3_step != SQLITE_DONE` and on prepare failure; surface failures to ClipStore so it can warn the user or refuse the optimistic mutation. Wrap `transaction()` in a do/rollback path; COMMIT only on success.

### H12. Only install path is clone + Swift toolchain + Xcode — excludes all non-technical users
*(Adjudicated High, down from critical: same root cause as C1 viewed from the install angle, so not double-counted as critical.)*
- **File:** `README.md` (Build & run); `Makefile`; `Scripts/build-app.sh`.
- **Evidence:** README requires macOS 13+ and the Swift toolchain (Xcode 15+), then `git clone … && make run`; Makefile `app:` compiles via `swift build -c release`. No GitHub Releases / `.dmg` / download link; `build/` and `*.icns` are gitignored so no artifact is checked in.
- **Impact:** A wide (non-technical) userbase has no way to obtain a runnable Cliphoard. The target persona for a menu-bar clipboard manager (compare Paste's notarized `.dmg`) cannot install from source.
- **Recommendation:** Ship a notarized, stapled `.dmg`/`.zip` via GitHub Releases with drag-to-Applications instructions; keep build-from-source as a secondary developer path.

---

## MEDIUM

### M1. Actor-reentrancy: poll-timer add() can mutate items/embeddings while a reindex/reclassify loop is suspended at await
- **File:** `Sources/Cliphoard/Clipboard/ClipStore.swift:109,127,141,161`; `Sources/Cliphoard/Clipboard/ClipboardMonitor.swift:29-37`.
- **Evidence:** `reindexStale`/`reclassifyAllTags` capture a snapshot (`stale`/`targets`) then `await Task.yield()`. At each suspension the separately-scheduled poll timer can run `store.add` → `trim` (db.delete + `items.removeAll`) and `ClipIndexer.index`. The loop resumes against the stale snapshot and can re-embed/upsert an item `trim()` already removed. (Mitigated: the embeddings table has `FOREIGN KEY(clip_id)` with `PRAGMA foreign_keys = ON`, so an upsert for a deleted clip fails the FK rather than orphaning a row; and `index()` runs fully synchronously so each `embeddings`-dict mutation is atomic on the cooperative actor — no torn writes, only coarse interleaving. Newly-added items are embedded by `add()` itself, so the collision is with trim/delete of *older* items.)
- **Impact:** Inconsistent state and wasted work: the reindex loop re-embeds/attempts upsert for items removed by add()/trim(); both passes can call `rebuildTagIndex()` and write `indexing` interleaved. No corruption (FK blocks the orphan), but coarse interleaving across whole operations.
- **Recommendation:** Pause the poll timer (or queue captured clips) during a reindex/reclassify pass, or re-validate `items.contains(item)` after each yield before writing. Better: serialize indexing through one owned Task and diff against current `items` on resume.

### M2. No guard against concurrent/overlapping reindex and reclassify passes
- **File:** `Sources/Cliphoard/Clipboard/ClipStore.swift:113/131, 146/165`; triggers in `SettingsView.swift:27,33,45`, `AppDelegate.swift:30`.
- **Evidence:** Neither pass stores or checks an in-flight Task; each unconditionally `Task { @MainActor in … }` and both drive the single `@Published indexing` (set at 113/146, cleared to nil at 131/165). Triggers fire back-to-back: `deepSearchLevel.didSet → configureAndReindex → refreshForActiveModel → reindexStale`, `activeBasket.didSet → reclassifyAllTags`, `applyCustomTags → reclassifyAllTags`, launch `configureAndReindex`.
- **Impact:** Two interleaved passes both set/clear `indexing` (one's `nil` ends the other's progress early — flicker, done>total, premature finish), both upsert embeddings and rebuild the tag index — wasted CoreML work. Cosmetic + wasteful; no crash/corruption.
- **Recommendation:** Store the in-flight indexing Task; cancel-and-replace (or coalesce) on a new request and check `Task.isCancelled` in the loop. Make `indexing` ownership belong to exactly one live pass.

### M3. No tokenizer parity test exists despite "validated bit-for-bit" claim
- **File:** `Sources/Cliphoard/Search/OgmaTokenizer.swift:11`.
- **Evidence:** Comment claims reference-id parity. Grep across `Tests/` finds zero references to `OgmaTokenizer`/`encode`/the golden ids; the only `encode` hit is an unrelated `JSONEncoder().encode`. `reference.json` exists but is consumed only by the Python flow; no `tokenizer.json` is checked into the repo. (Assurance gap, not itself a runtime defect — amplifies H3.)
- **Impact:** The most failure-prone component (hand-rolled Viterbi + offset + normalizer claiming exact parity) has no automated guard; any regression ships undetected and permanently poisons stored vectors keyed by signature.
- **Recommendation:** Add a Swift test loading a checked-in `tokenizer.json` fixture asserting `encode` produces exactly `reference.json` ids for all sample strings, including CLS=9/SEP=10 offset boundaries.

### M4. High (EmbeddingGemma) tier loads an ogma Unigram tokenizer for a model that does not use one
- **File:** `Sources/Cliphoard/Search/DeepSearch.swift:32,201-207`.
- **Evidence:** `configure()` unconditionally builds `OgmaTokenizer(folder: "<name>-tokenizer")` for any non-nil modelName including `.high`'s `"embeddinggemma-300m"`; no model-family guard. OgmaTokenizer hardcodes the ogma normalizer (NFKD→strip-accents→lowercase), `▁` metaspace, and `n_special_tokens` offset — none matching Gemma. (Latent: requires BOTH the Gemma `.mlmodelc` AND tokenizer folder bundled; Gemma is gated/not converted today, so the path currently falls back to HashingEmbedder and cannot mis-tokenize.)
- **Impact:** If a Gemma bundle is ever added, OgmaTokenizer emits garbage `input_ids` under ogma's rules and the "high" tier's embeddings are meaningless but persisted and trusted.
- **Recommendation:** Gate `OgmaTokenizer` to ogma model names or abstract tokenizer construction per tier; require a Gemma-specific tokenizer. Until then, fall back to HashingEmbedder for `.high` rather than mis-tokenizing.

### M5. Normalizer is hardcoded instead of derived from tokenizer.json's declared normalizer
- **File:** `Sources/Cliphoard/Search/OgmaTokenizer.swift:63-73`.
- **Evidence:** `init?()` reads only `model.vocab`, `unk_id`, and `n_special_tokens`; it never parses the `normalizer`/`pre_tokenizer` sections. `normalize()` applies a fixed chain including the SentencePiece/T5-ism `` `` ``→`"` and `''`→`"` replacements with no basis in the loaded JSON. Both ogma-micro and ogma-small load through this class with the same hardcoded chain.
- **Impact:** Silently assumes ogma-small's exact normalizer. If ogma-micro or a future revision declares a different normalizer (NFKC vs NFKD, no accent-strip, precompiled_charsmap), `encode()` diverges from training-time tokenization with no error.
- **Recommendation:** Parse/honor the declared `normalizer`/`pre_tokenizer` (Replace/NFKD/NFKC/Lowercase/StripAccents/Metaspace), or assert at load time that the declared normalizer matches the hardcoded assumptions and refuse to load otherwise.

### M6. Tag classification mixes DOC-space ingest with QRY-space tag search — asymmetric geometry mismatch
- **File:** `Sources/Cliphoard/Search/DeepSearch.swift:241,256,268-269`.
- **Evidence:** `TagSpace.vectors` embeds tag names DOC (241); `ClipIndexer.index` embeds items DOC and classifies vs DOC tag vectors (DOC↔DOC, symmetric). `nearestTag` embeds the query QRY (256) vs the same DOC tag vectors (QRY↔DOC, asymmetric). ogma uses Task qry=4/doc=5, so the two paths operate in different cross-task geometries; HashingEmbedder is symmetric so tests never exercise the divergence. (Impact plausible but not demonstrated — asymmetric retrieval models are trained so a QRY embedding lands near correct DOC neighbors, so nearest-tag identity may be preserved.)
- **Impact:** Tag-search and ingest tagging can disagree on which tag a concept maps to, so tag-mode search may return the wrong O(1) bucket on ogma models.
- **Recommendation:** Make task-token usage consistent (embed tag names per task space, or verify QRY/DOC preserves nearest-tag identity). Add an integration test on an ogma/asymmetric stub asserting ingest-tag == query-tag for representative inputs.

### M7. Unaligned `bindMemory(to: Float16.self)` on Data bytes is undefined behavior
- **File:** `Sources/Cliphoard/Clipboard/Database.swift:204-211`.
- **Evidence:** `vectorFromBlob` does `data.withUnsafeBytes { raw in let buf = raw.bindMemory(to: Float16.self); … }`. `bindMemory`+typed subscript require 2-byte alignment; the Swift pointer model treats violation as UB. (In practice `Data(bytes:count:)` copies into fresh malloc'd storage which is ≥16-byte aligned, so it does not actually misalign/trap on arm64/x86_64 — latent-UB/portability defect, not active corruption.)
- **Impact:** A future toolchain/optimizer could legitimately miscompile or trap; the read is correct today only by allocator luck.
- **Recommendation:** Use `raw.loadUnaligned(fromByteOffset: i*2, as: Float16.self)` per element, or copy into `[Float16]` via `copyMemory`, instead of `bindMemory`.

### M8. insert() writes clip row and embeddings without a wrapping transaction
- **File:** `Sources/Cliphoard/Clipboard/Database.swift:89-112`.
- **Evidence:** One auto-committed prepare/step for the clip row, then `for (model, emb) in item.embeddings { upsertEmbedding(...) }` each auto-committed, no enclosing transaction (`transaction()` exists but is used only by `delete(ids:)` and migration). (Mitigated: a clip with missing embeddings still loads cleanly with an empty dict, and `isStale` marks it stale so `reindexStale` re-embeds it from text — self-healing for text/link/color clips; defect is the atomicity gap + N fsyncs per capture, recoverable consequence.)
- **Impact:** A crash between the clip INSERT and embedding upserts leaves a clip with missing/partial embeddings; in WAL+default-synchronous each statement is a separate commit, multiplying fsync cost per capture.
- **Recommendation:** Wrap the row insert + all `upsertEmbedding` calls in a single `transaction { … }` so the clip and its embeddings commit atomically.

### M9. Database holds raw SQLite pointers with no actor isolation, protected only by convention
- **File:** `Sources/Cliphoard/Clipboard/Database.swift:8-10,37`.
- **Evidence:** `final class Database` is not `@MainActor` and carries no Sendable/isolation annotation; it holds `private var db: OpaquePointer?` and `deinit { sqlite3_close(db) }`, with the header asserting "All access is on the main actor … so no extra locking." Safety is enforced only by prose. (Conditional: every caller is `@MainActor` today, so no current race — the hazard materializes the moment embedding/DB work moves off-main, which is the natural fix for H1.)
- **Impact:** The "no locking" invariant is invisible to the type system; moving DB work off-main (the recommended H1 fix) silently creates a data race / use-after-free on the shared connection with no compiler diagnostic.
- **Recommendation:** Annotate `Database` as `@MainActor` (compiler-enforced isolation) or wrap it in its own actor/serial queue. Do not leave SQLite thread-safety as a prose comment.

### M10. vectorFromBlob image-persist/payload-delete failures and missing payloads — silent dangling/missing payloads
*(Robustness #5.)*
- **File:** `Sources/Cliphoard/Clipboard/ClipboardMonitor.swift:113-120,93-99`; `Sources/Cliphoard/Clipboard/ClipStore.swift:235-239`; `Sources/Cliphoard/Clipboard/Paster.swift:19-23`.
- **Evidence:** `persistImage` returns nil on conversion/write failure; `capture()` still returns the image clip with `payloadFile==nil`. `Paster.writeToPasteboard` guards `if let file …, let image = NSImage(contentsOf:)` and on failure does nothing after `clearContents()` — a silent no-op paste, with `ClipCardView` showing the placeholder. `removePayload` uses `try? removeItem` and is the only deletion path keyed off live clips, so a failed remove orphans the PNG forever.
- **Impact:** (a) PNG write failure (disk full/permissions) stores an unpastable image clip with no user feedback. (b) Failed `removeItem` leaks orphaned PNGs in Application Support indefinitely.
- **Recommendation:** If `persistImage` fails, drop the image clip (don't store an unpastable entry) or surface an error. Log payload-deletion failures; add a startup sweep removing `*.png` with no matching clip id.

### M11. No accessibility annotations — bar is hard to use under VoiceOver
- **File:** `Sources/Cliphoard/UI/ClipCardView.swift` (whole file); `Sources/Cliphoard/UI/ContentView.swift` (whole file).
- **Evidence:** Grep for `accessibilityLabel|accessibilityHint|accessibilityElement|accessibilityValue|accessibility(` returns nothing. Cards are Image/Text fragments with no combined label; the search field has no label; icon-only buttons (gear ContentView.swift:68-76, sound play in SettingsView) use only `.help(...)` tooltips, which VoiceOver does not surface as control names. (Slightly softened from "largely opaque": SwiftUI synthesizes default accessibility — Buttons read "button", Text reads its string, TextField is reachable — so the surface is unlabeled/piecemeal rather than invisible.)
- **Impact:** VoiceOver users get anonymous icon-only buttons and card fragments read piecemeal; an accessibility/usability gap on the core surface.
- **Recommendation:** Add `.accessibilityElement(children: .combine)` + `.accessibilityLabel`/`.accessibilityHint` to each ClipCardView (kind, source app, preview, index, pinned state); label the search field and all icon-only buttons; expose selection via `.accessibilityAddTraits(.isSelected)`.

---

## LOW

### L1. Database opened without SQLITE_OPEN_FULLMUTEX while assuming serialized access
- **File:** `Sources/Cliphoard/Clipboard/Database.swift:14,18`. `sqlite3_open_v2` with only `READWRITE|CREATE`, WAL enabled, no FULLMUTEX/NOMUTEX. Benign today (main-actor-serialized); reinforces M9. **Rec:** if access stays main-actor-only, enforce isolation in Swift; if moved off-main, open with FULLMUTEX or route through one serial queue/actor.

### L2. Carbon hotkey / Darwin-notification C callbacks rely on `takeUnretainedValue` + manual main-dispatch
- **File:** `Sources/Cliphoard/App/HotKey.swift:28-29,36-41`; `Sources/Cliphoard/App/AppDelegate.swift:41-59`. Untyped main-actor bridge via `DispatchQueue.main.async` with unretained pointers; safe in practice (AppDelegate retained for app life via `objc_setAssociatedObject`, HotKey unregisters in deinit). **Rec:** prefer `MainActor.assumeIsolated` inside the dispatched block; document lifetime requirements.

### L3. No busy_timeout / synchronous pragma; deinit uses sqlite3_close with no WAL checkpoint
- **File:** `Sources/Cliphoard/Clipboard/Database.swift:18-19,37`. Only `journal_mode=WAL` and `foreign_keys=ON`; `deinit` is non-`_v2` close, no `wal_checkpoint`. Low-impact in a single-process main-actor store (statements finalized via `defer`; SQLite folds WAL on next open). **Rec:** add `busy_timeout=5000`, explicit `synchronous=NORMAL`, use `sqlite3_close_v2`, and `wal_checkpoint(TRUNCATE)` on clean shutdown.

### L4. Float16 BLOB round-trip is lossy/saturating; blob length not validated
- **File:** `Sources/Cliphoard/Clipboard/Database.swift:199-206`. `v.map { Float16($0) }` with no clamp (|v|>65504 → ±inf); `count = data.count / stride` integer-divides so an odd-length blob drops the trailing byte. Undercut by the documented invariant that the model already runs in Float16 (round-trip lossless for in-range values). **Rec:** validate blob length % stride == 0 (skip/log non-conforming); document the Float16-range assumption.

### L5. PNG payload sidecars can be orphaned on DB-level deletes — no reconciliation sweep
- **File:** `Sources/Cliphoard/Clipboard/ClipStore.swift:235-239`; `Sources/Cliphoard/Clipboard/Database.swift:32`. FK cascade only covers the embeddings row; PNG cleanup lives only in `removePayload`. (No current path actually leaks — `delete`/`clearUnpinned`/`trim` all call `removePayload` before `db?.deleteUnpinned()`; the cited scenarios are hypothetical future/external deletes.) **Rec:** add a startup orphan-sweep over `*.png` vs `SELECT id FROM clips`, or centralize all deletes.

### L6. Per-model embedding comparability hinges on signature uniqueness (name+dimension only)
- **File:** `Sources/Cliphoard/Search/DeepSearch.swift:101,148,303,314`. Signature is `"<modelName>-<dimension>"`; `cosine` guards only `count` equality; `isStale` checks only key presence. (Currently won't collide — ogma-micro is 128-dim, ogma-small 256-dim; "hashing-256" vs "ogma-small-256" are distinct strings. Only triggers on re-converting a model under the same name+dim without bumping the signature.) **Rec:** include a weight/tokenizer fingerprint or version in the signature so any model change invalidates stale vectors.

### L7. vectorFromBlob wrong-length vectors score 0 in cosine instead of being flagged
- **File:** `Sources/Cliphoard/Clipboard/Database.swift:204-211`; `Sources/Cliphoard/Search/DeepSearch.swift:303,314`. A present-but-wrong-length vector is used as-is; `cosine` returns 0 on count mismatch with no log; `essence` re-embeds only when nil. Narrow triggers (BLOB corruption or a build-time dimension mismatch). **Rec:** validate vector length vs active `embedder.dimension` on load; on mismatch treat as stale and re-embed; log it.

### L8. Unigram Viterbi UNK fallback uses a hardcoded `unkScore = -25`, not the model's value
- **File:** `Sources/Cliphoard/Search/OgmaTokenizer.swift:18,86-98`. Real pieces use `entry.score`; the UNK fallback uses the literal `-25` instead of reading `unk_score` from config, changing which segmentation wins for OOV-adjacent strings (urls, base64, hashes). Rarely fires for clean in-vocab text. **Rec:** read the real unk score from tokenizer.json/config; add OOV strings to the parity test.

### L9. HashingEmbedder fallback ignores query/document distinction (test-coverage gap)
- **File:** `Sources/Cliphoard/Search/DeepSearch.swift:91-93,99-129`. Protocol default `embed(_:query:){ embed(text) }` is inherited; correct for the symmetric hashing model but means the asymmetric QRY/DOC paths are never exercised in the default/fallback config or the test suite (all tests use HashingEmbedder), masking M6's behavior. **Rec:** add a test driving an asymmetric embedder stub through index/classify/essence.

### L10. Dedup-bump persists recency but not a re-embedding; updateMeta omits embeddings
- **File:** `Sources/Cliphoard/Clipboard/ClipStore.swift:61-66`; `Sources/Cliphoard/Clipboard/Database.swift:115-124`. On a consecutive duplicate, sets `lastUsedAt`, calls `updateMeta` and returns early — never runs the indexer; `updateMeta` writes only kind/last_used_at/pinned/use_count. A re-copied item captured while `DeepSearch.level == .off` stays unembedded on the dedup path (self-healing via `reindexStale`). **Rec:** on dedup-bump, if `ClipIndexer.isStale(existing)` run the indexer and upsert before returning.

### L11. Up/Down arrows are intercepted but do nothing — dead keys
- **File:** `Sources/Cliphoard/App/AppDelegate.swift:248-249`. `case kVK_DownArrow, kVK_UpArrow: return nil` swallows the events (blocks fall-through) with no action — silent no-op feels like a freeze. **Rec:** map Up/Down to `moveSelection(-1)/(+1)` aliases, or remove the case so events fall through to the text field/scroll view.

### L12. Keyboard navigation gated on `panel.isKeyWindow`, which may be false after slideIn
- **File:** `Sources/Cliphoard/App/AppDelegate.swift:153-156`; `Sources/Cliphoard/UI/FloatingPanel.swift:42,68-84`. The local key monitor guards `self.panel.isKeyWindow else { return event }`, so `handleKey` runs only when the panel is key. (Materially mitigated: `show()` calls `NSApp.activate(ignoringOtherApps:true)` before `slideIn`, `slideIn` calls `makeKeyAndOrderFront`, and the panel overrides `canBecomeKey { true }`; SPEC rates this exact concern H2/medium. Residual risk is intermittent/timing-dependent.) **Rec:** gate on `panel.isVisible` (the panel is the only on-screen surface when shown), or force/confirm key status after the animation.

### L13. Distribution / build-hygiene low-severity cluster
- **No localization / i18n** — `Sources/Cliphoard/UI/SettingsView.swift`, `AppDelegate.swift`, `Info.plist`. All user-facing strings hardcoded English; no `NSLocalizedString`/`String(localized:)`, no `.lproj`. Real future-scaling limit, not release-blocking for the English-dominant macOS base. **Rec:** wrap strings in `String(localized:)`, add base `Localizable.strings` + `InfoPlist.strings`.
- **Stable-signing requires a keychain-modifying script** — `Scripts/setup-signing.sh`. `security import … -A` exposes the key to all apps; may prompt for the login password. Developer-workflow only; never run by end users. **Rec:** make the notarized Developer-ID release the primary path; drop `-A` in favor of `-T /usr/bin/codesign`.
- **Single-arch binary; CoreML compute units unset** — `Scripts/build-app.sh:11`; `DeepSearch.swift:202-206`. `swift build -c release` with no `--arch`/`lipo`, so non-universal; `MLModel(contentsOf:)` uses default `MLModelConfiguration`. Mostly subsumed by C1/H12 (no artifact at all). **Rec:** produce a universal binary for releases; validate the `.mlmodelc` loads on both architectures.
- **Global Darwin notifications let any local process control the app** — `Sources/Cliphoard/App/AppDelegate.swift:40-59`. Observers for `ai.axiotic.ditto.toggle/.embedtest/.opensettings` on the unauthenticated Darwin notify bus; no data exfil. **Rec:** gate `embedtest`/`opensettings` behind `#if DEBUG`; the hotkey toggle does not need a world-postable name.
- **Default build is ad-hoc signed** — `Scripts/build-app.sh:64-71`. Fresh code identity per build drops the AX grant each rebuild; no hardened runtime/notarization. **Rec:** default to the stable self-signed identity; prefer Developer ID + hardened runtime + notarization (see C1).
- **DebugLog overwrites the log on first-write / handle-open failure** — `Sources/Cliphoard/Support/Feedback.swift:53-64`. The `else` branch does `try? data.write(to:)` which truncates the whole file; opt-in debug-only. **Rec:** create-then-append; only create when the file is genuinely absent.
- **Clip-derived token ids leak into the unified log via NSLog** — `Sources/Cliphoard/Search/DeepSearch.swift:172,182`. First 8 token ids logged on prediction failure / with debug on; lossy, partial, rare. **Rec:** log only counts/shapes; use `os_log` with `privacy:.private`.
- **Legacy-JSON migration archive failure can re-import history** — `Sources/Cliphoard/Clipboard/ClipStore.swift:255-279`. `try? moveItem` to `history.migrated.json` swallowed; if it fails and the DB is later empty, JSON is re-imported, resurrecting cleared history. **Rec:** check the move result; use a UserDefaults "migrated" marker instead of the file-rename + empty-db heuristic.
- **Database init failure → silent in-memory-only store** — `Sources/Cliphoard/Clipboard/ClipStore.swift:37,47-49`. `db==nil` makes every `db?.` a no-op; app runs but nothing persists, no user signal. **Rec:** surface a one-time alert/menu-bar warning; consider retrying with a fresh DB filename if the file is corrupt.
- **Reindex/reclassify Tasks ignore embedding failures and persist whatever the embedder returned** — `Sources/Cliphoard/Clipboard/ClipStore.swift:107-134,139-167`. Composition of H10 + H11; small incremental severity. **Rec:** skip caching/upsert on empty/zero vectors; update the in-memory tagIndex only from successfully persisted embeddings.
- **Reindex/reclassify rebuild the full tag index every 8/16 items** — `Sources/Cliphoard/Clipboard/ClipStore.swift:114-134,147-167`. `rebuildTagIndex()` is O(n·tags); over a 10k reindex that's ~1250 rebuilds → O(n²) on the main actor. Background/occasional pass. **Rec:** update the tag index incrementally as each item is reclassified.
- **Clipboard poll allocates type-list string before skip checks** — `Sources/Cliphoard/Clipboard/ClipboardMonitor.swift:56-57`. Built unconditionally for any real change (the changeCount guard at line 53 already returns early before this), even when the change is then skipped or logging is disabled. **Rec:** build the string lazily only when `DebugLog.enabled`; move skip checks ahead of any allocation.
- **Selected chip uses hardcoded `Color.white` on a user-customizable accent** — `Sources/Cliphoard/UI/ContentView.swift:112-114`; `Theme.swift:8`. White text on a light system accent (Yellow/Green) is low-contrast. (macOS accents are vibrant, so practical illegibility is limited to the lightest accents.) **Rec:** use a luminance-aware foreground or a fixed brand accent for the fill.
- **Rebuilding NSHostingController on every present discards SwiftUI @State / re-instantiates AppSettings** — `Sources/Cliphoard/UI/FloatingPanel.swift:48-65`; `AppDelegate.swift:170`. (This is the deliberate, documented fix for the stale-render bug; resetting transient state per summon is desirable; AppSettings.init is cheap. Only residual is a possible one-frame relayout.) **Rec:** optional — keep one persistent controller and drive updates via the existing `store.objectWillChange` republish; hoist AppSettings to a single AppDelegate-owned instance.
- **Fixed point sizes / no Dynamic Type response** — `Theme.swift:6-7`; `FloatingPanel.swift:8`; `ClipCardView.swift:26,117-119`. (Largely refuted on macOS: no iOS-style system Dynamic Type rescales `.system(size:)` fonts, so the overflow/clip scenario does not occur; residual is only that fixed 10–12pt is non-ideal for low-vision users.) **Rec:** prefer relative fonts (`.caption`/`.body`) and `@ScaledMetric` for card/panel dimensions where practical.

---

## Appendix — Refuted / downgraded by the adversary (and why)

No finding was struck outright (every finding was `confirmed=true`). The adversary **downgraded** the following; the corrected (lower) severities are used above. Material walk-backs of impact:

- **Tokenizer parity test missing** (high→**medium**): assurance/test-coverage gap, not a shipping runtime defect on its own — amplifies H3 but produces no wrong output itself.
- **High/EmbeddingGemma tier mis-tokenizes** (high→**medium**): latent — requires a Gemma `.mlmodelc` + tokenizer bundled, which is gated/absent today; currently falls back to HashingEmbedder and cannot mis-tokenize.
- **Actor reentrancy** (high→**medium**): "orphan embedding row" refuted by the FK constraint + `PRAGMA foreign_keys=ON` (upsert fails, no usable orphan); "torn dict write" refuted by synchronous, cooperative (non-preemptive) `index()`; collision is with older trimmed items, not freshly-added ones.
- **Unaligned `bindMemory`** (high→**medium**): real latent UB, but `Data(bytes:count:)` copies into ≥16-byte-aligned malloc storage, so it does not misalign/trap in practice — "corrupts all cached embeddings" overstated.
- **insert() not transactional** (high→**medium**): missing embeddings are self-healing via `isStale`/`reindexStale` for text/link/color clips — recoverable, not permanent loss.
- **Database isolation by convention** (medium→**low**) and **no busy_timeout/FULLMUTEX** (medium→**low**): no current race — single-process main-actor store; hazard is forward-looking, materializing only if DB work moves off-main.
- **Float16 lossy/saturating** (medium→**low**): undercut by the documented invariant that the model already runs in Float16 (in-range round-trip is lossless).
- **PNG orphan sidecars** (medium→**low**): no current path actually leaks — every real delete path calls `removePayload`; scenarios are hypothetical.
- **Per-model signature collision** (medium→**low**): cannot collide today (ogma-micro 128-dim vs ogma-small 256-dim; distinct signature strings); needs a manual re-conversion misstep.
- **Search not first responder** kept **high**, but "keys always lost" softened — `NSApp.activate(ignoringOtherApps:true)` improves key-window odds; the defect is that nothing focuses the field, intermittently failing.
- **Keyboard nav gated on isKeyWindow** (high→**low/medium**): heavily mitigated by `activate()` + `makeKeyAndOrderFront` + `canBecomeKey { true }`; SPEC itself rates it medium; most likely the panel does become key.
- **No accessibility / "largely opaque"** (high→**medium**): SwiftUI synthesizes default accessibility for standard controls — unlabeled/piecemeal, not invisible.
- **Fixed point sizes / Dynamic Type ignored** (high→**low**): the clipping/overflow harm is essentially refuted on macOS, which has no system Dynamic Type that rescales `.system(size:)` fonts.
- **NSHostingController rebuild** (medium→**low**): the deliberate, documented stale-render fix; resetting transient state per summon is desirable; no functional bug.
- **Hardcoded white-on-accent** (medium→**low**) and **NSLog token-id leak** (medium→**low**): macOS accents are vibrant (only lightest are low-contrast); the id leak is partial/lossy/rare and behind the error path.
- **Headline semantic search degrades to hashing** (high→**medium**): default `searchMode` is `exact` (substring), so the out-of-box experience does not depend on embeddings; the fallback is disclosed in README and Settings copy.
- **EmbeddingGemma tier selectable but non-functional** (high→**medium**): the picker is disabled while `searchMode == .exact` (the default), so the broken tier is reachable only by users who already opted into semantic search.
- **CC-BY-NC vs MIT license conflict** (high→**medium**): conditional/latent — no shipped artifact bundles the NC weights today; MIT (code) vs CC-BY-NC (weights) are separable artifacts, so it is a documentation/attribution gap, not an automatic violation.
- **Install path = clone only** (critical→**high**): same root cause as C1, so not double-counted as critical.
- **i18n, signing-script, single-arch, Darwin notifications, ad-hoc signing** all downgraded to **low** as developer-workflow or future-scaling concerns rather than wide-userbase blockers.
