# Mac visual system on Windows — 15 November 2026

Replaced the first standalone Windows UI with the shipping Mac app's visual system and supported clipboard interactions. References are the current `Sources/Cliphoard/UI/Theme.swift`, `SearchBarView.swift`, `ContentView.swift`, `ClipCardView.swift`, `BarHeightSettings.swift`, and `PanelViewModel.swift`; the repository's Swiss/Dracula screenshots were also inspected. No live Mac clipboard history or owner preferences were read.

## Appearance and interaction

- All **18 shipping presets**, in the Mac CaseIterable order: Automatic, Swiss Grayscale, Midnight Glass, High Contrast, Paper & Ink, Light Floating Palette, One Dark, Dracula, Tokyo Night, Catppuccin Mocha, Gruvbox Dark, Monokai, Night Owl, Solarized Light, GitHub Light, Catppuccin Latte, Rosé Pine Dawn, One Light.
- The exporter reads the Swift tokens directly, preserving palette colors, pin color, corner radius, selected stroke, borders/hover, muted color, tag fill, material/appearance and serif choice. `ThemePresets.json` includes source SHA-256. `export-mac-themes.py --check` rejects drift. Automatic resolves One Dark/Swiss from Windows appearance, and the main bar listens for system color changes.
- The shipping `Resources/AppIcon.png` is reused byte-for-byte as the Windows toolbar brand asset. Both SHA-256 values: `e57e85d6c549d0d295507e1c278928cbc70169bcfb7df8073f8f32f5c2fc6ef7`.
- The toolbar follows the current Mac source: 56-DIP row, 32-DIP brand, capsule search, matching label, inline Filters and trailing utilities. Filters expose actual supported type, pin, time and source-app predicates. There is no placeholder Models button or nonfunctional neural/tag matching option.
- The 220-DIP cards use a 28-DIP source/glyph/pin/inspect/quick-key header, divider, bounded preview, character/dimension count and relative-time footer. Default strip height uses the Mac `250 - 48 = 202` preview calculation with 14-DIP insets. Images fill/crop the card slot and fit the inspector/Spotlight preview. Selection uses the theme ring/shadow; card fills do not change to an invented selection palette.
- Card Strip, Spotlight Palette (430-DIP list plus selected preview), and Compact List are functional. Height is adjustable from 200 to 400, with 250 reset; the three preferences persist in the existing encrypted store. Auxiliary windows fit the active work area.
- Inspector, selected-card activation, context actions and keyboard equivalents: arrows, Enter, Shift+Enter, Ctrl+C, Ctrl+Shift+C, Ctrl+1–9, Ctrl+P, Ctrl+Backspace, Ctrl+Enter, Ctrl+comma, Escape, Ctrl+Q. Local file clips additionally expose Open first file, Show in Explorer, Copy path and Ctrl+O; file double-click opens rather than pasting. UNC/remote file verbs are refused; capture still never probes file contents.
- Settings and inspector retain the original paste target on close. Modifier shortcuts wait boundedly for real physical key release, checking the captured target/epoch after every await. They never synthesize modifier release, force focus, or retry a partial SendInput result.

AppKit materials/font rendering cannot be copied literally onto WinUI. Midnight Glass uses Windows Desktop Acrylic with a bounded translucent fallback; native Segoe/Georgia/Fluent glyphs substitute for Apple's fonts and SF Symbols. Window motion remains native Windows behavior. This is visual/interaction parity for the supported standalone clipboard feature set, not a claim that the Mac's semantic/media models, detector/tag pipeline, agent/licensing/update flows or startup integration were ported.

## Qualification

Windows 11 ARM64 in the existing isolated Parallels guest; synthetic data only; no sharing, security, credentials, elevation, host Cliphoard or Mac source changes.

- Warnings-as-errors WinUI ARM64 and NativeTests builds: **zero warnings/errors**.
- Source export: **18 palettes match Swift**, including ordering and literal color/geometry values.
- **44 theme checks**, including valid palettes, light/dark automatic mapping, material/serif behavior, bounds, encrypted preference roundtrip and unknown-value fallback.
- **29 history/clipboard checks**, **12 native checks**, **150 existing paste-policy checks**: all pass, **235 automated checks total**. The policy checks were repeated after making auxiliary-window target preservation explicit.
- Actual GUI observed Swiss, Dracula, Paper & Ink, High Contrast and Midnight Glass changes; all 18 previews were reachable in the gallery. Paper changed typography to serif; glass used the native backdrop without changing OS transparency settings.
- Actual GUI exercised all three layouts, Spotlight selection/image preview, inspector, live height changes/reset, Ctrl+comma settings and Ctrl+Q quit. Dracula/Card Strip/default height were restored through the UI and reopened after restart.
- Actual Ctrl+4 inserted the generated link into the separate synthetic editor, with a content-free receipt `length=39`, `syntheticLinkPasted=true`. The final integration pass opened and closed Settings between summoning the bar and Ctrl+4; the generated link still arrived in the original editor. No private clipboard payload was logged.
- As in the earlier qualification, the nested Parallels/CUA route can consume an activation click; focused WinUI controls were also exercised with Space. This is not represented as an exhaustive hardware-pointer qualification.
- No new real lock/disconnect, elevation, numeric-HWND churn or short-SendInput experiments were run in this UI pass. Their protected native components remain unchanged and retain the earlier qualification reports.

Failures encountered and fixed: initial C# namespace qualification errors; duplicate default WinUI PNG resource inclusion (changed Content Include to Update); WinUI logical-parent reparenting during chrome rebuild (retain/remove from owning grids explicitly); horizontal scrollbar space clipping card footers (hide the strip indicator while keeping horizontal scrolling). Initial metadata-only startup tracing was removed after the fix.

The source bridge now batches bounded idempotent source transfers and includes the reviewed PNG asset. Build/test commands are still executed once, without automatic retries. The normal application remains available through the existing Windows desktop shortcut and Ctrl+Alt+Shift+B.

Primary platform reference: [DesktopAcrylicBackdrop](https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.media.desktopacrylicbackdrop?view=windows-app-sdk-1.8).

## Interaction follow-up

Closing Settings or Inspect now preserves the search text and selected clip as well as the original target. A fresh summon still resets search to the newest clips. Notices can be dismissed without reopening the bar.

Quick-paste waits now use a separately testable bounded release policy. Arrow navigation, mouse selection and new captures advance the UI epoch, cancelling a pending paste before it can write the clipboard. Every wait rechecks epoch, target identity, lock/close state and item membership. The maximum remains 28 × 15 ms; no synthetic modifier release or SendInput retry was added.

Warnings-as-errors ARM64 build passed with zero warnings/errors. Existing 150 policy checks plus **22 additional deferred-paste checks** passed, covering immediate release, last-interval release, timeout, revocation before and during waiting, and refusal before even querying key state. The prior 44 theme / 29 clipboard / 12 native checks were not unnecessarily repeated for this UI/policy-only change.

Live qualification limitation for this follow-up: the VM remained running and the revised bar was visible, but the current computer-use route did not deliver clicks or keyboard shortcuts into the guest canvas. Native host menu actions worked; the direct Windows app proxy timed out. No credentials, VM configuration or OS protections were changed. Search retention and dismissible notices therefore have build/source verification but were not newly proven through guest GUI interaction in this follow-up. Earlier visual/theme qualifications above remain historical evidence.
