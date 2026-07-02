# Cliphoard / Ditto — Codebase Map

> **Cliphoard** (bundle id `ai.axiotic.ditto`) is a macOS menu-bar clipboard manager with on-device semantic search. It captures every copy into an encrypted SQLite history, embeds entries with a CoreML model (with a deterministic hashing fallback), tags them against a 100-tag taxonomy, and surfaces them in a borderless floating bar invoked by a global hotkey (⌃⌥⌘V), pasting the chosen clip into the previously-frontmost app via a synthetic Cmd-V.

## Overview / Architecture

The app is a single SwiftPM executable target (`Cliphoard`) plus a test target (`CliphoardTests`). It is a non-sandboxed, `LSUIElement` accessory app (no Dock icon) targeting macOS 13+. Functionality is organized in four layers:

1. **App / control layer** (`Sources/Cliphoard/App`) — `@main` entrypoint, the `AppDelegate` that owns every subsystem and wires the status-bar menu, the global Carbon hotkey, and the present/hide/commit-paste flow.
2. **Clipboard / data layer** (`Sources/Cliphoard/Clipboard`) — the data model (`ClipItem`), the polling capture engine (`ClipboardMonitor`), the durable store (`ClipStore` over `Database`/SQLite), at-rest encryption (`Crypto`), and the paste actuator (`Paster`).
3. **Search layer** (`Sources/Cliphoard/Search`) — the semantic engine: embedders (CoreML `OgmaEmbedder` + `HashingEmbedder` fallback), the `OgmaTokenizer` port, the `TagBaskets` taxonomies, and `TagSpace`/`ClipIndexer`/`SemanticRanker`.
4. **UI layer** (`Sources/Cliphoard/UI`) — SwiftUI floating bar (`FloatingPanel` + `ContentView`), per-clip cards (`ClipCardView`), the view model (`PanelViewModel`), settings (`SettingsView`/`AppSettings`), onboarding, and the `Theme` system.

Cross-cutting **Support** (`Sources/Cliphoard/Support`) provides audible feedback + debug logging (`Feedback`/`DebugLog`) and launch-at-login (`LoginItem`).

**Build & distribution**: `Makefile` → `Scripts/build-app.sh` assembles `Cliphoard.app` (binary + Info.plist + rendered icon + bundled CoreML models/tokenizers + code-signing). `Scripts/release.sh` signs/notarizes/staples a DMG. `Scripts/setup-signing.sh` creates a stable local signing identity so the Accessibility grant survives rebuilds. A Python `tools/` toolchain restores ogma HF models and converts them to CoreML `.mlpackage`; two GitHub Actions workflows (`models.yml`, `release.yml`) exercise that path and cut releases.

## Entry Points

- **`Sources/Cliphoard/App/Main.swift`** — `@main struct Main`; creates `NSApplication` + `AppDelegate`, sets `.accessory` policy, runs the app. This is the runtime entrypoint.
- **`Sources/Cliphoard/App/AppDelegate.swift`** — `applicationDidFinishLaunching`; the de-facto application bootstrap that constructs `ClipStore`, `ClipboardMonitor`, `PanelViewModel`, `FloatingPanel`, and `HotKey`.
- **`Package.swift`** — SwiftPM manifest defining the `Cliphoard` executable and `CliphoardTests` targets.
- **`Makefile`** — developer build/run/install/clean entrypoints.
- **`Scripts/build-app.sh`** / **`Scripts/release.sh`** — app-bundle and DMG release entrypoints.
- **`tools/restore-models.sh`** — model restore+convert orchestrator (consumed by `build-app.sh` and CI).

## Per-directory file index

### Root (manifest, build, distribution)

| File | Lang | Role | Key symbols |
|---|---|---|---|
| `Package.swift` | swift | SwiftPM manifest: `Cliphoard` executable target (AppKit/SwiftUI/Carbon/UTI + sqlite3) + `CliphoardTests` (Fixtures resource copy) | `let package` |
| `Makefile` | make | Build entrypoints | `build`, `app`, `run`, `install`, `clean` |
| `Resources/Info.plist` | plist | App bundle Info: `ai.axiotic.ditto` v1.0.0, `LSUIElement` accessory, min macOS 13, AppleEvents usage string | `CFBundleIdentifier`, `LSUIElement`, `LSMinimumSystemVersion` |
| `Casks/cliphoard.rb` | ruby | Homebrew Cask for DMG distribution via tap | `cask "cliphoard"` |

