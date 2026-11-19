# Windows parity implementation and qualification

Updated 17 November 2026. The shipping macOS source is the behavioral reference. Version 1.2.3.0 established the baseline below. The search and docking follow-up records subsequent fixes.

## Implemented workflows

- [x] Complete detector vocabulary, content shapes, checksum/entropy/OTP decisions, origin quarantine and unsigned 64-bit flags.
- [x] Content-bound, sixty-second reveal grants, alternate RTF/HTML representation inspection and protected metadata handling. Unsupported embedded RTF objects remain quarantined.
- [x] Local explicit-content screening, exemptions, text/image/audio/video controls and read-only Windows Focus state. Unknown conditional state retains protection.
- [x] Encrypted per-row SQLite history, lazy payloads, Unlimited history, unrestricted pins, incremental persistence, legacy migration and transactional failure handling.
- [x] Storage-failure notices, memory-only quit confirmation and encrypted suspension recovery.
- [x] All supported Mac model families, both Ogma projection heads, exact/Tags/Neural/Smart search and Gemma image specificity admission.
- [x] Twelve Mac tag baskets, specialist overlays, custom baskets, confidence assignment, facets, suggestions, user labels and persisted dismissals.
- [x] Combined text/image/audio/video search with rank fusion, calendar/custom ranges and `when:` query syntax.
- [x] Instant/pause/Enter timing, composition admission and held-Enter refusal.
- [x] Durable encrypted per-model indexes, cancellation, pause/resume and forget controls. Pause state survives reopening Settings within the session.
- [x] Local media selection, bounded decoding and sampling, sound/frame vectors, sampled/full speech coverage, passage timestamps and retained-stream moment playback.
- [x] Bounded plain-text/RTF/PDF document extraction, encrypted snapshots, refresh and optional model tagging.
- [x] Reference-image selection, semantic image retrieval and perceptually similar-image actions. Shift+F10 exposes selected-card actions from keyboard focus outside the query editor.
- [x] Last-used/use-count ordering, factual chips and inspector metadata.
- [x] Paste, Maccy, Alfred and Flycut store preview/import, private SQLite snapshots including WAL and explicit Alfred preview acceptance.
- [x] Encrypted Mac-compatible agent transport, explicit connection/approval sessions, pinned agent notes, notifications and an installed seven-tool MCP companion.
- [x] Guided onboarding, eighteen Mac palettes, three layouts, height controls, native Windows capture sounds, passive summon and archive passphrase generation.
- [x] Optional release checks, offline licence verification and bounded encrypted diagnostic event logging.
- [x] Native target/focus validation, reopening, rich/plain paste, PNG plus DIBV5 browser compatibility, numeric HWND reuse and partial-input cleanup.
- [x] ARM64 and emulated-x64 regression qualification, model-free packages and data-preserving ARM64 installation.

## Supported model inventory

Text choices are built-in hashing, Ogma Micro, Ogma Small, MiniLM and EmbeddingGemma 2. Both Ogma models expose 384- and 1024-dimensional projections. Image choices are OpenVision Tiny and EmbeddingGemma 2. Speech choices are Whisper Small, Large v3 and Large v3 Turbo. Gemma also provides local sound/frame embeddings for media search.

Acquisition stays explicit. Immutable asset revisions, byte sizes and SHA-256 pins are compiled into the application. Cached models work offline. Installers contain runtime libraries and notices, with learned weights excluded. Windows ARM64 uses the owned private x64 worker for runtimes distributed for x64. Detailed model/reference tolerances are recorded in [the model qualification report](WINDOWS-MODELS-20261116.md).

## Automated qualification

Thirty core suites passed on each architecture. Their final component counts total 729 checks per architecture, including the later four diagnostic-storage checks. x64 execution used Windows ARM64 emulation.

