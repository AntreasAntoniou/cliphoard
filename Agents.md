# Ditto — Agents.md (navigation map)

> A native, open-source macOS menu-bar **clipboard manager**. Press **⌃⌥⌘V** and a
> borderless `NSPanel` slides up from the bottom of the active screen showing your
> clipboard history as a horizontal strip of cards; pick one and Ditto writes it
> back to the pasteboard and simulates ⌘V into the app you were using. Built only
> on Swift + AppKit + SwiftUI + Carbon + `sqlite3` (no Electron, no network, no
> account, no telemetry). History persists in a **SQLite** DB (`ditto.sqlite`,
> WAL) with image payloads as PNG sidecars. Beyond exact substring search it does
> fully **on-device semantic search** ("Tag" and "Essence" modes) via CoreML
> embedding models (`axiotic/ogma-micro`/`ogma-small`), with a dependency-free
> `HashingEmbedder` fallback so search always works. The whole app is `@MainActor`;
> `ClipStore` is the single source of truth and the UI is a projection of it.

> Note: the repo's `SPEC.md` describes an **earlier** JSON-sidecar version and does
> not mention deep search, SQLite, the in-bar Settings surface, plain-text paste,
> or copy-without-paste. This document reflects the **current source**. Where the
> SPEC and code disagree, the code wins.

---

## 1. Directory / file map (path → responsibility)

### App entry & wiring — `Sources/Ditto/App/`
| Path | Responsibility |
| --- | --- |
| `App/Main.swift` | `@main struct Main`. Builds `NSApplication`, sets `AppDelegate` as delegate, `setActivationPolicy(.accessory)` (no Dock icon), retains the delegate via `objc_setAssociatedObject(app, "dittoDelegate", …)`, then `app.run()`. Struct (not `main.swift`) to avoid the top-level-code vs `@MainActor` conflict under SwiftPM. |
| `App/AppDelegate.swift` | The conductor (`@MainActor`, `NSApplicationDelegate`, `NSMenuDelegate`). Owns `store`/`monitor`/`model`/`panel`/`hotKey`/`statusItem`. `applicationDidFinishLaunching` wires the status item, panel, hotkey, Darwin remote toggles, calls `EmbedderProvider.configureAndReindex`, and `monitor.start()`. Builds the status menu (`rebuildMenu`/`menuNeedsUpdate`), handles keyboard (`handleKey`), and runs the paste flow (`show`/`hide`/`commit`/`copyToClipboard`). |
| `App/HotKey.swift` | `final class HotKey`. Registers the global shortcut via Carbon `RegisterEventHotKey` + an `InstallEventHandler` on `GetApplicationEventTarget()`. Hotkey id signature `0x4454_4f48` ('DTOH'). `onPressed` callback dispatched to main. Carbon is used as the only reliable no-entitlement system-wide shortcut API. |

