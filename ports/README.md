# Cliphoard Windows app and native-port fixtures

The default Windows executable now opens a standalone clipboard manager: automatic capture, encrypted local history, horizontal cards, substring search, category filters, pin/delete/copy, guarded paste, pause/settings and tray access. Launch `Cliphoard.Windows.exe` with **no arguments**, or use the **Cliphoard Windows** desktop shortcut in the development guest. With Windows focused, **Ctrl+Alt+Shift+B** opens/closes the bar; on a Mac keyboard that is **Control+Option+Shift+B**. Double-click a card or press Enter to paste.

Windows now also has optional launch-at-login, capture sound, user tags and tag filtering, source-app exclusions, PNG/HTML clipboard support, encrypted shared Mac/Windows backup/import, all Mac text-model choices for Smart/Neural search, OpenVision/Gemma image search, Whisper Small/Large v3/Turbo WAV transcription and Windows OCR. These are distinct from full Mac feature parity; [the live acceptance matrix](docs/WINDOWS-FEATURE-STATUS-20261115.md) lists what is implemented, tested and still missing.

The Mac visual system is now available in Windows: all **18 shipping themes**, **Card Strip / Spotlight Palette / Compact List**, live height adjustment, an inspector and Windows keyboard equivalents. Open Settings with **Ctrl+,** and choose Appearance. [Visual parity and qualification](docs/WINDOWS-MAC-APPEARANCE-20261115.md).

See [the normal-app qualification](docs/WINDOWS-APP-20261115.md) for scope and results. The explicit `--synthetic-fixture` mode below is available in Debug builds. Neither mode enables the unfinished per-user service or production named pipe.

## Earlier foundation scope

This private first slice implements a bounded shared Rust history engine and stages a C#/WinUI3 Windows fixture frontend. It preserves the existing macOS app. It is not a complete Windows release, secure service, persistence implementation or model port.

The Rust engine and WinUI frontend now compile and run on Windows 11 ARM64 with generated synthetic text only. The first native checks passed on 14 November 2026: 8 Rust tests, 86 process checks, 9 C# policy checks and 3 Windows pipe-reader regressions; the locked WinUI build has zero warnings. Live fixture seeding, substring search, marked clipboard capture, clear and Escape dismissal were observed. Initial shortcut reopening failed through the nested VM route; subsequent [local Parallels qualification](docs/WINDOWS-REMAINING-QUALIFICATION-20261114.md) verified reopening and native input safeguards. Ubuntu's later GTK4 frontend is outside this slice.

## Run the qualified synthetic engine

From `ports/engine`, Rust1.100.0 is pinned in `rust-toolchain.toml`; dependencies and checksums are in `Cargo.lock`, with exact direct versions in `Cargo.toml`. Use at most2 build jobs:

```sh
export CARGO_BUILD_JOBS=2
cargo +1.100.0 test --locked
cargo +1.100.0 fmt --check
cargo +1.100.0 clippy --locked --all-targets -- -D warnings
cargo +1.100.0 build --locked
/opt/homebrew/bin/python3.14 ../tests/smoke.py
```

`cliphoard-engine --synthetic-stdio` accepts the bounded framed protocol in [PROTOCOL.md](docs/PROTOCOL.md). This transport is an explicitly opted-in test fixture, including for the Windows fixture's owned child process. Ordinary invocation, `--windows-service`, extra arguments and all other modes refuse with exit78. There is no TCP listener or unauthenticated production IPC fallback.

The standalone C# selection-epoch guard also links the actual production source and passed9 checks under the exact user-local MacARM64 .NET10.0.404 SDK. The same 9 checks also pass natively on Windows ARM64; they do not substitute for desktop target/focus/paste qualification. From `ports/windows`, run `dotnet run --project PolicyTests`.

The test suite covers capture/dedup identity and recency, pin-preserving trim, all-pinned refusal, search/select, clear, permanent lock/purge, fixture markers, bounds, version/op/key/UTF8 failures and frame truncation. The process smoke checks actual framing, lifecycle, domain roundtrips, error exits and production-mode refusal with a3-second per-operation bound. All inputs are generated synthetic fixtures.

