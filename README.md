# Ditto

A floating clipboard manager for macOS — a native, open-source take on [Paste](https://pasteapp.io). Press **⌃⌥⌘V** anywhere and your clipboard history slides up from the bottom of the screen as a strip of cards. Pick one and it pastes straight back into whatever app you were using.

> Built with Swift, AppKit and SwiftUI. No Electron, no telemetry, no account.

## Features

- **Slide-up bar** — a borderless panel animates up from the bottom edge of the active screen, just like Paste.
- **Captures everything** — text, rich text (RTF), links, hex colors, images and files are detected automatically and shown with type-appropriate previews.
- **Instant search** — fuzzy-free substring search across your whole history.
- **Category filters** — All · Pinned · Text · Links · Colors · Images · Files, with live counts.
- **Pinboards via pinning** — pin clips you reuse so they survive history trimming and float to the front.
- **Keyboard-first** — navigate with arrows, paste with ↩, quick-paste the first nine with **⌘1–9**, pin with **⌘P**, delete with **⌘⌫**, dismiss with **esc**.
- **Auto-paste** — selecting a clip copies it and issues ⌘V into the previously-focused app.
- **Capture sound** — a subtle tick when a clip lands (like Paste), with a choice of system sounds and an on/off toggle.
- **Always-on capture** — opts out of macOS App Nap so background copies are recorded continuously, not just after a restart.
- **Persistent history** — stored locally in `~/Library/Application Support/Ditto`, with a configurable limit (50–1000 items).
- **Privacy-aware** — honors the `org.nspasteboard` transient/concealed markers, so password managers aren't recorded.
- **Menu-bar app** — runs as a background accessory (no Dock icon); launch-at-login toggle included.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `⌃⌥⌘V` | Show / hide the Ditto bar |
| `← →` | Move selection |
| `↩` | Paste selected clip |
| `⌘1`–`⌘9` | Quick-paste by position |
| `⌘P` | Pin / unpin selection |
| `⌘⌫` | Delete selection |
| `esc` | Dismiss |

## Build & run

Requires macOS 13+ and the Swift toolchain (Xcode 15+).

```bash
git clone https://github.com/AntreasAntoniou/ditto.git
cd ditto
make run          # builds Ditto.app and launches it
```

Other targets:

```bash
make app          # build build/Ditto.app
make install      # copy to /Applications
make build        # debug binary only
make clean
```

### Permissions

On first launch macOS will ask for **Accessibility** access — Ditto needs it to send the ⌘V keystroke that pastes into the focused app. Grant it under *System Settings → Privacy & Security → Accessibility*. Until then, selecting a clip still copies it to the clipboard; you just paste manually.

## How it works

| Piece | File |
| --- | --- |
| Pasteboard polling + type detection | `Sources/Ditto/Clipboard/ClipboardMonitor.swift` |
| History model, dedup, persistence, trimming | `Sources/Ditto/Clipboard/ClipStore.swift` |
| Write-back + simulated paste | `Sources/Ditto/Clipboard/Paster.swift` |
| Global hotkey (Carbon) | `Sources/Ditto/App/HotKey.swift` |
| Slide-up panel | `Sources/Ditto/UI/FloatingPanel.swift` |
| Bar & card UI (SwiftUI) | `Sources/Ditto/UI/ContentView.swift`, `ClipCardView.swift` |
| App wiring, menu, keyboard | `Sources/Ditto/App/AppDelegate.swift` |

## Roadmap

- iCloud / file-based sync across machines
- Paste stack (queue multiple, paste in order)
- Paste-as-plain-text modifier
- Customizable hotkey in a settings window
- Smart actions on links/colors

## License

MIT © Antreas Antoniou