### Clipboard core — `Sources/Ditto/Clipboard/`
| Path | Responsibility |
| --- | --- |
| `Clipboard/ClipItem.swift` | `enum ClipKind {text,link,color,image,file}` (with `symbolName`/`title`) and `final class ClipItem: Codable, Identifiable` — the history entry. Also `struct ModelEmbedding {vector:[Float]; tags:[Int]}`. Reference type; `kind` is now **mutable** (the embedder can promote text→link). Holds `embeddings: [String: ModelEmbedding]` (per-model cache keyed by embedder signature) plus legacy `vector`/`tagIDs`/`vectorModel` (decoded only to migrate). Resilient `init(from:)` (every field optional-with-default → schema changes never wipe history). Derived `preview`, `characterCountLabel`, `signature` (dedup key, `img:`/`file:`/`color:`/`text:` prefix), `isEmbedded(by:)`. |
| `Clipboard/ClipStore.swift` | `@MainActor ObservableObject` — **single source of truth**. `@Published items`, `@Published lastAddedID`, `@Published indexing`, plus `tagIndex` (tag-id → items inverted index). Mutations: `add` (dedup-bump else insert+trim+sort+index+`db.insert`+sound), `togglePin`, `delete`, `clearUnpinned`, `markUsed`. Querying: `filtered(kind:query:pinnedOnly:)` (substring), `counts()`, `items(taggedWith:)`. Indexing: `rebuildTagIndex`, `refreshForActiveModel`, `reindexStale` (background, resumable, ETA), `reclassifyAllTags` (re-tag from cached vectors on basket change). `historyLimit` over UserDefaults (default 200). Owns the `Database` and runs `migrateLegacyJSONIfNeeded`. |
| `Clipboard/ClipboardMonitor.swift` | `@MainActor` pasteboard poller. `start()` opens a 0.4 s `Timer` (tolerance 0.1, `.common` modes) and an App-Nap-defeating activity assertion. `poll()` skips own paste (`ignoreChangeCount`), transient/concealed types, then `capture()` (priority: file URL → image → string), stamps `sourceApp`, and `store.add`. `persistImage` (TIFF→PNG sidecar). `detectKind`/`isColor`/`isLink` (links via `NSDataDetector`, so bare domains/emails count; colors via hex regex requiring a digit). `suppressNextChange()`. |
| `Clipboard/Database.swift` | `final class Database` — thin SQLite store (links `sqlite3`). WAL + foreign keys. Tables `clips` and `embeddings` (`PRIMARY KEY(clip_id, model)`, cascade delete) + an order index. Incremental row ops: `insert`/`updateMeta`/`upsertEmbedding`/`delete`/`deleteUnpinned`/`delete(ids:)`/`transaction`. `loadAll()` reconstructs `ClipItem`s with their embeddings. Vectors stored as **Float16 BLOBs** (`blob(fromVector:)`/`vectorFromBlob`); tags as a comma-joined string. |
| `Clipboard/Paster.swift` | `@MainActor enum Paster`. `writeToPasteboard(_:store:plain:)` clears + writes by kind (image from disk / file URL / RTF+string; `plain:true` strips RTF). `paste(into:)` activates the prior app then after 0.12 s sends a synthetic ⌘V (`CGEvent` virtual key `0x09`, `.maskCommand`, posted to `.cghidEventTap` — needs Accessibility). |

### Search & on-device embeddings — `Sources/Ditto/Search/`
| Path | Responsibility |
| --- | --- |
| `Search/DeepSearch.swift` | The whole semantic-search engine in one file. Enums `DeepSearchLevel {off,low,normal,high}` (maps to CoreML model name + dimension; default `normal`) and `SearchMode {exact,tag,essence}` (default `exact`); `enum DeepSearch` holds both in UserDefaults. `protocol TextEmbedder` (+ `signature`, `embed`, query/doc variant). `struct HashingEmbedder` (FNV-1a tri-gram fallback, `"hashing-256"`). `final class OgmaEmbedder` (CoreML `MLModel` + `OgmaTokenizer`, task tokens QRY=4/DOC=5/SYM=6, dim 128/256/768). `enum EmbedderProvider` (owns `active` embedder; `configure`/`configureAndReindex`). `enum TagSpace` (tag vectors cache, `classify`, `nearestTag`). `enum ClipIndexer` (`index`, `isStale`, `refineKind` text→link). `enum SemanticRanker` (`searchText`, `cosine`, `essence`). |
| `Search/OgmaTokenizer.swift` | `final class OgmaTokenizer` — a faithful Swift reimplementation of ogma's Unigram/SentencePiece tokenizer from the bundled `tokenizer.json`. NFKD-normalize → strip accents → lowercase → collapse spaces → whitespace split → `▁` metaspace prefix → Unigram Viterbi → wrap `[CLS]`…`[SEP]` → add the `+n_special_tokens` offset. Validated to match the PyTorch reference token ids bit-for-bit. |
| `Search/TagBaskets.swift` | `struct TagBasket {id,name,tags}` (with caching `fingerprint`) and `enum TagBaskets` — the tag taxonomies. Five built-in baskets (`general` (100 tags), `developer`, `writing`, `business`, `everyday`) plus a UserDefaults-backed editable `custom` basket. `active`/`activeID` select the basket used by `TagSpace`. |

