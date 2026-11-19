# Remaining Windows qualification — 14 November 2026

Continuation from `816599b`, on Astrapé and the existing Windows 11 ARM64 VM. Work stays within `ports/`; synthetic-only startup, own-run clipboard markers, target admission and production transport refusal remain in force. No authentication files, history, model weights, owner clipboard contents or host UI sessions are transferred.

## Established results

- **Exact numeric HWND reuse:** a hidden, constant-resource native loop reused handle 2818644 after 32,766 creations in 6,820 ms, in the same live process. The undisposed old stamp rejected the recycled number. Creating a fresh stamp and then disposing the stale stamp did not remove the replacement's authority. No mocked HWND or PID substitution was used.
- **Elevated target:** the owner approved guest UAC for the owned synthetic editor. Its measured integrity RID was 12288 (high), versus 8192 (medium) for the controller/frontend launch context. The frontend opened from the actual guest shortcut and explicitly refused selection. The elevated editor stayed empty with zero paste messages; clipboard sequence stayed 226.
- **Real session lock:** a five-second queued synthetic selection preceded a real LockWorkStation request in guest session 2. The native adapter received Windows reason 7, the engine acknowledged count 0, and the queued selection later refused with locked=true. Sequence stayed 236. The owner unlocked the guest normally; the purged fixture did not reopen afterward. No posted session message or sign-in automation was used.

- **Real console disconnect:** a fresh frontend received Windows reason 2 for session 2 after an actual WTSDisconnectSession request. It purged count 0 and rejected the queued selection; sequence stayed 246. Windows also delivered reason 7 afterward. After the existing guest was resumed through its ordinary credential-free Sign in button, the purged frontend stayed closed. No credential was entered or settings changed.
- **Actual short SendInput return:** a medium-integrity worker on a disposable non-input desktop submitted the normal four valid INPUT records and received 0 with Win32 error 5. The production PasteInput component disabled further automatic input; the second submission returned Refused without another native call. The original worker desktop was restored and the disposable object closed. The visible desktop never changed.

Metadata receipts are under [evidence-remaining-20261114](evidence-remaining-20261114). The Windows fixture audit contains only bounded operation/epoch/session/count/sequence metadata, never clipboard payloads.

## Return-count experiments and preserved failures

The first direct medium-to-high API probe returned 4 for a complete four-event call while the elevated editor accepted no text. Its original probe mistakenly made a second call based on an expected short return; this was corrected so a second call is permitted only to verify a disabled sender after an actual short result, never after a full return. The failed attempt is retained as `uipi-full-count-no-insertion.json`, not counted as a short-return pass.

With explicit owner approval, a high-integrity, guest-only BlockInput probe used a different sending thread and always released input from the owning thread in finally. The bounded wait was 500 ms; the measured block scope was 6 ms and release succeeded. The API again returned 4 while no text or paste message was delivered. There was one native call, no retry, and both keys were released. This is preserved as `blocked-thread-full-count.json` and does not prove a short return. No further input-block attempt is authorized or scheduled.

The successful private-desktop result is saved as `actual-short-isolated-desktop.json`. It used the real SendInput binding with the normal 40-byte INPUT layout, no mocked return and no truncated event array. Its desktop rights were limited to the new disposable object and excluded SWITCHDESKTOP; SwitchDesktop was never called. The UI controller remained on the visible desktop. This qualifies a real zero-event short return under a desktop access boundary. Positive partial returns of 1/2/3 remain covered by the earlier native prefix fault-injection and exhaustive policy tests; this report does not claim naturally occurring positive partial returns.

## Session-event instrumentation and safeguard repair

`NativeWindowAdapter` carries the actual revocation reason/session into the existing immediate lock/purge path. `FixtureAudit` writes a bounded, synthetic-only snapshot beside the fixture binary. F8 provides a five-second selection delay for actual session transitions; F6 retains the earlier one-second fixture delay.

During qualification, ListView's handled Enter could also reach the root's handled-event listener and start a duplicate selection. The root now skips Enter already handled by the child; clipboard epochs still protect all asynchronous replies. The final native GUI regression passed after rebuilding: one ListView Enter produced the exact 55-character rust fixture once (one WM_PASTE and one text change). A second, delayed Enter followed by Escape produced one selection-start and one stale refusal, with sequence 262 unchanged and no additional text. The audit has exactly two selection-start entries for those two actions.

## Final verification and limits

- Final Windows ARM64 frontend and NativeTests builds: zero warnings/errors, using .NET 10.0.404 and existing restore/pins. Guest OS version reported 10.0.26300.0.
- 150 cumulative policy assertions and 12 general native assertions passed; exact numeric reuse and actual OS-boundary cases are separate measured receipts.
- Source-only transfer and vendor current-user guest execution remained the code/build route. Native GUI supplied the visible behavior checks; no posted WM_HOTKEY/session message was used as physical/session proof.
- Elevated fixtures closed through their own GUI. Final scoped process cleanup returned zero frontend, engine or NativeTests processes. No input block, disposable desktop or privileged helper remains active. VM and other host services remain running; host free capacity was 17 GiB.
- Remote-session reason 4 and OS logoff reason 6 were not generated: this VM uses a console session, and no new remote service/account or OS logout was implied. Console lock reason 7 and console disconnect reason 2 were generated and verified. Production/distribution remain disabled and unqualified beyond this bounded synthetic milestone.
- No release, deployment, private push, canonical-record edits, authentication-file transfer or security-setting changes occurred. Owner UAC approval was used for the reviewed elevated editor and the single bounded input-block probe; the latter released after 6 ms and is not counted as a short-return pass.

Final machine-readable checks and source hashes accompany the receipts. Earlier failures remain preserved rather than overwritten.