| Suite | Checks per architecture |
| --- | --- |
| Clipboard image compatibility | 14 |
| Shipping Mac detector goldens and shapes | 70 |
| Protected-content/reveal/representation policy | 49 |
| Tag baskets and facets | 15 |
| Agent protocol, directory, controller, writer, companion | 43 / 20 / 29 / 20 / 17 |
| Capture suspension, forget-image | 9 / 6 |
| Documents and other-manager imports | 25 / 17 |
| Mac archive, legacy archive, streaming archive | 45 / 25 / 13 |
| History, encrypted storage, session recovery | 29 / 14 / 10 |
| Distribution, themes, clipboard features | 18 / 44 / 27 |
| Perceptual images and encrypted embedding cache | 10 / 12 |
| Media decoding, speech boundaries, media index | 81 / 10 / 17 |
| Screening, MiniLM semantic, OCR | 14 / 21 / 5 |

Both architectures also passed twelve native boundary checks. The final policy run passed 150 policy checks and 22 deferred-paste checks. The 23 selection/handoff checks are included in the 150 total.

Real-model regression passed Ogma 163, OpenVision 17, Gemma 11 and model-switching 27 checks. Both Ogma projection heads matched reference vectors above cosine 0.99999999999. OpenVision also exceeded that value. Gemma's minimum reference cosine was 0.9985696447. Every supported Whisper model recognized the generated 67-character speech fixture. Owned-worker parent-death cleanup passed. Earlier complete model qualification also covered emulated x64.

Streaming archive tests include 1,001 clips, 31 pins and an encrypted file larger than 48 MB. Storage tests include 5,001 clips, 30 pins, concurrent writers, a legacy encrypted store and an injected transactional failure. Agent tests exercise ACLs, junction refusal, authenticated receipts, Unicode paging, expiry and no-overwrite publication. The directory-replacement fixture observed Windows preventing an ancestor rename. It does not establish execution of a replacement-success branch.

Guest evidence is retained under `C:\CliphoardDev\evidence`. Final core logs use `latest-arm64-*` and `latest-x64-*`. Later diagnostic-storage runs use `diagnostics-arm64-*` and `diagnostics-x64-*`. Policy and numeric reuse receipts use the `shipping-` prefix. Source builds and packages treat warnings as errors and use locked dependencies.

## Normal-entry-point UI qualification

The normal Debug frontend used only the fixed, marked synthetic profile at `C:\CliphoardDev\qualification\interactive-profile`. Release builds reject both synthetic entry flags with exit code 78 on both architectures.

- Native rich-text paste retained bold formatting in the disposable RichTextBox. Plain-text quick paste removed that formatting. Paste metadata confirmed original-target restoration, current epoch and native clipboard write admission.
- Real Chrome paste received `image/png`, 224 by 224 pixels, with the expected red RGBA pixel. The original PNG remains byte-identical while DIBV5 enables the Windows/Chromium standard image path. The browser completed asynchronous image decoding before the result was accepted.
- The generated backup passphrase populated both masked fields and reported strong strength. Export using a public synthetic fixture phrase completed. The unchanged shipping Mac archive reader authenticated that UI-produced archive and verified six clips and two PNG payload hashes.
- Native import authenticated and merged four new synthetic archive rows. Alfred preview showed two generated rows, disabled Import until preview acceptance, then imported both.
- Similar-image actions and a native reference-image picker completed. Cached OpenVision preparation finished locally and returned image results.
- Document capture produced the expected extracted text in Inspector. Refresh re-extracted the local synthetic document snapshot.
- Media refresh recognized generated speech, saved the index encrypted, and returned an Audio-scope speech match. The player displayed passage, timestamp, coverage and duration. Playback reached the four-second fixture end.
- Player cleanup initially crashed the frontend. The repaired path detaches the WinUI player, removes the media callback, and releases player/source/stream/file ownership. Close-before-play, close-during-play and close-after-play all completed, followed by responsive frontend actions.
- Forgetting synthetic semantic indexes visibly enabled pause. Pause stayed enabled after reopening Settings. Resume returned the indexed media result. The final build also clarifies the paused empty state and expands the diagnostic-log viewport.
- Debug logging and its event viewer worked. Entries contain fixed event names and UTC times, with a 256-entry bound inside encrypted account settings.
- Earlier normal-entry-point checks covered Enter submission, held Enter, `when:today`, specialist basket selection and preference restoration. Existing owner settings were preserved.
- Real MCP reader and writer workflows passed 16 and 21 checks. The writer used an explicit fifteen-minute Ask every time session, native folder selection and native Save and pin approval for a synthetic note. Receipt reconciliation and disconnect completed.