### Floating bar UI — `Sources/Ditto/UI/`
| Path | Responsibility |
| --- | --- |
| `UI/FloatingPanel.swift` | `final class FloatingPanel: NSPanel`. Borderless, nonactivating, level `.mainMenu+1`, joins all spaces; `barHeight 380`. **Stores a hosting controller** and rebuilds it on every present: `setContent(_:)` retains a `() -> NSViewController` builder; `refresh()` rebuilds an `NSHostingController`, installs it as `contentViewController`, forces synchronous layout — fixes the reopen-stale-content bug. `slideIn()` (0.28 s easeOut from below the screen edge) / `slideOut()` (0.2 s easeIn → `orderOut`). `targetScreen()` = screen under mouse. `resignKey()` → `onResignKey?()`. |
| `UI/PanelViewModel.swift` | `@MainActor ObservableObject` backing the bar. `@Published` `query`/`activeKind`/`pinnedOnly`/`selection`/`presentToken`/`scrollRequest`/`showSettings`. **Republishes `store.objectWillChange`** through itself (collapses two-object observation → one deterministic update path; fixes live-while-open refresh). `results` computed property routes by `DeepSearch.mode` (exact substring / tag inverted-index lookup / essence cosine). Keyboard intents: `moveSelection`, `click`, `commitSelection`, `copySelection`, `deleteSelection`, `pinSelection`, `quickSelect`. Callbacks `onPaste(item,plain)`/`onClose`/`onCopy`. |
| `UI/ContentView.swift` | `struct ContentView` (root SwiftUI view; `@ObservedObject model`+`store`, `@StateObject settings`). Layout: `toolbar` (title, `categoryChips`, search field, gear→Settings) · indexing progress bar (`store.indexing`) · either `SettingsView` or the horizontal `cards` strip (`ScrollViewReader`+`LazyHStack` of `ClipCardView`, scroll-driven by `scrollRequest`/`lastAddedID`/`presentToken`/filter changes) · keyboard-hint `footer`. `tagNames(for:)` shows the active model's top tags. `emptyState`. |
| `UI/ClipCardView.swift` | `struct ClipCardView` — one 220×250 card. `header` (kind icon, `sourceApp`, pin glyph, `⌘n` badge), per-kind `content` (image from disk / color swatch / file glyph / link text / text with 11-line clamp), `tagRow` (up to 3 tag pills), `footer` (char-count + relative time). Selection ring/scale/shadow, hover, double-click→`onActivate`, context menu Paste/Pin/Delete. |
| `UI/SettingsView.swift` | `final class AppSettings: ObservableObject` (two-way bindings over the persisted settings: sound, debug log, history limit, launch-at-login, search mode, embedding tier, active basket, custom tags; live `axTrusted` polling) **and** `struct SettingsView` — the in-bar settings surface (sections General/Sound/Search/Tags/History/Permissions & Advanced; `relaunch()` helper for AX). |
| `UI/Theme.swift` | `enum Theme` (`cardWidth 220`, `cardHeight 250`, `accent`, `color(fromHex:)` for 3/6/8-digit hex). `struct FlowLayout: Layout` (wrapping tag-pill layout). `struct VisualEffectBackground: NSViewRepresentable` (blurred material; default `.hudWindow`/`.behindWindow`). |

### Support — `Sources/Ditto/Support/`
| Path | Responsibility |
| --- | --- |
| `Support/Feedback.swift` | `@MainActor enum Feedback` (capture sound: `soundEnabled`/`soundName` defaults true/"Tink", 14 `availableSounds`, `play(named:)` volume 0.4 w/ beep fallback, `playCapture()`). `enum DebugLog` (`enabled` over UserDefaults `debugLog`; append-only ISO-8601 writer to `…/Ditto/debug.log`; `write(_:)`). |
| `Support/LoginItem.swift` | `@MainActor enum LoginItem` — launch-at-login via `SMAppService.mainApp` (`.enabled` status / `register()` / `unregister()`). Shared by the menu and Settings. |