### Scripts/ (build, sign, release)

| File | Lang | Role | Key symbols |
|---|---|---|---|
| `build-app.sh` | bash | Assembles `Cliphoard.app`: swift build release, copy binary+plist, render icon, bundle CoreML models/tokenizers + LICENSE, code-sign (stable identity preferred, else ad-hoc) | `SIGN_ID`, `APP` |
| `make-icon.swift` | swift | Renders the app icon (Cmd-V glyph on graphite squircle) into a full `.iconset` for `iconutil` | `drawIcon(size:)`, `svgArc(...)`, `png(...)`, `VB` |
| `release.sh` | bash | Release pipeline: build, Developer-ID sign + Hardened Runtime + entitlements, notarize/staple, package+sign+notarize DMG; degrades to local self-signed | `DEVID`, `NOTARY_PROFILE`, `say`, `warn` |
| `setup-signing.sh` | bash | One-time: create stable self-signed "Ditto Local Signing" identity so AX grant survives rebuilds; idempotent | `IDENTITY_NAME` |
| `Cliphoard.entitlements` | plist | Deliberately empty: app is NOT sandboxed (needs global hotkey + synthetic Cmd-V); Hardened Runtime, AX at runtime | — |

### Sources/Cliphoard/App/ (control layer)

| File | Lang | Role | Key symbols |
|---|---|---|---|
| `Main.swift` | swift | `@main` entrypoint; NSApplication + AppDelegate, `.accessory` policy | `Main.main()` |
| `AppDelegate.swift` | swift | Central controller: builds status-bar menu; owns store/monitor/viewmodel/panel/hotkey; wires hotkey + Darwin-notification toggle; present/hide/commit-paste with AX-trust handling; routes key events | `AppDelegate`, `PasteStatus`, `applicationDidFinishLaunching`, `rebuildMenu`, `setupPanel`, `toggle`, `show`, `hide(paste:)`, `commit(_:plain:)`, `handleKey`, `setupHotKey`, `promptAccessibility` |
| `HotKey.swift` | swift | Single system-wide global hotkey via Carbon Hot Key API → `onPressed` on main queue | `HotKey`, `register(keyCode:modifiers:)`, `unregister()` |

### Sources/Cliphoard/Clipboard/ (data layer)

| File | Lang | Role | Key symbols |
|---|---|---|---|
| `ClipItem.swift` | swift | Core model: `ClipKind`, `ModelEmbedding`, `ClipItem` (Codable/Identifiable) with per-model embedding cache, legacy migration, resilient decode, derived `preview`/`signature` | `ClipKind`, `ModelEmbedding`, `ClipItem`, `init(from:)`, `isEmbedded(by:)`, `preview`, `signature` |
| `ClipStore.swift` | swift | `@MainActor` history owner: SQLite-backed store + in-memory items + inverted `tagIndex`; add/dedup/trim/pin/delete, incremental index maintenance, (re)indexing/reclassify, legacy JSON migration, encryption/Secure-Enclave re-key, orphan-PNG sweep, filtering | `ClipStore`, `IndexingProgress`, `add`, `filtered(kind:query:pinnedOnly:)`, `reindexStale`, `reclassifyAllTags`, `togglePin`, `delete`, `migrateLegacyJSONIfNeeded`, `sweepOrphanPayloads` |
| `ClipboardMonitor.swift` | swift | `@MainActor` pasteboard poller (0.4s, App-Nap-exempt): captures copies, skips excluded apps/private types, persists images+thumbnails; pure static `shouldSkip`/`detectKind` | `ClipboardMonitor`, `start`, `stop`, `poll`, `capture`, `shouldSkip`, `detectKind`, `isColor`, `isLink` |
| `Crypto.swift` | swift | At-rest AES-GCM encryption; Secure-Enclave-derived key (P-256 + HKDF) or random Keychain key; non-destructive seal/open w/ legacy fallback + `enc1:` marker | `Crypto`, `usesSecureEnclave`, `seal`, `open`, `resolveKey`, `secureEnclaveKey` |
| `Database.swift` | swift | Thin SQLite (C API) store: clips + embeddings tables (WAL, encrypted content, Float16 BLOB vectors), CRUD, ordering, transactions, vacuum, blob/vector/tag (de)serialization | `Database`, `init?(path:)`, `loadAll`, `insert`, `updateMeta`, `upsertEmbedding`, `delete`, `transaction`, `blob(fromVector:)`, `vectorFromBlob`, `tags(fromText:)` |
| `Paster.swift` | swift | `@MainActor` pasteboard writer + actuator: writes clip (text/RTF/image/file, plain option) and synthesizes Cmd-V into prior frontmost app | `Paster`, `writeToPasteboard`, `paste(into:)`, `sendCommandV` |

