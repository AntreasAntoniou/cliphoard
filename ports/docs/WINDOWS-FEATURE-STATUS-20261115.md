# Windows feature completion status — updated 16 November 2026

This acceptance list tracks implemented capabilities and remaining qualification. The model report records the latest model inventory and evidence.

| Capability | Windows implementation | Qualification |
| --- | --- | --- |
| Real text/rich text/link/color/file/bitmap capture | Implemented, bounded, encrypted local history | Native synthetic roundtrips; prior GUI capture/paste |
| PNG-only clipboard images | Added; registered PNG format translated at runtime, not persisted as an unstable format ID | Native generated PNG roundtrip and dimension refusals |
| HTML clipboard content | Added; preserves CF_HTML alongside text, extracts text for HTML-only copies; no web rendering or network resolution | Native UTF-8/non-ASCII, script stripping, plain-copy and malformed-offset checks |
| Themes and layouts | All 18 shipping Mac palettes; three layouts, height, inspector | Prior guest GUI and 44 native palette/preferences checks |
| Search/selection after Settings/Inspect | Preserved, with retained original paste target | Live guest search retention after Settings close verified 16 November; prior target/paste qualification retained |
| Pins, context actions, copy/plain copy, paste, file verbs | Implemented | Prior native/GUI evidence; no new unsafe input/elevation probes |
| User tags | Added to inspector, cards, text search and Filters; encrypted and preserved during dedup | Native persistence/dedup/normalization checks; real inspector save, live card chip and tag search verified 16 November |
| Capture sound | Added, optional, off by default | Build; no unsolicited persistent setting enabled |
| Launch at login | Optional current-user Run entry; guarded against overwriting another installation; background startup flag | Build and background launch. Actual login activation not claimed; setting remains off unless the owner enables it |
| Source-app exclusions | Added in Privacy; clipboard owner process is checked before content reads | Native exclusion tests; owner exclusions never changed by tests |
| Private/transient/generated clipboard formats | Added skip paths; known password-manager process exclusions | Native generated privacy-format tests |
| Encrypted Windows backup/import | Added .cliphoard-win; AES-256-GCM and 600,000 PBKDF2-SHA256 rounds, NFC passphrases; atomic ciphertext writes; staged/confirmed merge with no implicit trimming | 25 native synthetic archive checks; actual save/open pickers, passphrase prompts, export and authenticated duplicate import verified 16 November |
| Mac .cliphoard archive interoperability | Implemented shared CLIPHRD1 v1 reader/writer, authenticated staging, metadata/payload preservation and PNG identity dedup | 45 generated native checks, shipping Swift reader cross-check, installed UI six-clip export/import with zero additions |
| Semantic Smart/Neural search and all Mac text models | Built-in hashing, Ogma Micro/Small with both 384/1024 heads, MiniLM and EmbeddingGemma 2; explicit verified acquisition and local CPU inference | Model/tokenizer goldens, model-switch/cancellation checks and live Ogma meaning-only search; see model report |
| Semantic tag assignment/facets | Pending | User labels and Tags search work. Mac specialist baskets and generated suggestions remain pending |
| OCR | Implemented installed-language Windows OCR, encrypted recognized text, image search and inspector Copy text | Five generated native checks on both architectures and installed UI image capture/search/copy/paste. Unpackaged OCR succeeded, correcting the earlier package-identity blocker assumption |
| Sensitive preview authentication | Implemented concealed previews and Windows Hello verification, analysis vetoes and local high-confidence secret signatures | Generated refusal checks. Successful Windows Hello reveal remains unverified. The complete Mac detector suite remains pending |
| Installer and packaging | ARM64/x64 self-contained ZIP, per-user MSI and structurally validated MSIX | MSI install/upgrade/repair/uninstall preserve encrypted history. Final build uses locked dependencies and includes WinUI PRI/XBF, icons and notices. Packages are unsigned |
| Native x64 hardware, signed distribution and updater | Pending | x64 suites ran under Windows ARM64 emulation. Publisher signing credentials and native x64 hardware were unavailable |
| Image models and speech transcription | OpenVision Tiny and Gemma image search; Whisper Small, Large v3 and Turbo through explicit local WAV transcription | Both image/text towers, Gemma text/image/audio vectors and all three full speech checkpoints qualified; live Gemma image ranking and Whisper transcription/copy verified |
| Full media-library workflow | Pending | Speech UI accepts PCM16 mono 16 kHz WAV for up to ten minutes. Other media formats and the complete Mac media-library workflow remain pending |

Current model qualification is in [the model report](WINDOWS-MODELS-20261116.md). Earlier archive, OCR and installer evidence is in [the parity report](WINDOWS-PARITY-20261116.md). Full Mac feature parity remains incomplete.

## Historical input blocker — 15 November

The existing Parallels guest is running; Cliphoard is responding in the interactive guest session. macOS Accessibility explicitly shows both Codex Computer Use and Parallels Desktop enabled. Host frontmost state was verified as `com.parallels.desktop.console`; the VM window was selected through Parallels' native Window menu. Native host AX menus/configuration navigation work, but tool-delivered guest canvas clicks/keyboard shortcuts still produce no guest result. Screenshot dimensions/window bounds agree (1915×979, 1× host scale), ruling out the earlier assumed Retina coordinate mismatch. The direct Windows app proxy times out.

