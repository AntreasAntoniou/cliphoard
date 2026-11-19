# Windows benchmark

`ports/windows/Run-Benchmark.ps1` runs generated fixtures against the production classes linked by NativeTests and PolicyTests. Each suite gets a fresh process, a time limit, stdout and stderr logs, and a JSON result. A unique run directory contains `results.jsonl` and `summary.json`, including executable hashes, assertion counts and elapsed times. Nonzero exits, missing success receipts, timeouts and failed retrieval expectations fail the run. Runs continue after a failed suite so the report retains the remaining coverage.

Build both fixtures on Windows with the .NET 10 SDK, using the chosen runtime.

```powershell
dotnet build ports/windows/NativeTests/NativeTests.csproj -c Release -r win-arm64 -p:RestoreLockedMode=true
dotnet build ports/windows/PolicyTests/PolicyTests.csproj -c Release -r win-arm64
$benchmark = [scriptblock]::Create([IO.File]::ReadAllText("$PWD/ports/windows/Run-Benchmark.ps1"))
& $benchmark -Executable "$PWD/ports/windows/NativeTests/bin/Release/net10.0-windows10.0.19041.0/win-arm64/NativeTests.exe" -PolicyExecutable "$PWD/ports/windows/PolicyTests/bin/Release/net10.0/win-arm64/PolicyTests.exe" -OutputDirectory "$PWD/benchmark-results" -Repeat 2
```

Loading the reviewed script as a script block supports the guest's existing restrictive execution policy. System execution policy stays in effect. NativeTests builds its private model worker and companion into its own output directory. This also supports x64 fixtures under ARM64 emulation without borrowing another build output.

## Coverage

The default 23 suites cover hashing and detector parity, secret and representation safeguards, theme persistence, encrypted storage migration and corruption, concurrent writers, transactional rollback, embedding caches, tag baskets, archive authentication and large streaming archives, manager imports, document extraction, perceptual images, agent protocol and directory boundaries, companion isolation, speech protocol boundaries, capture suspensions, paste-input policy, transparent theme icons and bundled copy sounds.

The workflow suite adds composed and decomposed accents, CJK, Arabic, Hebrew, emoji, line endings, whitespace, bidi controls, maximum-length text, deduplication metadata, pinned retention, limits, repeated imports and invalid-write recovery. All data is generated in temporary fixture directories. The default suites leave the live clipboard alone.

`-IncludeModels` adds cached-model golden checks, model switching, speech and media. `-IncludeSearchEvaluation` adds the labeled text and image retrieval matrix from `SearchEvaluation.cs`. These paths use verified cached assets with implicit downloads disabled. Allow a larger per-suite timeout for model runs, such as `-TimeoutSeconds 1800`. Use `-Only workflow,input-policy` to rerun selected enabled suites.

Retrieval acceptance requires a relevant result in the first three positions for answerable queries and an empty result for absent topics. Raw per-query rankings and scores remain in each suite's stdout log. These strict expectations deliberately expose the existing model quality gaps. Passing model golden checks alone does not satisfy retrieval acceptance.

## Qualification limits

The runner exercises production classes through synthetic fixtures. Live UI capture and paste, physical input after Mac/Windows focus changes, layout across displays, Windows Hello, elevated targets, real lock/disconnect events and installer upgrades require their corresponding interactive qualification. ARM64 guest results and x64 results under ARM64 emulation identify their actual execution environment. Physical x64 qualification remains separate.

## 18 November 2026 results

The ARM64 core run completed 42 suite invocations across two repetitions, with 1,370 assertions and zero failures. Its receipt is `ports/tests/results/windows-benchmark-core-20261118.json`. NativeTests and PolicyTests built in the Windows guest with zero warnings and errors.

The workflow cases exposed a durable-write defect. HistoryStore could save text containing NUL or exceeding 65,536 characters, then reject that database on reopening. `HistoryStore.Save` now applies the existing state validator before the database transaction. Invalid changes remain unsaved in memory and the previous durable history remains readable. Both repetitions passed the recovery regression. The fix is included in the installed 1.2.13 application.

The initial extended run measured 336 text queries and 96 image queries. Text retrieval missed 37 top-three or empty-result expectations. Image retrieval missed four expectations, all in OpenVision. Its singleton collection missed both red queries, and the mixed and duplicate collections each missed the feline query. Gemma image retrieval passed all 48 cases in this small generated corpus.

Ogma, OpenVision, Gemma, model switching, media indexing and media decoding passed their fixture checks. All three speech models recognized the generated phrase. The initial runner incorrectly marked speech failed because its success receipt uses `speech_models`, whereas the counter expected a name ending in `_checks`. The runner now recognizes that receipt. The original failed receipt is retained in `windows-benchmark-models-initial-20261118.json`. A subsequent ARM64 run passed all seven model suites with 322 checks, including the corrected speech count. Its completed receipts are retained in `windows-benchmark-arm64-partial-20261118.jsonl`. That bridge invocation interrupted during retrieval evaluation and has no completed summary; it is not treated as a fully passing run.

Raw rankings and scores are retained in `search-evaluation-text-20261118.jsonl` and `search-evaluation-images-20261118.jsonl`. No quality thresholds were relaxed to produce passing results. The corpus remains small and synthetic, so these measurements do not establish exhaustive UI search quality.

Parallels 27.0.3 logged `[HID_CTL] Invalid mouse grabber` at 22:18:04 and 22:18:23 UTC during native-window/guest focus transitions. Keyboard input worked after idle and two settings round trips, then stopped again after a mouse click. Auto-detect mouse mode was confirmed persisted through both configuration reopen and `prlctl list -i`. The guest keyboard/mouse devices reported healthy, its Parallels Tools service was running, and keyboard/mouse class filters contained the standard Windows drivers. Host Accessibility and PostEvent grants were present, and no Secure Input owner was observed. These observations identify a reproducible console-routing failure without establishing its durable repair.