### Sources/Cliphoard/Search/ (semantic engine)

| File | Lang | Role | Key symbols |
|---|---|---|---|
| `DeepSearch.swift` | swift | Engine core: tier/mode enums; `TextEmbedder` protocol; `HashingEmbedder` fallback + CoreML `OgmaEmbedder`; `EmbedderProvider` (active model + reindex); `TagSpace` (100-tag classify/nearest); `ClipIndexer` (embed+tag, staleness); `SemanticRanker` (cosine/essence/smart) | `DeepSearchLevel`, `SearchMode`, `DeepSearch`, `TextEmbedder`, `HashingEmbedder`, `OgmaEmbedder`, `EmbedderProvider`, `TagSpace`, `ClipIndexer`, `SemanticRanker` |
| `OgmaTokenizer.swift` | swift | Faithful Swift port of ogma Unigram/SentencePiece tokenizer (from bundled tokenizer.json/config.json): NFKD → whitespace split → metaspace → Unigram Viterbi → CLS/SEP + offset | `OgmaTokenizer`, `init?(folder:)`, `encode`, `normalize`, `unigram` |
| `TagBaskets.swift` | swift | `TagBasket` model + built-in taxonomies (general/developer/writing/business/everyday) + UserDefaults custom basket; active selection drives `TagSpace` | `TagBasket`, `TagBaskets`, `general`, `builtIn`, `custom`, `active`, `activeID` |

### Sources/Cliphoard/Support/ (cross-cutting)

| File | Lang | Role | Key symbols |
|---|---|---|---|
| `Feedback.swift` | swift | Audible capture feedback (system sound) + `DebugLog` append-only diagnostics file; both UserDefaults-backed | `Feedback`, `DebugLog`, `playCapture`, `DebugLog.write` |
| `LoginItem.swift` | swift | Launch-at-login via `SMAppService` (macOS 13+) | `LoginItem`, `enabled`, `set(_:)` |

### Sources/Cliphoard/UI/ (SwiftUI front end)

| File | Lang | Role | Key symbols |
|---|---|---|---|
| `FloatingPanel.swift` | swift | Borderless non-activating `NSPanel` pinned to screen bottom; slides in/out; rebuilds hosting controller per present to re-evaluate SwiftUI against fresh store; resignKey → dismiss | `FloatingPanel`, `setContent`, `refresh`, `slideIn`, `slideOut`, `resignKey` |
| `ContentView.swift` | swift | Root view of the bar: toolbar (chips/search-mode/search/gear), paste-blocked banner + confirm flash, indexing bar, three layouts (strip/spotlight/list), footer, scroll-into-view; hosts `SettingsView` | `ContentView`, `init`, `body`, `tagNames(for:)` |
| `ClipCardView.swift` | swift | SwiftUI card for one `ClipItem` (Paste-style): per-kind header/content, tag chips, footer, selection ring, context menu, a11y; static thumbnail `NSCache` | `ClipCardView`, `imageCache`, `cachedImage(for:)`, `body` |
| `PanelViewModel.swift` | swift | `@MainActor` bar backing: query/filter/selection/present state; republishes store; memoized filtered/ranked results via `DeepSearch`; keyboard/click intents | `PanelViewModel`, `results`, `computeResults`, `moveSelection`, `commitSelection`, `copySelection`, `deleteSelection`, `pinSelection`, `quickSelect` |
| `SettingsView.swift` | swift | In-bar settings: `AppSettings` (two-way bindings → Feedback/DebugLog/store/LoginItem/Theme/DeepSearch/TagBaskets) + `SettingsView` sections (General/Appearance/Sound/Search/Tags/History/Permissions), embedder status, AX-trust polling/relaunch | `AppSettings`, `SettingsView`, `applyCustomTags`, `refreshAXTrust`, `body` |
| `OnboardingView.swift` | swift | First-run welcome window: explains hotkey + one-time Accessibility grant, polls AX trust, re-openable from menu | `Onboarding`, `OnboardingView`, `showIfNeeded`, `present` |
| `Theme.swift` | swift | Theming: `ThemeTokens`, `ThemePreset` (system + dark/light palettes), `LayoutMode`, `Theme` facade (persistence, backgrounds, hex→Color) + reusable `FlowLayout`, `VisualEffectBackground` | `ThemeTokens`, `ThemePreset`, `LayoutMode`, `Theme`, `FlowLayout`, `VisualEffectBackground` |