The isolated Chrome for Testing binary came from Google's official storage endpoint and reports NotSigned. Its origin and SHA-256 receipt are retained in `chrome-fixture-source.json`. Its disposable browser profile and local fixture were used throughout. The browser and synthetic native windows were closed after qualification.

## Session and input boundaries

Actual numeric HWND reuse occurred after 32,766 window creations. The stale stamp stayed invalid, and disposing it preserved the fresh stamp's validity.

The final real non-input-desktop probe requested four SendInput events and returned zero with Win32 error 5. It restored and closed its disposable desktop, kept the visible desktop unchanged, disabled further automatic input and refused a second submission without another native batch.

The fresh native prefix probe deliberately injected return prefixes zero through three. Every case returned PartialCleaned and released Control and V. Prefixes two and three delivered only the generated fixture text. These positive prefixes are fault injection. The isolated-desktop zero return is an actual Windows short return. The earlier approved BlockInput probe was not repeated.

Actual lock and disconnect notifications purged items, visible rows, reveal grants, paste targets, references, media matches, model readiness and agent connections while retaining encrypted unsaved recovery. A memory-only synthetic pin survived sign-in and reconnect.

Reconnect testing exposed reason 1 arriving before the interactive desktop was ready. Restoration now stays locked and empty until the current desktop admits cursor/work-area access, then loads history and restarts local analysis. A new revocation cancels the pending restore. The repeated real test recorded reason 1 with zero items and locked true, followed by reason 8 with fourteen restored synthetic items and locked false. It produced no new session failure. This uses the existing desktop access boundary. [Microsoft GetCursorPos documentation](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getcursorpos)

Programmatic quit initially bypassed AppWindow's user-close notification. Ctrl+Q, Settings Quit and tray Quit now share explicit unsaved admission. The live confirmation defaulted to Cancel, cancellation retained the memory-only pin, and explicit Quit anyway ended the disposable fixture. All injected write-failure triggers were removed.

Previously qualified elevated-target admission and exact process/session checks remain in the unchanged PasteInput/PasteTarget/WindowStamp components. Their actual UAC/elevated-target evidence is recorded in [the native qualification report](WINDOWS-REMAINING-QUALIFICATION-20261114.md).

## Build, installation and recovery

Final packages are self-contained ARM64 and x64 ZIP, per-user MSI and unsigned MSIX at `C:\CliphoardDev\qualified-1.2.3-arm64` and `C:\CliphoardDev\qualified-1.2.3-x64`. WiX full ICE validation and Windows SDK MSIX structural validation passed. Every payload includes the private model worker, MCP companion, compiled WinUI resources, icon and third-party notices. Test binaries and learned weights are excluded.

The ARM64 MSI upgrade and repair returned zero. All 944 installed files matched the final payload manifest. Encrypted history file hashes remained unchanged through upgrade and repair. The desktop shortcut targets `%LOCALAPPDATA%\Programs\Cliphoard\Cliphoard.Windows.exe`. The installation receipt is `C:\CliphoardDev\evidence\install-1.2.3-receipt.json`.

The normal desktop shortcut launched the installed 1.2.3.0 executable. Its process responded and no NativeTests process remained. Final visible qualification opened the bar with Ctrl+Alt+Shift+B, dismissed it with Escape and reopened it with the same shortcut. The bar remains visible with an empty query and the owner's existing preferences.

Final artifact SHA-256 values follow. Each architecture directory also contains its complete payload manifest.

| Artifact | SHA-256 |
| --- | --- |
| ARM64 ZIP | `06396556125F4A6C02E879EA186972E3ED4B401ADF9740B1B8062FF8A1D8FB8A` |
| ARM64 MSI | `15F39BF6F96C5D477F75C9784F3D764DFE66F26E3B773996D1DD7C0D1453C8F6` |
| ARM64 MSIX | `788C7CAFB5DE35318B3A9DFFE6F9FF940F673E577C33682D278DCE6684D4F32E` |
| x64 ZIP | `C07C64393EB58CB7E47061ECB149843FE5E379D7394F6A1C289E021517CFB52E` |
| x64 MSI | `6A86AF9912A564B4CC4D90C5AB54EFF8DA6E9A8D70D7F9C456990378BAFD4100` |
| x64 MSIX | `E2C6BB98FDA6F3E629417EA3E489E495DDED57E0FEBE095BD6740F4E2A57E444` |

