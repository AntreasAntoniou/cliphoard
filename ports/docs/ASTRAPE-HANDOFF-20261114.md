> Historical checkpoint at `2d5c31c`. Superseded by [the native input qualification](WINDOWS-INPUT-QUALIFICATION-20261114.md); original failures below are preserved.

# Astrapé local continuation, 14 November 2026

Host `astrape`; Python 3.14.3; source base `2b537b4586ead02ab48a8e0a01248fd3be71d447` on `codex/windows-foundation-20261114`. Worktree initially clean. Host free capacity 28 GiB. Local Butler executable absent; coordinator admission retained, no duplicate ledger created. No host login, Screen Sharing hop, credentials or MacBook UI used.

## Changes

Selection now restores and verifies target focus before marked clipboard mutation. Synchronous handoff suppresses its own deactivation epoch increment; the response epoch, target identity, held modifiers and foreground are rechecked before writing. Missing targets refuse selection rather than silently copy. Session console/remote disconnect and logoff now take the existing purge/lock path. Hotkey status exposes registration error, delivery count and immediate foreground result without clipboard text.

Pure regression callbacks exercise ordered focus-before-write and refusal at initial admission, focus restoration, second admission, stale epoch, and clipboard failure. These do not qualify native focus behavior.

## Verification and limits

Native Windows ARM64 Debug compilation and selection policy checks run through vendor `prlctl exec --current-user`, source transfer only. The earlier build passed with zero warnings/errors; expanded policy checks passed 23 assertions. Final verification is reported with the commit receipt.

GUI inventory matched local Parallels and guest UUID `ad50825b-955a-4cd4-a04b-b7fadc860197`. Selecting Parallels timed out after about 456 seconds. Selecting the Windows 11 VM helper then returned exactly: `Computer Use was not approved to use Windows 11`. No GUI input was sent and no new GUI success is claimed. No new permissions were granted.

The original Ctrl+Alt+Shift+V reopen failure remains unresolved and unqualified. Registration collision/no-repeat, real guest shortcut delivery, repeated Escape/reopen, exact-once synthetic editor insertion, native focus-before-write, competing activation, lock/disconnect, elevated/UIPI and held-modifier behavior still require authorized native GUI proof. No WM_HOTKEY posting was used as keyboard proof. HWND reuse within the same live process and SendInput partial-submission modifier cleanup remain open security findings; production startup remains disabled. Input submission is not insertion proof.

VM stayed running, sharing restrictions unchanged. No frontend or engine process was running at initial inspection; no fixture application was launched by this continuation. Build processes exited. Original source clone and canonical records untouched; no release, push, deployment, model or owner clipboard data transfer.