### Tests — `Tests/DittoTests/`
| Path | Responsibility |
| --- | --- |
| `Tests/DittoTests/DittoTests.swift` | XCTest suites: `ClassificationTests` (`detectKind` text/link/color edge cases incl. hex-like words, bare domains, host-less url), `CodableResilienceTests` (legacy/minimal decode, embedding round-trip), `ColorParsingTests` (hex→RGBA), `SignatureTests` (dedup keys), `ClipStoreTests` (add/dedup/trim/unlimited/pin/filter/clear/**persistence round-trip via temp dir**/counts), `PasterTests` (plain strips RTF / rich keeps it). |
| `Tests/DittoTests/DeepSearchTests.swift` | `EmbeddingTests` (HashingEmbedder determinism, FNV-1a stability, L2 norm, cosine, similarity ordering), `TagSpaceTests` (100 tags, classify top-5, nearestTag), `EssenceRankingTests` (substring ranks first), `IngestIndexingTests` (add embeds+tags, tag-index populated, staleness, per-model cache, vectors persist+reload). |

### On-device model pipeline — `tools/`
| Path | Responsibility |
| --- | --- |
| `tools/README.md` | Documents the ogma→CoreML conversion: model table (micro 2.3M/128, small 8.6M/256, embeddinggemma 300M/768), requirements, and the download→convert→bundle flow. CoreML↔PyTorch parity cosine = 1.00000. |
| `tools/_dl.py` | `python3 _dl.py <repo>` — `huggingface_hub.snapshot_download` into `models/<name>`, with brotli content-encoding force-disabled (flaky decoder workaround). |
| `tools/convert_ogma.py` | `python3 convert_ogma.py models/<name>` — loads the ogma model via `trust_remote_code`, wraps `forward(input_ids, attention_mask, task_token_ids)` with `F.normalize`, traces, and `coremltools.convert`s to `models/<name>.mlpackage` (flexible seq length `RangeDim`, macOS13 target); prints the PyTorch-vs-CoreML parity cosine. |
| `tools/reference.py` | Produces `reference.json` — golden token ids + vector heads + norms for three sample strings, the ground truth the Swift `OgmaTokenizer`/`OgmaEmbedder` are checked against. |
| `tools/reference.json` | The golden reference data (token ids, `vec_head`, `norm`) for `the quick brown fox` (doc), `hello world` (qry), `python ValueError stack trace` (doc). |
| `tools/_compat.py` | `enum.StrEnum` backport so ogma's `trust_remote_code` modules import under Python 3.10. Imported first by the other tool scripts. |