The disconnected, regenerable 6.5 GB Windows installation ISO was removed from the Parallels download cache, restoring host headroom to 9.1 GiB before the updater suspended Windows. The owner approved the updater's license agreement. Parallels Desktop and the guest Tools were then verified at 27.1.0 build 58756, with Windows running and Auto-detect mouse mode retained. The owner confirmed that typing and mouse input through the remote Mac desktop remained working after several Mac/Windows switches. Host headroom subsequently reached 10 GiB. Automated guest keystrokes remained less reliable than the owner's remote input, so this does not establish exhaustive automation reliability.

The Windows icon now uses transparent mascot artwork with light and dark variants in `ports/windows/Cliphoard.Windows/Assets`. The bar and window icon follow the selected application theme. The notification-area icon follows the Windows taskbar theme and refreshes when system colors change. The default desktop icon uses the white mascot. `Scripts/make-windows-icons.swift` encodes eight standard ICO sizes while retaining alpha. Forty-nine Windows asset checks cover PNG transparency, palette contrast and Win32 icon loading at 16 through 256 pixels. The artwork was edited with the built-in ImageGen tool to remove the background tile, create an inverse palette, and give the dark pouch small solid oval eyes and a subtle smile. Light and dark synthetic bar previews were inspected in the Windows guest. The installed light-theme bar and transparent desktop shortcut were also observed.


The final x64 core run completed 22 suites and 734 checks with zero failures under ARM64 emulation. Its receipt is `windows-benchmark-x64-20261118.json`. Two initial failures came from missing private worker binaries in the test output. The fixture build now provisions its own worker and companion. After rebuilding with zero warnings, all x64 suites passed. ARM64 manager-import, document and companion reruns passed 59 checks. The earlier interrupted ARM64 run had completed 22 core suites with 734 checks before all seven model suites passed.

The dedicated retrieval rerun completed all 432 queries and reproduced the same 37 text and four image misses. Both quality suites remain failed in `windows-benchmark-quality-final-20261118.json`. These are recorded product quality gaps, not waived expectations.

The final per-user ARM64 MSI upgrade to 1.2.13.0 succeeded. All 948 installed payload files matched the package manifest, and the existing encrypted history database and legacy history file retained their exact pre-install SHA-256 hashes. All four synthetic launch flags returned 78 in Release. The installed app was relaunched and its bar rendered with the revised icon. The receipt is `windows-install-1.2.13-20261118.json`.

Final artifacts remain in `C:\CliphoardDev\qualified-1.2.13-final-arm64`:

| Artifact | SHA-256 |
| --- | --- |
| MSI | `197436DDA003472529E3DF61152B2B112E3D4843897AEB21D74EC7C479531D83` |
| ZIP | `FC02EB5EFDA9BC38B4471E84F345545E88B252E7878DA6894186D81A0785767E` |
| MSIX | `760477D3FD2798D39FFCFAAA08C1C098B97DA0EBCD852D4B291D2041464F8456` |


## 19 November: supplied branding, image previews and copy sounds

The pane previously decoded every PNG at only 64 pixels wide, including full inspectors. DIBs used a fixed 720-pixel decode. Clipboard cards now request 1,024 pixels for either representation, while inspectors leave decoding at original resolution. The logo retains its separate small decode. This changes presentation only; capture, durable image payloads, paste conversion and privacy checks retain their existing behavior.

The owner supplied the approved teal mascot and purple-backed app icon. The exact transparent PNG is used in both bar themes, without regenerating its face or recoloring it. The app icon is encoded from the supplied 256-pixel icon into standard Windows ICO frames. These supersede the provisional monochrome mascots above.

Twelve original, bundled copy cues join the five existing Windows sound aliases: Soft tick, Click, Pop, Bubble, Glass, Bell, Chime, Pluck, Drop, Ripple, Woodblock and Sparkle. Settings exposes the full list under Copy sound and retains its Preview sound button. Existing choices remain valid. `Scripts/make-copy-sounds.py` deterministically generates short mono PCM WAVs without external samples. The sound fixture checks Windows WAV loading, distinct content, bounded length and peak level, plus persistence for every choice. It does not play audio during automated tests.

The ARM64 guest run completed 23 suites and 860 checks with zero failures, including 126 sound checks and 49 branding checks. The application Debug and Release builds completed with no warnings or errors. The 1.2.14.0 MSI, ZIP and MSIX passed packaging validation. The synthetic PNG and DIB cards rendered matching fine detail in the guest; the PNG inspector also rendered sharp original-resolution detail. The owner then closed the installed app normally for the upgrade.

| 1.2.14 artifact | SHA-256 |
| --- | --- |
| MSI | `D00346A80D6D17A4B0A2517E0F8D7080660239A29F509C6E91E3FA64006085E1` |
| ZIP | `A06789C3C29A6D08DC6C038B275CAF850B3C4B5C3F586FF2F1FE5DCF88CB4718` |
| MSIX | `8AC9003E34FC3F9238B33887DECF2952D865FA8417791F809D3DFBEC9CE1851D` |

The per-user 1.2.14.0 MSI upgrade succeeded. All 960 installed files matched the manifest, and all four history files present at upgrade retained their exact hashes. The installed bar was relaunched and displayed the supplied teal logo with sharp photo previews. Settings opened, although automated General navigation was dropped by the guest, so the expanded sound selector was not visually qualified in this session. WAV loading and persistence for all 17 choices passed fixture checks. The installation receipt is `windows-install-1.2.14-20261119.json`. The synthetic fixture dispatcher now rejects unknown options with exit 78 rather than falling through into interactive input tests.