A build-space incident earlier exhausted host headroom and interrupted the guest. Task-owned duplicate stages and regenerable caches were removed, supported virtual-disk compaction recovered space, and the guest filesystem scan reported no problems. A temporary 2 GB recovery boot was used. Original guest RAM was restored to 6 GB. The final clean packages and all-file hash verification supersede the interrupted installation. Encrypted rollback copies and earlier rollback installers remain retained.

Parallels keyboard optimization is off for this VM after input qualification. Mouse optimization is restored to auto. Timed native keyboard delivery worked. Coordinate clicks remained unreliable through automation. No host shortcut, credential or security-setting changes were made.

## Search and docking follow-up, 17 November

The owner reported a floating pane and a failed `cat` query. Earlier qualification covered specific synthetic search cases and model parity. It did not establish exhaustive end-to-end UI retrieval quality. The previous completion wording overstated that coverage.

In the live installed 1.2.3 UI, a settled `cat` query eventually returned the existing cat photograph. During the query, the previous five images remained selectable. Enter during that interval submitted the stale selection. The image-only path also failed to expose its busy state as prominently as the text search path.

Docking now uses the complete monitor work-area width and bottom edge with no floating margin. Native window-position changes retain those bounds, move/size commands are refused, and display/work-area/DPI changes re-anchor the panel. Internal content-height changes retain its monitor. Summoning chooses the monitor under the cursor.

Image preparation now covers unified All and Images scopes on startup and settings changes. Preparation completion invalidates both image and unified query results. Pending drafts hide stale results, current-query ranking is visible, and paste admission refuses pending/composing/ranking states. Scope selection restores query focus. The existing authenticated, bounded, per-model cache also retains image vectors by model signature and pixel fingerprint across process restarts. Forget clears disk and memory image indexes.

Live 1.2.4 checks used the owner's reported cat image and existing generated color fixtures with the configured Gemma image backend, with all inference kept local.

| UI case | Observed outcome |
| --- | --- |
| Cold process, image scope, `cat` | Cat photograph returned after explicit searching state |
| Image scope, `feline` | Cat photograph returned |
| Image scope, `red` | Only generated red image returned |
| Image scope, `blue` | Only generated blue image returned |
| Image scope, `airplane` | No matches |
| All / Smart, `cat` | Cat photograph returned |
| Enter while first image ranking runs | Pane remained open, no stale paste |
| Windows snap-up attempt | Pane retained full-width bottom bounds |

The first uncached visual query still incurs local image embedding work. These cases establish a concrete regression matrix. Broader retrieval quality across arbitrary photographs and every model remains an evaluation task.

The 1.2.5 cross-backend check exposed OpenVision's short-label miss. `cat` and `red` produced no results, while `a photo of a cat` and `a red picture` returned the intended images. Its exported text mean exactly matches all 192 values in the shipping Mac constant. The Mac source itself documents highly anisotropic embeddings and a provisional corpus-centered relevance floor.

Caption and generic-description experiments in versions 1.2.6 through 1.2.9 were unstable. They recovered some short labels while producing false matches or suppressing valid colors as the image collection changed. Passing two-image and three-image unit cases did not predict the five-image UI outcome. Those ranking experiments were withdrawn from the final 1.2.10 build. OpenVision retains the Mac-reference corpus centering, raw query wording and 0.08 cosine floor. Temporary query and centered-image buffers are cleared. Its short-label retrieval quality remains an open qualification issue.

Final targeted Windows regression passed 180 checks per architecture across encrypted cache, content/privacy admission, detectors, session recovery, storage and OpenVision. Its 20 real-model checks cover both-tower golden parity, decoded-image controls, the single-image centering boundary and equality with the original Mac-reference scoring formula through the normal ranking entry point. Historical experimental runs also exposed color-association false positives. Full retrieval-quality qualification remains incomplete. ARM64 and x64 frontends compiled with warnings treated as errors. The x64 runtime checks used ARM64 emulation.

