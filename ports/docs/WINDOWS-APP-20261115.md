# Standalone Windows clipboard UI — 15 November 2026

The requested normal application now launches without flags. The earlier `--synthetic-fixture` harness is retained separately for regressions. Normal mode does not start the Rust engine and does not enable production service IPC.

## User workflow

Launch **Cliphoard Windows** from the Windows development guest desktop. Copy in a Windows application, open the bar with **Ctrl+Alt+Shift+B** (Mac keyboard: **Control+Option+Shift+B**, guest focused), search/filter, use arrows to select, and Enter or double-click to paste. Ctrl+C copies without a paste attempt. Escape closes and restores the previous target where possible. The purple clipboard tray icon also opens the bar; its context menu provides open, pause/resume, settings and quit. The original V shortcut remains registered, but the Mac can intercept it.

The panel has horizontal cards, text/code/link/color/image/file categories, source names, image thumbnails, recency, pinning, per-card context actions, pause/resume and scrollable settings. History size is adjustable from 50 to 500, default 200. Pins survive trimming; destructive clear affects unpinned entries only and is applied by Save. It starts capturing future copies automatically and restores saved history after relaunch. It does not read/backfill the clipboard that existed before startup or resume.

Current scope: substring search; Unicode and RTF text; CF_HDROP file lists; bounded 24/32-bit DIB/DIBV5 images. HTML-only content, PNG-only formats without Windows bitmap conversion, very large media, semantic models/search, migration, startup-at-login registration, signed distribution and native x64 qualification remain outside this implementation. Unsupported or oversized formats are skipped. See [security details](SECURITY.md) for bounds and storage semantics.

## Native ARM64 evidence

Existing isolated Parallels Windows 11 ARM64 guest; no VM sharing, security, credentials or elevation changes. Tests used generated synthetic contents only. No owner clipboard/history was inspected for test evidence.

- WinUI/.NET 10.0.404 ARM64 build with warnings-as-errors: **0 warnings, 0 errors**. NativeTests build: **0 warnings, 0 errors**.
- **29 new native history/clipboard checks passed**: DPAPI roundtrip, ciphertext not containing the generated text, dedup identity/pin preservation, trim, persisted delete, tamper refusal without overwriting saved data, bounded DIB validation, future-update capture, startup baseline, own-write suppression, exclusion/history privacy markers, bitmap copy roundtrip, file-list copy roundtrip, RTF preservation and plain-text stripping.
- **150 existing selection/input-policy checks passed**; **12 native stamp/hotkey/layout checks passed**. The prior exact numeric HWND reuse and partial-input qualifications remain in the 14 November reports; this change leaves their target stamp and PasteInput implementations unchanged.
- Invalid frontend argument: **exit78**. Second normal launch: **exit0** and **one** frontend process remains. Desktop shortcut exists. Saved history is ciphertext (718,278 bytes at the observed checkpoint; content not dumped).
- Actual guest GUI: copying generated meeting text automatically created a card; Enter returned to the original separate editor and inserted the full text. A second paste after the Fluent-resource changes also succeeded. The editor's content-free receipt reported `syntheticMeetingPasted=true`.
- Actual GUI also verified link/code capture, bitmap thumbnail rendering, live `meet` search, pin action and Pinned filter membership, pause/resume state, shortcut close/reopen, tray-icon reopen, scrollable settings and keyboard reachability of clear/quit. Relaunch restored the four generated cards and their pin state from encrypted storage.
- The Parallels/CUA route consumed activation clicks on WinUI controls. A second delivered pointer click activated the Links filter directly; Space also activated focused controls. Toolbar controls retain standard release-click semantics. Native tray and editor clicking worked directly. This route-specific activation behavior is retained here rather than hidden.

The new normal-mode unlock/reload path has not repeated the disruptive real lock/disconnect tests in this UI pass. The shared adapter still receives the actual session events qualified previously; normal mode handles them by invalidating targets, hiding, dropping history references, stopping capture, and reloading ciphertext/baselining on reconnect/unlock. Managed-memory zeroization is not claimed.

## Fixes found during this pass

Windows advances clipboard sequence state on CloseClipboard. Suppression previously recorded before close, and the first native regression caught an own-write being recaptured. Suppression now records after close; the regression passes. A running usability editor also held its DLL open during one rebuild; that owned fixture was stopped before rebuilding successfully. Earlier failed attempts are not counted as passes.

The app is left running in normal mode; the usability editor is stopped. No publication, installer, service, startup registration, host Cliphoard change, or background model download was performed.

Implementation references: [clipboard formats/privacy markers](https://learn.microsoft.com/en-us/windows/win32/dataxchg/clipboard-formats), [current-user/session named synchronization options](https://learn.microsoft.com/en-us/dotnet/api/system.threading.namedwaithandleoptions?view=net-10.0), [DPAPI](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata).
