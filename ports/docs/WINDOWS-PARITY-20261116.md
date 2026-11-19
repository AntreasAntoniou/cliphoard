# Windows parity qualification — 16 November 2026

The subsequent [model qualification report](WINDOWS-MODELS-20261116.md) supersedes the model inventory and pending model items in this v1.0.4 report.

## Delivered functionality

The Windows app provides local MiniLM Neural and Smart search, image OCR, shared Mac/Windows `.cliphoard` archives, legacy Windows archive import and self-contained ARM64/x64 packaging. The existing 18 Mac palettes, three layouts, encrypted history, native clipboard formats, original-target paste and shortcut reopening remain available. Full Mac parity still has the pending items below.

Semantic search uses `sentence-transformers/all-MiniLM-L6-v2` at immutable revision `1110a243fdf4706b3f48f1d95db1a4f5529b4d41`, ONNX Runtime 1.23.2 CPU, uncased WordPiece, 256 tokens, mean pooling and 384-dimensional normalized vectors. Explicit Search settings acquisition downloads the pinned 90,405,214-byte model and 231,508-byte vocabulary from Hugging Face. SHA-256 pins are compiled into `SemanticEngine.cs`. Subsequent preparation verifies and loads local bytes. Clipboard text stays on the device. Model weights are excluded from application packages. MiniLM was selected because an immutable upstream ONNX artifact exists for both Windows architectures.

OCR uses installed Windows languages, bounded WIC decoding and size-aware scaling. Results persist in the encrypted history, participate in search and appear in Inspector with Copy text. Protected content vetoes OCR and semantic indexing. Preview reveal uses Windows Hello and refuses unavailable or unsuccessful verification.

Shared archives implement the shipping CLIPHRD1 v1 chunk/AAD/record format, preserving clip metadata, user tags, pins, OCR, PNG payloads and opaque image-feature/dismissal records. Windows-specific kinds and rich formats survive Windows roundtrips through extra metadata fields. Authenticated summary, manifest, record counts, payload hashes, size limits and final boundary are checked before merge. Images are compared by canonical PNG identity during import while retaining their original clipboard payload. Windows retains its 500-clip, 24 MiB content, 8 MiB image and 20-pin limits. Current clips win on duplicates. Oversized merges refuse atomically.

## Automated evidence

| Suite | Passing checks | Environment |
| --- | --- | --- |
| Semantic tokenizer, vectors, ranking and cancellation | 21 | Windows ARM64 and x64 under ARM64 emulation |
| OCR, image scaling, protected refusal and corrupt-model refusal | 5 | Both architectures |
| Shared Mac archive interoperability and malformed-input refusal | 45 | Both architectures |
| Theme/preferences | 44 | Both architectures, 18 palettes and three layouts |
| History | 29 | Both architectures, generated clipboard data |
| Clipboard formats, user labels and exclusions | 27 | Both architectures, generated clipboard data |
| Legacy Windows archive | 25 | Both architectures |

The latest seven-suite x64 run passed all 196 checks. The final native ARM64 rerun also passed 12 native input, 150 paste-policy and 22 deferred-paste checks. Together these suites cover 380 checks. Native x64 hardware remains untested. The x64 packaged frontend also opened and returned the expected meaning-only Smart search result under ARM64 emulation. ONNX Runtime emitted an unknown Apple Silicon CPU-vendor diagnostic during emulated startup, and inference completed successfully.

Nine tokenizer inputs and full embedding vectors were generated independently with upstream Hugging Face `tokenizers` and Python ONNX Runtime. C# token IDs matched exactly, with minimum reference cosine `0.9999999584268227`. Reference generation uses explicit Python 3.14 in an isolated environment. No fixture contains owner clipboard data.

`ports/tests/mac-archive-fixture.swift` compiles alongside the unchanged shipping `HistoryArchive.swift`. It generates the Mac golden imported by C# and verifies a Windows re-export with timestamps, flags, pin, Unicode tags and dismissal retained. It also authenticated the installed UI's six-clip export, checking two PNG payload hashes, the saved OCR text, pin and user label. This validates the shipping byte-format reader. Full Mac app import UI was outside this run.

## Installed UI evidence

On the installed ARM64 app, explicit model preparation completed and a meaning-only query `something to eat` returned the generated restaurant clip. Enter pasted its complete text into the disposable native editor. Searching `2026` found the generated image through OCR. Inspector displayed `SYNTHETIC CLIPBOARD 2026`, and Copy text pasted the exact recognized text into that editor.