### Build / packaging — repo root, `Scripts/`, `Resources/`
| Path | Responsibility |
| --- | --- |
| `Package.swift` | SwiftPM manifest. `swift-tools-version:5.9`, `platforms [.macOS(.v13)]`. Executable target `Ditto` (`Sources/Ditto`) links `AppKit`, `SwiftUI`, `Carbon`, `UniformTypeIdentifiers` + library `sqlite3`. Test target `DittoTests`. No external package dependencies. |
| `Makefile` | `build` (`swift build`), `app` (`Scripts/build-app.sh release`), `run` (`app` + `open`), `install` (copy to `/Applications`), `clean`. |
| `Scripts/build-app.sh` | Builds `build/Ditto.app`: `swift build -c`, assembles bundle + Info.plist, renders the icon, compiles any `tools/models/*.mlpackage` → `.mlmodelc` and bundles them + the `<name>-tokenizer/` folder (remapping `tokenizer_class`→`T5Tokenizer`), then code-signs — preferring the stable `Ditto Local Signing` identity, else ad-hoc `-`. |
| `Scripts/setup-signing.sh` | One-time, **user-run** creation of a stable self-signed `Ditto Local Signing` code-signing identity in the login keychain (OpenSSL → legacy PKCS#12 → `security import`), so the Accessibility grant survives rebuilds. Idempotent; modifies the login keychain (may prompt for password). |
| `Scripts/make-icon.swift` | Renders the app icon (indigo→purple gradient rounded rect + white `doc.on.clipboard.fill` SF Symbol) at the 10 `.iconset` sizes for `iconutil`. |
| `Resources/Info.plist` | Bundle metadata: `CFBundleIdentifier ai.axiotic.ditto`, version `1.0.0`, **`LSUIElement true`** (accessory/no Dock icon), `LSMinimumSystemVersion 13.0`, `NSAppleEventsUsageDescription`, `CFBundleIconFile Ditto`, copyright. |
| `README.md` / `SPEC.md` / `LICENSE` / `.gitignore` | Docs (README is current; **SPEC is stale** — pre-deep-search/SQLite) + MIT license + ignores. |

---

## 2. Key types & their roles

- **`AppDelegate`** (`App/AppDelegate.swift`) — `@MainActor` conductor; owns every long-lived object and orchestrates show/hide/commit, the status menu, keyboard handling, and three Darwin-notification hooks (`ai.axiotic.ditto.toggle` / `.embedtest` / `.opensettings`).
- **`ClipStore`** (`Clipboard/ClipStore.swift`) — `ObservableObject` single source of truth: `@Published items`, the SQLite-backed durable store, dedup/trim/pin/sort logic, the tag inverted-index, and the background (re)indexing pipeline.
- **`ClipItem`** (`Clipboard/ClipItem.swift`) — the reference-type history entry; `ClipKind` enum and `ModelEmbedding` live here. `signature` drives dedup; `embeddings[signature]` is the per-model vector+tags cache.
- **`Database`** (`Clipboard/Database.swift`) — incremental SQLite persistence; Float16 vector BLOBs; WAL.
- **`ClipboardMonitor`** (`Clipboard/ClipboardMonitor.swift`) — the capture loop (poll → classify → `store.add`), App-Nap defeat, own-paste/transient/concealed suppression.
- **`Paster`** (`Clipboard/Paster.swift`) — writes a clip back to the pasteboard and synthesizes ⌘V.
- **`PanelViewModel`** (`UI/PanelViewModel.swift`) — bar state + `results` (the search router) + keyboard intents; republishes `store.objectWillChange`.
- **`FloatingPanel`** (`UI/FloatingPanel.swift`) — the slide-up `NSPanel` that hosts `ContentView` and rebuilds it on each present.
- **`ContentView` / `ClipCardView` / `SettingsView` / `AppSettings`** (`UI/`) — the SwiftUI surface and its settings binding object.
- **`TextEmbedder` / `HashingEmbedder` / `OgmaEmbedder` / `EmbedderProvider`** (`Search/DeepSearch.swift`) — the embedding abstraction, fallback, CoreML model, and active-embedder owner.
- **`TagSpace` / `TagBaskets` / `ClipIndexer` / `SemanticRanker`** — tag classification, taxonomies, ingest indexing, and ranking.
- **`OgmaTokenizer`** (`Search/OgmaTokenizer.swift`) — exact-parity Unigram tokenizer.
- **`Feedback` / `DebugLog` / `LoginItem` / `HotKey`** — support singletons (sound, logging, login item, global hotkey).

---

## 3. Main data flows

### 3.1 Capture (copy → history)
`NSPasteboard.general` ← 0.4 s `Timer` (`ClipboardMonitor.start`, App-Nap defeated) →
`ClipboardMonitor.poll()` (bail if `changeCount` unchanged; skip own paste / transient / concealed) →
`capture(from:)` (file URL → image→PNG sidecar → string+`detectKind`+RTF) → stamp `sourceApp` →
`ClipStore.add(item)`:
- duplicate `signature` → bump `lastUsedAt`, re-sort, set `lastAddedID`, `db.updateMeta`, return; else
- if a model tier is on and the item is stale → `ClipIndexer.index` (embed + top-5 tags) + `refineKind` (text→link); then `items.insert(at:0)` → `trim()` → `sortStable()` → `rebuildTagIndex()` → set `lastAddedID` → `db.insert(item)` → `Feedback.playCapture()`.

`@Published items` / `lastAddedID` → SwiftUI re-render; row written to `ditto.sqlite`.

### 3.2 Persistence
- DB at `~/Library/Application Support/Ditto/ditto.sqlite` (WAL). `clips` + `embeddings` tables.
- `ClipStore.init` opens the DB, runs `migrateLegacyJSONIfNeeded` (imports an old `history.json` once → archives it as `history.migrated.json`; folds legacy single-vector fields into `embeddings`), `loadAll()`, sorts, rebuilds the tag index.
- Image payloads are `<uuid>.png` files in the same directory (deleted with their clip).
- Vectors persist as Float16 BLOBs; tags as comma-joined ints.

### 3.3 Embedding / tagging
- At ingest, the active embedder produces a vector for the clip's `searchText`; `TagSpace.classify` assigns the top-5 nearest preset tags → cached under `item.embeddings[signature]` and into `tagIndex`.
- `EmbedderProvider.configureAndReindex` (launch / tier change) loads the CoreML model for the tier (or `HashingEmbedder` fallback) and `store.refreshForActiveModel()` → `reindexStale()` embeds only clips missing the active model's vector (background, resumable, ETA in `store.indexing`).
- Changing the **tag basket** calls `store.reclassifyAllTags()` — re-runs only the cheap nearest-tag step from cached vectors (no re-embedding).

### 3.4 Search (`PanelViewModel.results`, routed by `DeepSearch.mode`)
- **exact** (or empty query) → `ClipStore.filtered` substring over `text`/`filePath`/`colorHex`.
- **tag** → `TagSpace.nearestTag(query)` (≤100 comparisons) → `store.items(taggedWith:)` O(1) inverted-index lookup, intersected with the kind/pinned scope.
- **essence** → `SemanticRanker.essence` full query·item cosine over stored vectors (+ substring boost), thresholded.

### 3.5 Paste (pick → write-back → ⌘V)
`⌃⌥⌘V` (`HotKey`) / Darwin `ai.axiotic.ditto.toggle` / menu → `AppDelegate.toggle()` → `show()`:
`panel.refresh()` (rebuild hosting controller) → record `previousApp` → reset model state → bump `presentToken` → `NSApp.activate` → `panel.slideIn()`.
Selecting (Enter / double-click / ⌘1–9) → `model.onPaste(item,plain)` → `AppDelegate.commit`:
`store.markUsed` → `monitor.suppressNextChange()` → `Paster.writeToPasteboard(plain:)` → if `AXIsProcessTrusted()` then `hide(paste:true)` → `slideOut` → `Paster.paste(into: previousApp)` (activate + after 0.12 s synth ⌘V); else prompt once and dismiss (clip is on the pasteboard regardless).
`⌘C`/`⌃C` → `copyToClipboard` writes without pasting. `esc` → `hide(paste:false)`. Losing key focus (`resignKey`) auto-dismisses.

---

## 4. Build / run / test commands

```bash
make build         # swift build (debug binary)
make app           # Scripts/build-app.sh release → build/Ditto.app (bundles models if present)
make run           # build app + open it
make install       # copy build/Ditto.app to /Applications
make clean         # swift package clean + rm -rf build .build

swift build [-c release]           # direct SwiftPM build
swift test                         # run DittoTests (XCTest)
Scripts/build-app.sh [debug|release]   # assemble bundle + icon + models + codesign
Scripts/setup-signing.sh           # one-time: stable self-signed identity (login keychain)
```

Scriptable toggle without the hotkey/Accessibility: post the Darwin notification
`ai.axiotic.ditto.toggle` (also `ai.axiotic.ditto.opensettings`, `ai.axiotic.ditto.embedtest`).

Model pipeline (see `tools/README.md`):
```bash
cd tools
python3 _dl.py axiotic/ogma-small && python3 convert_ogma.py models/ogma-small
python3 _dl.py axiotic/ogma-micro && python3 convert_ogma.py models/ogma-micro
cd .. && make app   # build-app.sh compiles + bundles the .mlpackage(s) automatically
```

Requires macOS 13+ and the Swift toolchain (Xcode 15+). Auto-paste (⌘V) needs
**Accessibility** permission; until granted, picking a clip still copies it.

---

## 5. Where settings & state live

### UserDefaults keys (domain `ai.axiotic.ditto`)
| Key | Type / default | Owner |
| --- | --- | --- |
| `historyLimit` | Int, **200** (0 = unlimited) | `ClipStore.historyLimit` |
| `soundEnabled` | Bool, **true** | `Feedback.soundEnabled` |
| `soundName` | String, **"Tink"** | `Feedback.soundName` |
| `debugLog` | Bool, **false** | `DebugLog.enabled` (toggled by `AppDelegate.toggleDebug` / Settings) |
| `deepSearchLevel` | String, **"normal"** (`off/low/normal/high`) | `DeepSearch.level` |
| `searchMode` | String, **"exact"** (`exact/tag/essence`) | `DeepSearch.mode` |
| `activeBasket` | String, **"general"** | `TagBaskets.activeID` |
| `customTags` | [String], default = General's tags | `TagBaskets.custom` |

Launch-at-login is **not** a UserDefaults key — it is `SMAppService.mainApp` state (`LoginItem`).

### On-disk state — `~/Library/Application Support/Ditto/`
| Path | Contents |
| --- | --- |
| `ditto.sqlite` (+ `-wal`/`-shm`) | Durable history: `clips` and `embeddings` tables (WAL). |
| `<uuid>.png` | Image payloads (TIFF→PNG), referenced by `ClipItem.payloadFile`; deleted with the item. |
| `debug.log` | Append-only ISO-8601 diagnostics (only when `debugLog` is on). |
| `history.migrated.json` | Archived legacy JSON after a one-time migration (or `history.corrupt.json` if it failed to decode). |

(The base directory is overridable via `ClipStore(directory:)` — tests inject a temp dir.)

### Constants worth knowing
Global hotkey `⌃⌥⌘V` (`kVK_ANSI_V` + `controlKey|optionKey|cmdKey`); HotKey id sig `0x4454_4f48` 'DTOH'.
Poll 0.4 s / tolerance 0.1 / `.common`. Panel `barHeight 380`, level `.mainMenu+1`; slideIn 0.28 s easeOut / slideOut 0.2 s easeIn. Paste delay 0.12 s. Card 220×250; text line clamp 11 / link 6 / file 2. Embedding dims: low 128, normal 256, high 768; ogma `maxLen` 256; task tokens QRY 4 / DOC 5 / SYM 6. Essence threshold 0.12. Bundle id `ai.axiotic.ditto`, version 1.0.0.

---

## 6. On-device model pipeline (`tools/`)

1. **Download** (`_dl.py <repo>`) → `tools/models/<name>/` (HF snapshot; brotli disabled).
2. **Convert** (`convert_ogma.py models/<name>`) → loads ogma via `trust_remote_code`, wraps `forward(input_ids, attention_mask, task_token_ids)` with `F.normalize`, traces, `coremltools.convert` → `tools/models/<name>.mlpackage` with flexible sequence length and a printed PyTorch-vs-CoreML parity cosine (1.00000).
3. **Verify tokenizer/embeddings** (`reference.py` → `reference.json`) — golden token ids / vector heads / norms the Swift side is matched against bit-for-bit. `_compat.py` provides the `StrEnum` shim for Python 3.10.
4. **Bundle** (`Scripts/build-app.sh`) — compiles every `tools/models/*.mlpackage` to `.mlmodelc` into `Ditto.app/Contents/Resources`, and copies each model's `tokenizer.json`/`config.json`/`tokenizer_config.json` into a `<name>-tokenizer/` folder (remapping `tokenizer_class`→`T5Tokenizer`).
5. **Load at runtime** — `EmbedderProvider.configure(level:)` resolves `<name>.mlmodelc` + `<name>-tokenizer` from the bundle; on success uses `OgmaEmbedder` (CoreML), else falls back to `HashingEmbedder`. The Swift `OgmaTokenizer` reproduces ogma's Unigram pipeline (metaspace `▁`, `+n_special_tokens` offset) so token ids match the Python reference exactly.

Model tiers: low `axiotic/ogma-micro` (2.3M, 128-dim) · normal `axiotic/ogma-small` (8.6M, 256-dim, default) · high `google/embeddinggemma-300m` (300M, 768-dim, gated). Each `OgmaEmbedder` has a `signature` (`"<name>-<dim>"`); vectors/tags are only comparable within one signature, which is why the per-model cache and the `hashing-256` fallback are kept separate.

---

**Files mapped: 31** (Package.swift, Makefile, README.md, SPEC.md, LICENSE, .gitignore, Resources/Info.plist; 3 App + 5 Clipboard + 3 Search + 5 UI + 2 Support source files; 2 test files; 3 Scripts; 6 tools files).