## Windows fixture, first ARM64 qualification

Windows must have the exact .NET SDK10.0.404 pinned in `windows/global.json`, Visual Studio's native Windows/WinUI tooling and the Windows SDK needed for the10.0.19041.0 target. The direct Windows App SDK NuGet package is pinned to1.8.260921001, a supported1.8 servicing release, not claimed to be the newest major. See [official sources](docs/SOURCES.md).

In a native Windows developer environment:

```powershell
cd ports\engine
$env:CARGO_BUILD_JOBS = '2'
cargo +1.100.0 build --locked --release --target x86_64-pc-windows-msvc
cd ..\windows
# ARM64 needs a native ARM64 build and separate desktop qualification.
dotnet build .\Cliphoard.Windows\Cliphoard.Windows.csproj -c Debug -p:Platform=x64 -r win-x64 -p:RestoreLockedMode=true -p:TreatWarningsAsErrors=true
```

The x64 standalone app and regression suites now build and run under Windows ARM64 emulation. The earlier Rust-linked fixture sequence above has separate historical scope. The native ARM64 run uses `cargo test --locked -j 2`, an explicit Python 3.14+ interpreter for `../tests/smoke.py`, then the same frontend command with `Platform=ARM64` and `-r win-arm64`. The NuGet transitive graph is pinned in `windows/Cliphoard.Windows/packages.lock.json`; all package entries carry resolved versions and content hashes.

Place the resulting Windows `cliphoard-engine.exe` beside the Windows frontend executable in its private build output. Launch `Cliphoard.Windows.exe --synthetic-fixture`. No other startup mode enables the fixture. Rust `cargo check` cross-target success on a Mac is not a linked Windows binary or a Windows/WinUI compile.

The fixture implements generated history, substring search and select; a marked native clipboard fixture; Ctrl+Alt+Shift+V and Ctrl+Alt+Shift+B hotkeys; a pointer-monitor work-area bottom panel; Esc return and dismissal on focus loss; same-user/session retained-process target validation; and one paste attempt with copy-only fallback if focus/modifiers/input privilege prevent it. Session lock or Lock & purge hides/drops fixture content and permanently locks the engine until restart.

For manual VM testing from a Mac, use **Control+Option+Shift+B** with the Windows guest focused. This alternative was added on 15 November 2026 because the Mac could intercept the V combination for its local Cliphoard. Both guest registrations use no-repeat and are released when the fixture exits. The status line identifies which shortcut arrived. Host app shortcuts/settings are unchanged.

The clipboard adapter first checks a custom format and exact private per-run marker, then and only then requests bounded Unicode text with the explicit synthetic prefix. Clipboard data without that marker is not read. Own writes are suppressed by sequence. Clicking the marked-fixture action or selecting a fixture intentionally replaces the current clipboard; it does not back up or inspect its previous contents.

## Security and next acceptance

Production Windows named-pipe authentication is deliberately **not implemented or qualified**. The required current-user SID ACL, remote-client rejection, first-instance protection, client OS identity and client-side server owner/session/PID checks are recorded in [SECURITY.md](docs/SECURITY.md). No request claims a SID or grants access based on JSON. Service startup remains closed until native implementation and adversarial tests pass.

The standalone UI adds DPAPI persistence and bounded real text/rich-text, file-list and bitmap capture without service IPC. Current model qualification is recorded in [the model report](docs/WINDOWS-MODELS-20261116.md). Earlier OCR, archive and packaging qualification is recorded in [the parity report](docs/WINDOWS-PARITY-20261116.md). Signed distribution, native x64 hardware qualification and the remaining specialist Mac features are pending. Logical lock/purge is not secure memory zeroization. [NATIVE-ACCEPTANCE.md](docs/NATIVE-ACCEPTANCE.md) lists exact pending Windows checks.