The 1.2.10 ARM64 upgrade returned zero. All 944 installed files match the package manifest and encrypted history file hashes remained unchanged during installation. Both release fixture flags were refused with exit 78. Its receipt is `C:\CliphoardDev\evidence\install-1.2.10-receipt.json`. The final package directory is `C:\CliphoardDev\qualified-1.2.10-arm64`. Superseded experimental packages were removed to recover disk headroom. Stable baseline and final installers remain retained.

The final installed 1.2.10 UI was checked with Gemma selected. A freshly typed `cat` query passed through the visible pending state and returned the cat photograph as its sole result. An earlier no-match observation did not reproduce on retyping, and its cause remains unconfirmed. Windows snap-up retained the bottom bounds. Escape followed by the global shortcut reopened the pane at the bottom with an empty focused query and all five images visible. The app was left running in that state, with Gemma and Image mode selected. Testing also selected the stored All scope, which Image mode overrides. Broader model retrieval quality and physical multi-monitor behavior remain unqualified.

| Artifact | SHA-256 |
| --- | --- |
| ARM64 ZIP | `99064F90BC90731321CB83B36115621833839D3ADE33253FB7CE189F483A838B` |
| ARM64 MSI | `E13D47339842DE4AD5A686116D6B77161A64B4003F2466F8BB085A8256507C76` |
| ARM64 MSIX | `A9AA0F60C7C102E637FEE85817EEF208A9915725AEAAB5A5967E0BD05ECA0468` |

## Search model evaluation, 17 November

The first repeatable retrieval evaluation uses 16 generated text clips with 24 labelled queries and eight generated images with 12 labelled queries. The text corpus includes paraphrases, near-topic distractors, short exact clips, case/space variants, Unicode, code, a manual tag and four absent topics. Image collections cover a single image, two colors, eight mixed drawings/color/text/blank images and a duplicated image. Expected labels describe targeted retrieval within these synthetic collections.

The Windows ARM64 guest measured 336 baseline text queries, 96 baseline image queries and 336 post-fix text queries, giving 768 query observations. Baseline application scoring is commit `c0c56d0`, with the evaluation harness added. All five text models were exercised, including both Ogma projection heads, in Neural and Smart modes. The manual-tag case uses Tag mode in each matrix. Both image models used the shipping ranking entry points. Preparation used cached, hash-verified assets with downloads disabled. Gemma's packaged x64 worker runs under Windows ARM64 emulation. No owner clips entered this corpus.

The new NativeTests commands are `--search-evaluation-text` and `--search-evaluation-images`. They emit per-query admitted IDs, scores, relevant rank and elapsed time, together with hit@1, hit@3, reciprocal rank, precision@3 and absent-topic false-positive rate. Quality measurements retain failures without changing their labels. Raw baseline and post-fix observations are in `ports/tests/results/search-evaluation-20261117.jsonl`. The first Neural query includes cold document indexing, while subsequent queries and Smart mode reuse memory vectors. Timings are single observations.

Two Windows search-policy changes have been implemented. Neural and Essence respect their relevance threshold when every candidate falls below it. Exact substring matches receive full length confidence, allowing short exact clips to retain their semantic score. The latter preserves the existing score formula for other clips. Manual tags and Smart exact-match bonuses remain active.

The previous top-eight fallback comes from the current Mac implementation. Removing it is a deliberate Windows relevance-policy change prompted by this evaluation and the owner's reported search failures. It reduces irrelevant results and also withholds some relevant low-scoring guesses. Thresholds and model weights retain their existing values.

Each text configuration has 20 positive cases and four absent topics. Hit@1 is the fraction of positive cases whose first admitted result is relevant. The absent-topic rate counts a query as false-positive whenever any result is admitted. Precision@3 uses the labelled relevant set and includes negative queries.