### Tests/CliphoardTests/

| File | Role | Key classes |
|---|---|---|
| `CoreTests.swift` | Broad: kind detection, Codable resilience, hex parsing, dedup signatures, ClipStore behavior, Paster plain-vs-rich RTF | `ClassificationTests`, `CodableResilienceTests`, `ColorParsingTests`, `SignatureTests`, `ClipStoreTests`, `PasterTests` |
| `CaptureSkipTests.swift` | `ClipboardMonitor.shouldSkip`: excluded bundle IDs + private types skipped | `CaptureSkipTests` |
| `CryptoTests.swift` | `Crypto` round-trips, legacy plaintext pass-through, ciphertext opacity (BL-02) | `CryptoTests` |
| `DatabaseTests.swift` | SQLite `Database`: Float16 round-trip, insert/loadAll, cascade delete, deleteUnpinned, ordering, reopen persistence (BL-T1) | `DatabaseTests` |
| `DeepSearchTests.swift` | Embedding/search internals: HashingEmbedder determinism/L2/cosine, TagSpace, essence ranking, ClipIndexer ingest/staleness/cache (class is `EmbeddingTests`, not the filename) | `EmbeddingTests`, `TagSpaceTests`, `EssenceRankingTests`, `IngestIndexingTests` |
| `IncrementalIndexTests.swift` | BL-08: incremental `tagIndex` stays byte-identical to full rebuild across adds/deletes/pins/dedup | `IncrementalIndexTests` |
| `MigrationTests.swift` | BL-T2: legacy history.json→SQLite migration (pins survive, vectors fold, JSON archived, corrupt preserved) | `MigrationTests` |
| `OgmaTokenizerTests.swift` | H3/BL-T3: tokenizer on `Fixtures/ogma-mini` (CLS/SEP+offset, whitespace split, OOV→UNK, missing folder→nil) | `OgmaTokenizerTests` |
| `OrphanSweepTests.swift` | BL-18: init sweeps stray unreferenced *.png, keeps referenced | `OrphanSweepTests` |
| `SearchRankingTests.swift` | BL-T6: `SemanticRanker.essence` substring outranks, 0.12 threshold, top-K fallback capped at 12 | `SearchRankingTests` |
| `Fixtures/ogma-mini/config.json` | Fixture: minimal ogma config (`n_special_tokens=7`) | — |
| `Fixtures/ogma-mini/tokenizer.json` | Fixture: minimal HuggingFace Unigram tokenizer (9-token vocab, unk_id=1) | — |

### tools/ (Python model toolchain)