The installed shared backup workflow passed Save As, two-field passphrase validation, encryption, Open, authentication, staged confirmation and merge. All six clips authenticated with zero new entries, including both images. The UI reported zero imported clips. OCR, the synthetic user label, Dracula and Smart mode survived restart. The disposable archive resides at `Documents\finalqualified20261116.cliphoard` in the guest.

The owner confirmed physical guest input works. Tool-delivered input also worked after raising and focusing the Parallels guest, using 80–100 ms key holds. Native host menus remained responsive during intermittent guest delivery failures. No permanent Parallels integration repair is established. No host shortcut, sharing, security, credential or VM integration setting changed.

## Packaging and installation

Version 1.0.4.0 has self-contained ARM64 and x64 ZIP, MSI and unsigned MSIX outputs. The compiled packager requires the existing .NET 10.0.404 and Windows SDK toolchain, uses locked application dependencies and pinned WiX SDK 4.0.6, and leaves PowerShell execution policy unchanged.

```powershell
dotnet run --project ports\windows\Packaging\Packaging.csproj -- C:\source\cliphoard arm64 1.0.4.0 C:\build\cliphoard-arm64
# Repeat with x64 and a separate fresh output directory.
# Supply a fifth argument with the dotnet.exe path if it is outside PATH.
```

The source root must contain LICENSE and the complete ports/windows tree. Output directories must be fresh. The packager retains WinUI PRI and XBF resources, the application icon and third-party notices. This fixes a publish-only defect where omitted XAML resources produced fallback control styling. Installed Fluent controls and Dracula were visually verified after the repair. SHA256SUMS.json inventories each ZIP payload. The MSI carries the identical payload.

MSI installs per user into `%LOCALAPPDATA%\Programs\Cliphoard` with Start menu and Desktop shortcuts. The shortcut targets the installed executable. Install, upgrade, repair, uninstall and reinstall returned zero, preserving the encrypted history hash before relaunch. Uninstall retains user history and downloaded model caches. Optional startup remains off unless explicitly enabled by the owner.

WiX's intermediate MSI satellite-language metadata is normalized to fit legacy MSI column constraints, then the final MSI passes full ICE validation. MSIX is structurally validated by the Windows SDK. Packages remain unsigned. Trusted MSIX installation and publisher signing remain pending.

Normal launch takes no arguments. The guest shortcut is **Cliphoard Windows**. With Windows focused, **Control+Option+Shift+B** on the Mac keyboard opens the bar. Release builds refuse the synthetic fixture option. The per-user background option and exact-owned startup cleanup are retained.

## Remaining parity and qualification

- Mac Ogma micro/small tiers, specialist tag baskets, model-generated facets and suggestions.
- Media-library search, transcription and the complete Mac financial/entropy/OTP/content detector suite.
- Successful Windows Hello reveal with an owner-configured verifier.
- Native x64 hardware, trusted signing/MSIX installation and automatic updates.

These gaps remain explicit in the live feature matrix. Existing HWND identity, exact process/session admission, session revocation, held-modifier refusal and short SendInput cleanup safeguards remain in force.

## Release artifact hashes

| Artifact | SHA-256 |
| --- | --- |
| ARM64 MSI | `DECACEAE7BD49A640985E2E3C50EF38A796D6DC069FCC2BC5B29BCF84E6FCF4F` |
| ARM64 ZIP | `B9244AF0464124947D6910BF66A3A31E74CC284B50D31E7FFEA9F8322574FD50` |
| ARM64 MSIX | `21FFF420D08A383268768A74630CD01E301DBD540B959829B277310C19993C23` |
| x64 MSI | `D1F6EC49322FFB84548117B81EA5C987CE631E5716980E6552D86A72BC0B33B9` |
| x64 ZIP | `DAD40E7BFE3A6DA46870F2F104182E9C657FC26663893A89ED4A8F31C1883CD8` |
| x64 MSIX | `19C6AF5998BDF4B412E3ADE4F7B57A621067B8E551BBA3A14D6E2B49F98A3EF8` |

Guest artifacts are under `C:\CliphoardDev\packages\qualified-1.0.4-arm64` and the matching `qualified-1.0.4-x64` directory. Verified MSI copies are retained in the host workspace's ignored `ports/artifacts/1.0.4.0` directory.