Mouse/keyboard integration was inspected (both Auto-detect for games). No configuration, permissions, security, sharing, credentials, CPU/memory or host services were changed. A physical click and Control+Option+Shift+B check is requested from the owner to separate Parallels guest capture from the automation path. This was pending at the end of 15 November. The 16 November follow-up below supersedes this state.

## Data handling for the new features

Backup prompts suspend capture before file picking/passphrase entry and baseline the clipboard again when finished. Password fields are cleared; raw byte buffers/derived keys are zeroed where supported. No secure erasure of managed strings is claimed. Closing/locking prevents import application and stops an unfinished export from publishing after encryption. Import settings do not overwrite current preferences; count/pin/content-budget excess refuses the entire merge. Duplicate current clips win. Archive passphrases are not logged, sent online or copied by the app.

PNG is limited to 8 MiB, 8192 per dimension and 16,777,216 pixels. HTML is limited to 512 KiB, uses byte offsets/strict UTF-8 and bounded regular expressions, and is never rendered as active HTML. Rich clipboard data only returns to another app through an explicit copy/paste gesture. Tags are limited to 20 entries of 40 characters; exclusions to 100 process names. Local history validation includes image/color payload checks before accepted archive contents reach presentation.

References: [CF_HTML format](https://github.com/MicrosoftDocs/win32/blob/docs/desktop-src/dataxchg/html-clipboard-format.md), [startup activation](https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.windows.applifecycle.activationregistrationmanager.registerforstartupactivation?view=windows-app-sdk-1.8), [Windows OCR API](https://learn.microsoft.com/en-us/uwp/api/windows.media.ocr?view=winrt-26100).

## Regression result for this change

Both ARM64 projects built with warnings-as-errors and zero warnings/errors. Generated native suites passed: 25 archive, 27 added clipboard/tag/exclusion, 29 history, 44 theme, 12 native, 150 original paste-policy and 22 deferred-paste checks (**309 total**). Header/nonce/ciphertext/tag corruption, wrong password, truncation/trailing bytes, NFC, randomized ciphertext, duplicate imports, limit/pin refusal and unchanged persisted bytes on refusal are covered. Palette export still matches all 18 Swift presets.

A second `--background` launch exited0 while preserving the single existing responsive process; an invalid option exited78. No startup registry entry was enabled by testing. The app remains in its normal per-user runtime with the synthetic editor available for the pending physical-input test. The final archive UI snapshot is cloned on the UI thread before background encryption so later UI mutations cannot change an in-flight export.

## Live guest follow-up — 16 November 2026

The owner confirmed physical Control+Option+Shift+B opens the normal app. After refreshing the Parallels computer-use state, tool-delivered Control+Alt+Shift+B also opened the bar. Search text, Settings, Inspector and native file pickers were exercised through the actual guest UI. The former total keyboard-input blocker is cleared for this session. Mouse activation remains intermittent, and rapid zero-duration keystrokes dropped one filename character. Explicit 60 ms key holds and keyboard focus traversal completed the tests. No VM integration/security/sharing setting was changed. This does not establish a permanent fix to Parallels event delivery.

The settings navigation rebuild discarded focus, causing subsequent Tab traversal to restart. The selected navigation button now receives focus when its replacement loads. Live Privacy-to-Backup traversal passed after the repair. Backup/import/clear confirmations now explicitly inherit the selected light/dark theme and palette background/foreground. The Dracula unlock and import confirmation dialogs were visually checked, including readable summary text.

Generated four-clip history was exported through Save As to `Documents\syntheticui20261116.cliphoard-win`, unlocked through Open, authenticated as four clips with zero new entries, and imported with zero additions. The existing four clips stayed present. The disposable test passphrase was entered only as guest keystrokes and is absent from app logs. A subsequent authenticated import was cancelled at confirmation. The generated encrypted archive remains available in the guest for this qualification.

The synthetic meeting clip received the user tag `syntheticreview` through Inspector. Its card updated live and searching that tag returned exactly that clip. The inspector exposed multiline truncation caused by assigning Text before enabling AcceptsReturn. The initializer now enables multiline mode before assigning the full stored text.

The final ARM64 frontend rebuilt with warnings-as-errors and zero warnings/errors. The repaired inspector displayed all three lines of the generated meeting note. The saved synthetic tag survived restart. All 18 palette exports still match Swift, and the 44 native theme checks passed during this follow-up.

Actual focus/paste acceptance also passed on the final build. From the disposable editor, Control+Alt+Shift+B reopened the bar, `meet` filtered the meeting clip, Settings opened and closed with the query/selection retained, and Enter pasted the complete three-line note into the original editor. A fresh shortcut summon reset search. Control+4 then replaced the selected editor text with the generated link. The metadata-only fixture receipt reported length 39 and syntheticLinkPasted true. The normal frontend remained a single responsive process and was left open for owner testing.
