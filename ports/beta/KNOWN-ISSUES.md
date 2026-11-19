# Known issues and beta scope

## Distribution and platform coverage

- The MSI and application binaries are **unsigned**. There is no verified publisher identity or established Windows reputation. Trusted publisher signing is outstanding. MSIX files are excluded from these tester kits because trusted installation has not been qualified.
- ARM64 has live Windows 11 VM qualification, including an installed 1.2.14 upgrade. x64 packaging and tests run under ARM64 emulation. Physical Intel/AMD hardware, a clean user profile installation and uninstall on a tester device remain qualification work.
- Parallels and guest Tools were updated to 27.1.0 build 58756. The owner confirmed sustained remote mouse and keyboard use across Mac/Windows focus changes. Automated guest clicks and keystrokes can still be dropped. This is not a guarantee for every virtualisation or remote-desktop environment.

## Search quality

The synthetic retrieval benchmark has **41 failed expectations out of 432 queries**: 37 text and four image cases. These failures remain open. Some models return irrelevant results for absent topics; some relevant results fall outside the first three positions. OpenVision missed red queries in a singleton image collection and feline queries in two generated collections. Gemma's passing image checks cover only a small generated corpus and do not establish general photo quality. Report the selected model, mode, readiness and query when search behaves unexpectedly.

Model preparation may require substantial disk space and time. Unprepared, unsupported or failed inference must not be interpreted as evidence that the image or text was absent from history. Exact matching is the basic fallback, not an equivalent semantic engine.

## Safeguards and intentional limits

- Automatic paste into an elevated administrator application is refused. Use ordinary applications for the beta checklist; do not run Cliphoard as administrator to evade this restriction.
- Protected-content reveal depends on Windows Hello. Successful owner-device Hello reveal remains unqualified. Failed or unavailable verification must continue to refuse reveal.
- Positive partial SendInput return lengths are covered through fault injection. A real zero-event return was observed on an isolated desktop. The full range of real driver/session short returns is not proven. Partial returns disable automatic input for the run.
- Real console lock/disconnect tests have receipts. Other remote-session and logoff combinations are not exhaustively qualified.
- The new sound assets pass loading and persistence checks. The full sound chooser was not visually qualified because automated settings navigation was dropped by the guest.
- Image cards now request 1,024-pixel decoding instead of the old PNG 64-pixel limit. Inspect uses original-resolution decoding; card thumbnails remain previews. The fix does not restore detail missing from the source image.

Use generated or non-sensitive content for reports. Do not attach clipboard databases, archive exports, model caches, credentials, licence keys or unredacted screenshots of personal clips.