| File | Lang | Role | Key symbols |
|---|---|---|---|
| `restore-models.sh` | bash | Orchestrator: idempotently download (`_dl.py`) + convert (`convert_ogma.py`) each ogma model into `tools/models/` in the layout `build-app.sh` expects; skips present | `MODELS`, `HF_REPO_PREFIX`, `ROOT` |
| `_dl.py` | python | Download an ogma HF repo snapshot into `models/<name>/` (brotli disabled); arg1 = repo id | `_dl.py <repo>` |
| `convert_ogma.py` | python | Load ogma PyTorch model, wrap + L2-normalize embedding, trace, convert to CoreML `.mlpackage`, print parity_cosine vs PyTorch ref | `Wrap`, `convert_ogma.py <model_path>` |
| `reference.py` | python | Compute PyTorch reference embeddings for fixed sample texts (models/ogma-small) → `reference.json` | `P`, `samples`, `reference.py` |
| `reference.json` | json | Golden parity data: ids, first-6 dims, L2 norm for 3 sample texts | `reference[0..2]` |
| `_compat.py` | python | Backport `enum.StrEnum` on Python 3.10 so ogma trust_remote_code modules import | `StrEnum` |
| `requirements.txt` | text | Frozen pins (Python 3.11): torch 2.7.1, coremltools 9.0, numpy 1.26.4, transformers, etc. | — |

### .github/workflows/

| File | Role |
|---|---|
| `models.yml` | "Models (restore + convert)": cert-free proof the download+convert path works; on `workflow_dispatch` + PRs touching `tools/**`; caches+verifies both `.mlpackage`s + tokenizers on macos-14 |
| `release.yml` | "Release": on `v*.*.*` tag, restores+converts models, sets up signing + notarytool, builds/signs/notarizes/packages DMG via `Scripts/release.sh`, publishes GitHub Release with SHA-256 |

## Dependency Sketch

```
Main.swift  ──▶  AppDelegate
                   │  owns / wires
                   ├─▶ ClipStore ──▶ Database ──▶ Crypto
                   │      │            └▶ ClipItem / ModelEmbedding
                   │      ├─▶ ClipIndexer / EmbedderProvider / TagSpace  (Search)
                   │      └─▶ Feedback / DebugLog
                   ├─▶ ClipboardMonitor ──▶ ClipStore, ClipItem, DebugLog
                   ├─▶ HotKey                (Carbon global hotkey)
                   ├─▶ Paster ──▶ ClipItem, ClipStore   (writes pasteboard + synth Cmd-V)
                   ├─▶ FloatingPanel ──▶ ContentView
                   │                        ├─▶ PanelViewModel ──▶ ClipStore + DeepSearch
                   │                        ├─▶ ClipCardView ──▶ Theme
                   │                        ├─▶ SettingsView / AppSettings
                   │                        └─▶ PasteStatus (defined in AppDelegate)
                   ├─▶ Onboarding / OnboardingView
                   └─▶ LoginItem (SMAppService)

Search layer:
  DeepSearch ──▶ OgmaEmbedder ──▶ OgmaTokenizer  (CoreML + bundled tokenizer)
            └──▶ HashingEmbedder (deterministic fallback)
  TagSpace / TagBaskets  (100-tag taxonomy, active basket selection)

Build/dist:
  Makefile ──▶ build-app.sh ──▶ make-icon.swift, Info.plist, setup-signing.sh
            └▶ release.sh ──▶ build-app.sh, Cliphoard.entitlements
  tools/restore-models.sh ──▶ _dl.py, convert_ogma.py (── _compat, requirements.txt)
                              └▶ feeds models into build-app.sh
  CI: models.yml / release.yml ──▶ restore-models.sh, release.sh
```

**Key flows:**
- **Capture**: `ClipboardMonitor.poll` (0.4s) → `capture` → `ClipStore.add` → dedup/trim + `Database.insert` (encrypted) → background `ClipIndexer.index` (embed via `EmbedderProvider.active` + tag via `TagSpace`) → incremental `tagIndex` update + `Feedback.playCapture`.
- **Invoke + paste**: `HotKey.onPressed` (or Darwin notif) → `AppDelegate.toggle`/`show` → `FloatingPanel.slideIn` rebuilds `ContentView`; `PanelViewModel.results` ranks via `DeepSearch`/`SemanticRanker`; selection → `AppDelegate.commit` → `Paster.writeToPasteboard` + `Paster.paste` (synthetic Cmd-V into prior frontmost app), gated on AX trust.
- **Persistence/migration on init**: `ClipStore.init` → legacy `history.json` migration, Secure-Enclave re-key, encrypt-existing-rows, kind repair, orphan-PNG sweep, tag-index rebuild.