| Text model / head | Mode | Hit@1 before | Hit@1 after | Absent-topic rate before | Absent-topic rate after | Precision@3 after |
| --- | --- | --- | --- | --- | --- | --- |
| hashing-256 / 256 | neural | 65% | 65% | 100% | 100% | 29% |
| hashing-256 / 256 | smart | 65% | 65% | 100% | 100% | 28% |
| open-ogma-micro / 384 | neural | 85% | 80% | 100% | 0% | 89% |
| open-ogma-micro / 384 | smart | 90% | 90% | 0% | 0% | 90% |
| open-ogma-micro / 1024 | neural | 95% | 90% | 100% | 0% | 90% |
| open-ogma-micro / 1024 | smart | 100% | 100% | 0% | 0% | 83% |
| open-ogma-small / 384 | neural | 90% | 95% | 100% | 0% | 95% |
| open-ogma-small / 384 | smart | 100% | 100% | 0% | 0% | 95% |
| open-ogma-small / 1024 | neural | 95% | 95% | 100% | 0% | 95% |
| open-ogma-small / 1024 | smart | 100% | 100% | 0% | 0% | 95% |
| all-MiniLM-L6-v2 / 384 | neural | 100% | 100% | 100% | 0% | 70% |
| all-MiniLM-L6-v2 / 384 | smart | 100% | 100% | 25% | 25% | 60% |
| embeddinggemma-2-740m / 768 | neural | 90% | 100% | 100% | 100% | 30% |
| embeddinggemma-2-740m / 768 | smart | 100% | 100% | 100% | 100% | 30% |

Ogma and MiniLM Neural rejected all four absent topics after the fix. Ogma Micro still misses some meal/weather/dog paraphrases and the short Unicode query at the current floor. Ogma Small Neural misses the food paraphrase while Smart finds a relevant clip. Gemma text remains poorly calibrated for rejection, admitting results for all four absent topics and averaging over fourteen results per query. Hashing also admits unrelated results. MiniLM Smart admits one of the four absent topics. Higher top-rank accuracy alone therefore does not establish useful selectivity.

| Image backend | Single red hit@1 | Two-color hit@1 | Mixed-eight hit@1 | Duplicate-red hit@1 | Absent-topic false positives |
| --- | --- | --- | --- | --- | --- |
| OpenVision Tiny | 0% | 100% | 90% | 90% | 0 in this corpus |
| EmbeddingGemma 2 | 100% | 100% | 100% | 100% | 0 in this corpus |

OpenVision's single-image failure follows directly from the corpus-centering admission boundary. Its mixed-image miss is `feline`, while `cat` and the drawing phrase return the generated cat. This differs from the earlier five-image photograph collection and demonstrates collection-dependent quality. Fixed calibration or a singleton strategy needs independent examples before a ranking change is released. The eight synthetic images and two absent object queries provide narrow coverage. Photographs, large histories, varied languages, speech/video retrieval and broad UI matrices remain evaluation work.

The candidate's ordinary Debug UI used the existing marker-guarded synthetic profile, populated through HistoryStore with the corpus. Ogma Small 1024 Neural returned the three-character `red` clip alone, rejected `quasar redshift measurements`, and returned the kitten text for `cat`. Gemma Image returned the generated cat for `cat` and `feline`, and rejected `airplane`. Pending states were visible before completion. The UI also exposed a stale text-index progress notice after completion, which remains a follow-up issue. These observations cover selected UI cases.

The targeted post-fix regression suite passed 174 checks on ARM64 and 174 in a separate x64 runtime under emulation. It covers tag/relevance policy, authenticated embedding cache, content detectors, privacy policy and OpenVision golden parity. An initial x64 invocation used the ARM64 runtime and was rejected before tests executed. The corrected run used `C:\Program Files\dotnet\x64\dotnet.exe`. The ARM64 frontend built and packaged with warnings treated as errors. MSI ICE and MSIX structural validation succeeded.

Version 1.2.11.0 was installed through the per-user MSI. All 944 installed files match its manifest, encrypted history hashes were unchanged through the upgrade, and both Release synthetic fixture flags returned exit 78. The guest receipt is `C:\CliphoardDev\evidence\install-1.2.11-receipt.json`. Packages are retained in `C:\CliphoardDev\qualified-1.2.11-arm64`.

