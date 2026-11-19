> Follow-up: [remaining qualification](WINDOWS-REMAINING-QUALIFICATION-20261114.md) adds real session events, elevated-target refusal, exact numeric HWND reuse and a real short SendInput return. Historical limitations below are preserved.

# Windows input qualification on Astrapé, 14 November 2026

This is a synthetic-only ARM64 qualification after checkpoint `2d5c31c`, not production or release approval. All changes are within `ports/`. Ordinary and unknown startup modes remain disabled. No owner clipboard, history, models, credentials or MacBook UI were used. VM sharing restrictions and host services were preserved.

## Local GUI access and reopening

Host `astrape`, Python 3.14.3. The approved local `com.parallels.desktop.console` surface exposes the existing Windows 11 VM and accepts forwarded key input. The VM Dock Helper route timed out; no permission/TCC/security setting was changed. The prior nested Screen Sharing failure was not reproduced locally. No posted WM_HOTKEY was used as keyboard proof.

The existing modifier mask `0x4007` was retained. Repeated Escape/reopen worked, including a 1.5-second held combination with one additional delivery; the final build reached delivery count 4 after the expected four shortcut invocations. Native collision tests received Win32 error 1409, then successfully registered after unregistration. Panel presentation now explicitly requests and verifies native foreground admission; denied activation hides/refuses rather than accepting a selection in a background panel. No focus-attachment or privilege bypass is used.

## Changes

- Rows use explicit string content with a separate stable row map, avoiding private-record reflection/WinRT wrapping. Enter commits the selected row through a handled-event listener; an explicit Paste selected button uses the same path.
- Selection retains pre/post-response epoch checks, rechecks foreground/identity before clipboard mutation, and separates intentional synchronous focus handoff from dismissal. Search changes and Clear invalidate queued selections. F6 arms a one-second delay for the next synthetic selection so stale-response paths can be exercised through the real UI.
- A unique named window property stamps the captured window incarnation. Validation requires that stamp in addition to the retained original process handle, PID, SID and session. Destruction/recreation loses authority even within the same live process; disposal removes only this instance's marker. SetProp failure refuses the target, including denied integrity boundaries.
- Paste owns LEFT Control and V only. A responsive dedicated keyboard-hook thread tracks external ownership of those two keys without retaining or logging text. Own injections carry a run marker. Partial-prefix accounting releases only unmatched owned key-downs, excludes externally held keys, attempts one bounded cleanup batch and never retries the paste chord. Any partial result disables further automatic input for that run. Cleanup rejection reports PartialUnresolved; it is not represented as repaired or inserted text.

## Final native checks

Windows 11 ARM64; .NET 10.0.404. Frontend and NativeTests builds succeeded with zero warnings and zero errors using the existing restore and pins. Policy output is cumulative: **150 total assertions**, not 9 + 23 + 150. **12 native assertions** cover window-stamp destruction/recreation/disposal, actual hotkey collision/re-registration and ARM64 INPUT layout (40 bytes).

The final build was exercised with local Parallels GUI keys and the owned WinForms synthetic editor:

| Case | Observed result |
| --- | --- |
| Enter paste of rust fixture | Exact 55-character string once; one WM_PASTE and one text change; foreground/editor focus true. Clipboard notification arrived with editor focus already restored. |
| Escape, repeated reopen, no-repeat | Panel dismissed/reopened; held shortcut added one delivery. |
| Held Control + Enter | Selection explicitly refused; no clipboard or editor change. |
| One-second selection across Escape/new epoch | Refused; sequence stayed 186 and editor remained at one paste. |
| One-second selection followed by competing activation | Panel dismissed; sequence stayed 186 and editor remained at one paste. |
| Captured editor closed during delayed selection | Editor exited; sequence stayed 226. |
| Recreated editor plus delayed selection and fixture Lock & purge | Editor stayed empty with zero paste messages; sequence stayed 226; locked fixture did not reopen. |
| Native truncated prefixes 0/1/2/3 | Control and V released in all cases; inserted lengths 0/0/44/44. No chord retry. |

Machine-readable synthetic receipts are in [evidence-20261114](evidence-20261114). Native prefix probes deliberately truncate the first real SendInput submission; they do not claim naturally occurring OS short returns. Unit checks cover all prefix lengths, external key ownership combinations and cleanup rejection.

## Limits and preserved failures

- Numeric HWND equality was not forced (`same_numeric_hwnd=false`). Native window destruction/recreation and marker lifetime were tested; numeric reuse is guarded by the incarnation marker rather than assumed safe from PID alone.
- Actual OS lock/disconnect/logoff delivery and elevated-target/UIPI GUI behavior were not exercised. The fixture purge was tested without locking the OS or requesting elevation/new permissions. Production remains gated.
- Windows can refuse cleanup input too. That path is simulated in policy tests, fails closed for further automatic paste and reports unresolved cleanup; no guarantee of OS acceptance or insertion is claimed.
- Early builds were blocked by the owned running executable; only that fixture/engine was stopped before rebuilding. Parallels guest execution intermittently returned Invalid argument. Source-only transfers now use separate bounded, idempotent retries; build/test/launch commands are not automatically retried. An attempted reflection-only clipboard-format diagnostic failed; no clipboard payload was read by that diagnostic.
- Earlier overlapping native probes and a Space-start contamination were rejected as evidence. The final probe run is serialized, starts after the initiating key releases and has the expected 0/0/44/44 insertion lengths.

The owned frontend, engine and editor were stopped; final process inspection returned zero fixture processes. VM stayed running. Host free capacity was 15 GiB at final inspection (28 GiB at initial checkpoint); no unrelated cleanup was performed. No release, push, deployment or canonical-record changes.

## Reproduction

Use Python 3.14+ on Astrapé. `ports/tests/guest-run.py --sync '<PowerShell build/test command>'` copies repository Windows source files only into the existing C:\CliphoardDev\src tree. It never transfers binaries, runtimes, history, models or authentication files. GUI qualification must use the local Parallels surface after code commands finish; guest exec consoles can otherwise interfere with foreground observations.

Build NativeTests for `win-arm64`, run its ordinary mode while the frontend is stopped for the collision test, and run PolicyTests. Launch NativeTests with `--editor` and the frontend with `--synthetic-fixture`. Seed, Escape, focus the editor, invoke Ctrl+Alt+Shift+V, select a row and press Enter. F6 arms delayed-selection testing; Lock & purge is irreversible for that fixture run. `NativeTests --sequence` returns clipboard sequence metadata only.