The installed normal-profile UI was reopened through the global shortcut. With its existing Gemma image choice and Image mode, a freshly typed `cat` returned the owner's reported photograph as the sole result. The app was left running with that result visible and the pane docked above the taskbar. The generated evaluation corpus remains confined to NativeTests and the marker-guarded test profile.

| 1.2.11 artifact | SHA-256 |
| --- | --- |
| ARM64 ZIP | `6910C6A770616925759A65448150CDB473982223FC812FDE80C0E8240475BA8A` |
| ARM64 MSI | `7DAE41B6B324572A68992B7FAF2168AEB74BA8BC007371DF04E86CA1F031C286` |
| ARM64 MSIX | `7C3D58099430EE794B886118C6909B2C4687979B9595C65536C88DF4A39E8AF8` |

## Visual integration follow-up, 17 November

The owner reported that the pane looked out of place. Live inspection showed a bright native frame enclosing the dark palette, a permanent full-width model-readiness notice, and image previews cropped to fill their cards.

The docked window now owns the full client area through its non-client calculation, recalculates that frame when positioned, and suppresses the DWM border color on the main pane. Settings use their ordinary window treatment. Image previews fit the complete image with an eight-DIP inset. Model readiness and text-index progress use the existing footer. Text progress callbacks require a currently running matching query, preventing a completed search from leaving an old progress notice in the pane.

The Debug synthetic profile qualified the automatic light palette and Midnight Glass through the Appearance UI. Full generated image previews, keyboard focus, shortcut dismissal/reopening and Windows snap-up attempts were exercised. The installed normal profile qualified its existing dark palette with the reported cat photograph and generated images. The theme catalog regression covers 18 choices and three layout settings. These are selected visual checks on the guest's single display.

The ARM64 and x64 targeted suites each passed 111 checks, comprising 44 theme checks, 49 privacy-policy checks and 18 tag/relevance checks. ARM64 Debug and Release frontends built with warnings treated as errors. MSI ICE and MSIX structural validation succeeded. Version 1.2.12.0 installed through the per-user MSI. All 944 files match its manifest, encrypted history hashes were preserved during installation, and both Release fixture flags returned exit 78. The receipt is `C:\CliphoardDev\evidence\install-1.2.12-receipt.json`.

The final installed UI returned the reported cat photograph for `cat`, displayed the fitted image and footer readiness, and showed the docked pane without the bright native outline. The app was left open with that result visible.

Superseded 1.2.10 and 1.2.11 unpacked build payloads were removed for disk headroom. Their manifests and installers remain in their qualification directories. The final package directory is `C:\CliphoardDev\qualified-1.2.12-arm64`.

| 1.2.12 artifact | SHA-256 |
| --- | --- |
| ARM64 ZIP | `CBB84B1D4F5260102D9E13AA8FA80EDD0D089A3343857898F52EF6E6668ADDAE` |
| ARM64 MSI | `A3FA74E8E41F71242CDFEA97E77FB370618C13AD3D8C0CEF7C47865FBD5ED592` |
| ARM64 MSIX | `42349D4686C1E56AFC1CBEE72DD0266707B4EF3859320679802817A536B9B160` |

## Platform-specific qualification limits

- Physical x64 hardware remains untested. x64 suites and binary admission checks ran under ARM64 emulation.
- Successful Windows Hello reveal requires an owner-configured verifier. This guest qualified unavailable-verifier refusal and the complete content-bound grant/expiry policy. Its account/security configuration was preserved.
- Media and image codecs depend on codecs installed in Windows. Unsupported formats fail within the bounded local worker.
- Local packages remain unsigned. Publisher signing, trusted MSIX installation and store publication require distribution credentials and release scope.
- This owner qualification build exposes the implemented workflows without a new Pro gate. Offline signed-key verification is implemented. macOS StoreKit purchase/restore surfaces remain platform-specific.
- Native Windows sounds, Windows Hello, startup registration and WinUI materials provide the corresponding Windows integrations. Mac runtime/model formats are converted to the reviewed Windows runtime formats described in the model report.
