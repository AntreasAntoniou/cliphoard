# Cliphoard — Authoritative Engineering Specification

> ⚠️ **This SPEC predates the SQLite store, on-device deep search, in-bar
> settings, and tag baskets. For the current state see [Agents.md](Agents.md)
> (codebase map), [STATUS.md](STATUS.md) (readiness + prioritized backlog), and
> [AUDIT.md](AUDIT.md) (confirmed findings). Where SPEC and code disagree, code wins.**


> Byzantine 3-2-1 synthesis. Three independent spec drafts reconciled against two
> adversarial verification reports and re-checked against live source + on-disk
> state at `/Users/antreas/Projects/ditto` on **2026-06-17**. Every contested fact
> below was re-read from the code or the running system; code-verified facts win
> over any draft claim. Remote: `https://github.com/AntreasAntoniou/yank`.
> Target: macOS 13+ (`Package.swift` → `.macOS(.v13)`; `Info.plist
> LSMinimumSystemVersion 13.0`); built/run on macOS 26 / Darwin 25.6 / arm64,
> Swift 5.9 tools.

```
                              ▲
                             ╱ ╲
                            ╱ V ╲                 APEX — one-sentence vision
                           ╱─────╲
                          ╱       ╲
                         ╱ PRINCI- ╲             TIER 1 — principles
                        ╱   PLES    ╲
                       ╱─────────────╲
                      ╱   FEATURE     ╲          TIER 2 — built vs planned
                     ╱     SURFACE     ╲
                    ╱───────────────────╲
                   ╱   ARCHITECTURE &    ╲        TIER 3 — data flow
                  ╱      DATA FLOW        ╲
                 ╱─────────────────────────╲
                ╱      COMPONENT SPEC        ╲     TIER 4 — every file/type/field
               ╱   (files · types · fields)   ╲
              ╱───────────────────────────────╲
             ╱        VERIFIED STATE            ╲   TIER 5 — what is proven
            ╱─────────────────────────────────────╲
           ╱          OPEN DEFECTS                  ╲ TIER 6 — refresh-bug deep dive
          ╱   (ranked hypotheses · protocol · AC)    ╲
         ╱─────────────────────────────────────────────╲
        ╱             PRIORITIZED BACKLOG                ╲ TIER 7
       ╱───────────────────────────────────────────────────╲
      ╱   BASE REFERENCE: build · file map · persistence ·    ╲ TIER 8
     ╱    constants · decisions log · environment notes        ╲
    ╱───────────────────────────────────────────────────────────╲
   ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
```

---

## APEX — Vision (one sentence)

**Cliphoard is a native, open-source, no-account, telemetry-free macOS menu-bar
clipboard manager that, on the global shortcut `⌃⌥⌘V`, slides a horizontal strip
of clipboard-history cards up from the bottom of the active screen and pastes the
chosen clip straight back into the app you were using — a Swift/AppKit/SwiftUI
reimplementation of the commercial "Paste" app's core flow.**

---

## TIER 1 — Principles

1. **Native, not Electron.** Swift + AppKit + SwiftUI + Carbon only. `Package.swift`
   links exactly four frameworks: `AppKit`, `SwiftUI`, `Carbon`,
   `UniformTypeIdentifiers`. No web stack, no network, no account, no telemetry.
2. **Background-first accessory.** `Main.main()` calls
   `app.setActivationPolicy(.accessory)`; `Resources/Info.plist` sets
   `LSUIElement = true`. No Dock icon; one `NSStatusItem`, one `FloatingPanel`,
   no main window.
3. **Capture is sacred.** Every copy in any app — bar open or closed, Cliphoard
   frontmost or not — must be recorded. App Nap is explicitly defeated
   (`ClipboardMonitor.start()` activity assertion) to keep this promise. This
   promise is also the locus of the open refresh defect (Tier 6).
4. **Keyboard-driven.** Summon, navigate (`←→`), paste (`↩`), quick-paste
   (`⌘1–9`), pin (`⌘P`), delete (`⌘⌫`), dismiss (`esc`).
5. **Local & durable.** History persists as JSON + PNG sidecars under
   `~/Library/Application Support/Ditto`.
6. **Privacy-aware.** Honors `org.nspasteboard.TransientType` /
   `org.nspasteboard.ConcealedType` markers; password-manager content is skipped.
7. **Paste parity.** When a behavior is ambiguous, match the Paste app.
8. **Single source of truth.** `ClipStore` owns the data; the panel is a pure
   projection through `PanelViewModel.results`. All mutation is on the
   `@MainActor`.

---

## TIER 2 — Feature Surface

### 2.1 BUILT (present in source; verification status in Tier 5)

| Feature | Where |
| --- | --- |
| Slide-up borderless bar from the bottom edge of the mouse's screen | `FloatingPanel.slideIn`/`slideOut`, `targetScreen()` |
| Global hotkey **⌃⌥⌘V** toggle | `AppDelegate.setupHotKey` → `HotKey.register` (Carbon) |
| Automatic capture + classification: `text` / `link` / `color` / `image` / `file` | `ClipboardMonitor.capture` + `detectKind` |
| RTF fidelity round-trip (capture + write-back) | `capture` (`pb.data(forType:.rtf)`) + `Paster.writeToPasteboard` |
| Image payload persistence as PNG (`<uuid>.png`) | `ClipboardMonitor.persistImage` |
| Persistent history (JSON + PNG sidecars) | `ClipStore.save`/`load` |
| Configurable limit incl. **Unlimited** (0/100/200/500/1000/5000) | `ClipStore.historyLimit`, menu `setLimit` |
| Dedup of consecutive identical copies (by `signature`) | `ClipStore.add` |
| Per-item pinning (survives trim, sorts to front) | `ClipStore.togglePin`, `trim`, `sortStable` |
| Substring search (text / filePath / colorHex, case-insensitive) | `ClipStore.filtered` |
| Category filters: All · Pinned · Text · Links · Colors · Images · Files (live counts, non-empty kinds only) | `ContentView.categoryChips`, `ClipStore.counts` |
| Auto-paste: write clip always; simulate ⌘V into prior app if AX-trusted | `AppDelegate.commit` → `Paster` |
| Own-paste suppression (write-back not re-captured) | `ClipboardMonitor.suppressNextChange` / `ignoreChangeCount` |
| Keyboard model (Tier 4) | `AppDelegate.handleKey`, `PanelViewModel` intents |
| Capture sound: 14 system sounds, on/off, preview-on-pick | `Feedback`, menu `chooseSound`/`toggleSound` |
| Launch at login | `AppDelegate.toggleLaunchAtLogin` (`SMAppService.mainApp`) |
| App Nap opt-out (activity assertion) | `ClipboardMonitor.start` |
| Debug logging → `debug.log` | `DebugLog`, menu `toggleDebug` |
| Scriptable toggle via Darwin notification `ai.axiotic.ditto.toggle` | `AppDelegate.setupRemoteToggle` |
| Lazy Accessibility (no launch prompt; once on first paste + menu item) | `AppDelegate.commit`, `promptAccessibility`, `rebuildMenu` |

### 2.2 PLANNED (README "Roadmap" / prior SPEC; not in source)

iCloud / file-based sync · paste stack / queue · paste-as-plain-text modifier ·
in-app Settings window · customizable-hotkey recorder UI · smart actions on links
(open) and colors (rgb/hsl) · named pinboards beyond the single `pinned` flag ·
first-run onboarding / permission UX · Developer-ID-signed + notarized build ·
unit / UI / snapshot tests · CI. **No test target exists in `Package.swift`.**

---

## TIER 3 — Architecture & Data Flow

### 3.1 Process shape

A single `.accessory` `NSApplication`. `@main struct Main` (deliberately a struct
in `Main.swift`, **not** a top-level `main.swift`, to avoid the top-level-code vs
`@MainActor` conflict under SwiftPM) constructs `AppDelegate`, retains it via
`objc_setAssociatedObject(app, "dittoDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)`,
and runs the app. `AppDelegate` (`@MainActor`) is the conductor and owns every
long-lived object:

```
AppDelegate
 ├─ store      : ClipStore            (let; load() runs in init)
 ├─ monitor    : ClipboardMonitor     (lazy; ClipboardMonitor(store:))
 ├─ model      : PanelViewModel       (lazy; PanelViewModel(store:))
 ├─ panel      : FloatingPanel        (let; NSPanel subclass)
 ├─ hotKey     : HotKey               (let; Carbon)
 ├─ statusItem : NSStatusItem!
 └─ keyMonitor : Any?                 (NSEvent local monitor)
```

State flags on `AppDelegate`: `previousApp: NSRunningApplication?`,
`isVisible: Bool`, `isClosing: Bool` (recursion guard for `resignKey → hide`),
`didPromptAX: Bool`.

### 3.2 Capture loop (VERIFIED working — live `debug.log` shows `change #N … → captured`)

```
NSPasteboard.general
  │  Timer(0.4s, tolerance 0.1) on RunLoop.main in .common modes
  │  + ProcessInfo activity assertion (App Nap defeated)
  ▼
ClipboardMonitor.poll()
  │  guard count != lastChangeCount
  │  skip if count == ignoreChangeCount (own paste)
  │  skip Transient / Concealed pasteboard types
  ▼
ClipboardMonitor.capture(from:)   priority: file URL → image → string
  │  item.sourceApp = NSWorkspace.frontmostApplication?.localizedName
  ▼
ClipStore.add(item)
  │  dedup by signature → bump existing to front (NO save, NO sound)   ← see Tier 6.3
  │  else items.insert(at:0) → trim() → save() → Feedback.playCapture()
  ▼
@Published items   →   SwiftUI projection (ContentView)   |   history.json + <uuid>.png on disk
```

### 3.3 Presentation path (the open defect lives here — Tier 6)

```
HotKey ⌃⌥⌘V  ─or─  Darwin "ai.axiotic.ditto.toggle"  ─or─  menu "Open Cliphoard"
  ▼
AppDelegate.toggle() → show()
  │  guard !isVisible
  │  previousApp = frontmostApplication
  │  model.query=""; model.activeKind=nil; model.pinnedOnly=false
  │  model.resetSelection(); model.presentToken &+= 1
  │  isVisible=true; isClosing=false
  │  NSApp.activate(ignoringOtherApps:true); panel.slideIn()
  ▼
FloatingPanel (NSPanel, borderless / nonactivating, level .mainMenu+1)
  │  contentView = NSHostingView(rootView: ContentView(model, store))   ← set ONCE in setupPanel()
  ▼
ContentView.body reads model.results (= store.filtered(...)) and store.counts()
```

**Critical structural fact:** `panel.setContent(...)` runs **exactly once**, in
`setupPanel()`. The `NSHostingView` is a *local* in `setContent` (not stored on
the panel), and `slideIn()` only animates the frame + `makeKeyAndOrderFront`; the
hosting view's `rootView` is never reassigned. This is the architectural crux of
the refresh defect (Tier 6).

### 3.4 Paste path (VERIFIED own-paste suppression in live log; ⌘V works only if AX granted)

```
model.commitSelection()/quickSelect()/double-click → onPaste → AppDelegate.commit(item)
  store.markUsed(item)            (bump lastUsedAt/useCount, move to front, save)
  monitor.suppressNextChange()    (ignoreChangeCount = changeCount + 1)
  Paster.writeToPasteboard(item, store)   (ALWAYS — image | file URL | rtf+string)
  canPaste = AXIsProcessTrusted()
  if !canPaste && !didPromptAX { promptAccessibility() }   (once)
  hide(paste: canPaste)           (write + prompt are NOT mutually-exclusive branches)
hide(paste:true)  → slideOut → Paster.paste(into: previousApp):
                    app.activate; after 0.12s → CGEvent ⌘V down/up on .cghidEventTap
hide(paste:false) → slideOut → previousApp?.activate
```

> **Control-flow correction (from verification):** `commit()` writes to the
> pasteboard *before* the AX check in all cases; the lazy prompt and the `hide`
> are not either/or branches. The clip lands on the system pasteboard regardless
> of Accessibility — only the synthetic ⌘V keystroke needs it.

### 3.5 Invariants

- All `ClipStore` / UI mutation is on the **main actor** (`@MainActor` on
  `ClipStore`, `ClipboardMonitor`, `PanelViewModel`, `AppDelegate`, `Paster`,
  `Feedback`).
- `ClipStore` is the single source of truth; the panel is a pure projection.
- `suppressNextChange()` prevents self-capture (live-proven).
- `isClosing` guards the `resignKey → onResignKey → hide` recursion.
- The `NSHostingView` `rootView` is assigned exactly once, at launch.

---

## TIER 4 — Component-by-Component Spec (exhaustive; real symbols & values)

### `Package.swift`
`swift-tools-version:5.9`. Package `Cliphoard`; `platforms: [.macOS(.v13)]`; one
`.executableTarget` named `Cliphoard`, `path: "Sources/Cliphoard"`; linked frameworks
`AppKit`, `SwiftUI`, `Carbon`, `UniformTypeIdentifiers`. No test target.

### `Sources/Cliphoard/App/Main.swift`
`@main struct Main`; `@MainActor static func main()`. `NSApplication.shared`,
instantiates `AppDelegate`, sets `app.delegate`, `setActivationPolicy(.accessory)`,
retains the delegate via `objc_setAssociatedObject(app, "dittoDelegate", delegate,
.OBJC_ASSOCIATION_RETAIN)`, then `app.run()`.

### `Sources/Cliphoard/App/AppDelegate.swift`
`@MainActor final class AppDelegate: NSObject, NSApplicationDelegate`.
- `applicationDidFinishLaunching`: `setupStatusItem()` · `setupPanel()` ·
  `setupHotKey()` · `setupRemoteToggle()` · `monitor.start()`. **No launch-time AX
  prompt** (deliberate — it re-nagged after every ad-hoc rebuild changed code
  identity).
- `setupRemoteToggle()`: `CFNotificationCenterAddObserver` on Darwin name
  `ai.axiotic.ditto.toggle`, `.deliverImmediately`; callback dispatches `toggle()`
  to main. (No observer removal — process-lifetime singleton, benign.)
- `setupStatusItem()`: variable-length status item; button image SF Symbol
  `"doc.on.clipboard"` (`isTemplate=true`); calls `rebuildMenu()`.
- `rebuildMenu()`: **Open Cliphoard (⌃⌥⌘V)** · sep · **History Limit** submenu (tags
  `[0,100,200,500,1000,5000]`, `0`→"Unlimited", "N items", checkmark on current
  `store.historyLimit`) · **Launch at Login** (checked via
  `SMAppService.mainApp.status == .enabled`) · **Play Sound on Copy** (vs
  `Feedback.soundEnabled`) · **Copy Sound** submenu (`Feedback.availableSounds`,
  checked vs `Feedback.soundName`) · **Debug Logging** (vs `DebugLog.enabled`) ·
  sep · **Grant Accessibility…** (shown only if `!AXIsProcessTrusted()`) ·
  **Clear Unpinned History** · **About Cliphoard** · sep · **Quit Cliphoard** (`q`).
- `setupPanel()`: wires `model.onPaste = commit`, `model.onClose =
  hide(paste:false)`, `panel.onResignKey = { if isVisible && !isClosing {
  hide(paste:false) } }`; calls `panel.setContent(ContentView(model:model,
  store:store))`; installs `NSEvent.addLocalMonitorForEvents(matching:.keyDown)`
  that forwards to `handleKey` **only while `panel.isKeyWindow`**, else returns
  the event.
- `toggle()`: `isVisible ? hide(paste:false) : show()`.
- `show()` / `hide(paste:)` — Tier 3.3 / 3.4. `show()` early-returns if already
  visible.
- `commit(_:)` — Tier 3.4.
- `handleKey(_:) -> NSEvent?` — Carbon key codes: `kVK_Escape`(53)→hide;
  `kVK_LeftArrow`(123)→`moveSelection(-1)`; `kVK_RightArrow`(124)→`moveSelection(1)`;
  `kVK_DownArrow`/`kVK_UpArrow`→swallowed (`return nil`);
  `kVK_Return`(36)/`kVK_ANSI_KeypadEnter`(76)→`commitSelection`; `kVK_Delete` +
  ⌘→`deleteSelection`; `kVK_ANSI_P` + ⌘→`pinSelection`; ⌘ + digit `1–9`→
  `quickSelect`. **Non-matches return the event** so they reach the SwiftUI search
  field.
- `setupHotKey()`: `hotKey.onPressed = toggle`;
  `register(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey|optionKey|cmdKey))`.
- Menu actions: `setLimit` (sets `store.historyLimit`, rebuild), `clearHistory`
  (`store.clearUnpinned`), `toggleSound` (toggle + preview + rebuild),
  `chooseSound` (set `soundName`, force `soundEnabled=true`, preview via
  `Feedback.play(named:)`, rebuild), `toggleDebug` (flips UserDefaults `debugLog`),
  `toggleLaunchAtLogin` (`SMAppService.mainApp.register/unregister`), `about`
  (NSAlert), `quit`, `promptAccessibility` (`AXIsProcessTrustedWithOptions` with
  prompt).

### `Sources/Cliphoard/App/HotKey.swift`
`final class HotKey`. Fields: `ref: EventHotKeyRef?`, `handler: EventHandlerRef?`,
`id = EventHotKeyID(signature: OSType(0x4454_4F48) /* 'DTOH' */, id: 1)`,
`onPressed: (() -> Void)?`. `register(keyCode:modifiers:)` installs a
`kEventClassKeyboard`/`kEventHotKeyPressed` handler on
`GetApplicationEventTarget()` then calls `RegisterEventHotKey`; the C callback
dispatches `onPressed` to main. `unregister()`/`deinit` tear both down. Carbon
chosen as the only reliable no-entitlement system-wide shortcut API.

### `Sources/Cliphoard/Clipboard/ClipItem.swift`
`enum ClipKind: String, Codable, CaseIterable { text, link, color, image, file }`
with `symbolName` (`text.alignleft`/`link`/`paintpalette`/`photo`/`doc`) and
`title` (`Text`/`Links`/`Colors`/`Images`/`Files`).
`final class ClipItem: Codable, Identifiable`. **Reference type.** Stored fields:
`let id: UUID`, `let kind: ClipKind` (both immutable); `var text: String`,
`var rtf: Data?`, `var payloadFile: String?` (relative PNG filename),
`var filePath: String?`, `var colorHex: String?`, `var createdAt: Date`,
`var lastUsedAt: Date`, `var pinned: Bool`, `var sourceApp: String?`,
`var useCount: Int`. `init(kind:text:)` sets a fresh `UUID`, both dates to now,
`pinned=false`, `useCount=0`. Derived: `preview`; `characterCountLabel`
(image→"Image", file→last path component, color→hex, else "N character(s)");
**`signature`** dedup key (`img:`/`file:`/`color:`/`text:` prefix).
> **SwiftUI caveat:** because `ClipItem` is a class, mutating an existing item's
> fields in place (e.g. `lastUsedAt`) does not by itself emit `objectWillChange`;
> only the array reorder via `@Published items` does. Audit alongside Tier 6 H1.

### `Sources/Cliphoard/Clipboard/ClipStore.swift`
`@MainActor final class ClipStore: ObservableObject`.
`@Published private(set) var items: [ClipItem] = []`.
`historyLimit: Int` — computed over UserDefaults key `"historyLimit"` (**default
200**; setter writes then calls `trim()`). `dir = …/Application Support/Ditto`;
`indexURL = dir/history.json`; created in `init()`, which then `load()`s.
`storeDirectory` exposes `dir`.
- `add(_:)`: **dedup branch** — if an item with the same `signature` exists, set
  `existing.lastUsedAt = Date()`, `move(existing, toFront:true)`, and **`return`
  early — NO `save()`, NO `Feedback.playCapture()`** (defect, Tier 6.3). Else
  `items.insert(item, at:0)` → `trim()` → `save()` → `Feedback.playCapture()`.
- `togglePin(_:)`: flip `pinned`, `sortStable`, `save`.
- `delete(_:)`: remove by id, delete payload PNG sidecar, `save`.
- `clearUnpinned()`: remove unpinned + their PNGs, `save`.
- `markUsed(_:)`: `lastUsedAt=now`, `useCount+=1`, `move(toFront:true)`, `save`.
- `filtered(kind:query:pinnedOnly:)`: filter pinned → kind → lowercased substring
  across `text`/`filePath`/`colorHex`.
- `counts() -> [ClipKind:Int]`.
- `move(_:toFront:)`: remove + `insert(at:0)` + **`sortStable()`**. Note: the
  front-insert is then re-sorted, so a non-pinned bumped item's position is
  determined by recency sort, not the raw `insert(at:0)` — the explicit insert is
  partly redundant.
- `sortStable()`: pinned-first, then `lastUsedAt` descending.
- `trim()`: **`guard historyLimit > 0 else { return } // 0 = unlimited`** (any
  value ≤ 0 is treated as unlimited — the precise reading); else drops oldest
  **unpinned** beyond the limit (+ their PNGs).
- `save()`: `JSONEncoder` → atomic write. `load()`: decode `[ClipItem]` +
  `sortStable`.

### `Sources/Cliphoard/Clipboard/ClipboardMonitor.swift`
`@MainActor final class ClipboardMonitor`. Fields: `store`, `timer: Timer?`,
`activity: NSObjectProtocol?`, `lastChangeCount: Int` (init from
`NSPasteboard.general.changeCount`), `ignoreChangeCount: Int = -1`.
- `start()`: `ProcessInfo.processInfo.beginActivity(options:
  [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled], reason:
  "Monitoring the clipboard for new copies")`; `Timer(timeInterval: 0.4,
  repeats: true)` whose body hops to `@MainActor` via `Task` and calls `poll()`;
  `tolerance = 0.1`; added to `RunLoop.main` in `.common`.
- `stop()`: invalidates timer + ends activity. **Never called anywhere** — the
  App-Nap activity assertion is therefore held for the entire process lifetime
  (benign).
- `suppressNextChange()`: `ignoreChangeCount = NSPasteboard.general.changeCount + 1`.
- `poll()`: bail if `count == lastChangeCount`; log `change #N types=[…]`; skip
  own-paste / `org.nspasteboard.TransientType` / `org.nspasteboard.ConcealedType`;
  `capture()`; stamp `sourceApp`; `store.add`.
- `capture(from:)` priority — **(1)** file URL (`readObjects([NSURL],
  options: .urlReadingFileURLsOnly)`); **(2)** image (`NSImage(pasteboard:)` +
  `canReadObject([NSImage])`, persisted to `<uuid>.png` via `persistImage`,
  caption "Image W×H"); **(3)** string (`detectKind`, set `colorHex` if color,
  grab `.rtf`).
- `persistImage`: TIFF → `NSBitmapImageRep` → PNG → `<uuid>.png` in store dir.
- `detectKind`: `isColor` (regex
  `^#?([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8}|[0-9A-Fa-f]{3})$`) → `.color`; else `isLink`
  (no spaces, <2048 chars, scheme in http/https/ftp/mailto with host, or mailto)
  → `.link`; else `.text`.
  > **Operator-precedence subtlety:** `[...].contains(scheme) && url.host != nil
  > || scheme == "mailto"` parses as `(A && B) || C`, so a host-less `mailto:`
  > still classifies as `.link` (intended, but fragile — parenthesize).

### `Sources/Cliphoard/Clipboard/Paster.swift`
`@MainActor enum Paster`. `writeToPasteboard(_:store:)`: `clearContents()` then by
kind — image (`writeObjects([NSImage])` from disk), file (`writeObjects([URL as
NSURL])`), default (`setData(rtf)` if present, then `setString(text, .string)`).
`paste(into:)`: activates the app, then `asyncAfter(0.12s)` calls `sendCommandV()`
(`CGEvent` virtual key `0x09` ('v') down/up with `.maskCommand`, posted to
`.cghidEventTap` — requires Accessibility).

### `Sources/Cliphoard/UI/FloatingPanel.swift`
`final class FloatingPanel: NSPanel`. `static let barHeight: CGFloat = 380`.
`var onResignKey: (() -> Void)?`. `init()` — contentRect 800×380; styleMask
`[.borderless, .nonactivatingPanel, .fullSizeContentView]`, backing `.buffered`;
`isFloatingPanel=true`; `level = .mainMenu + 1`; `collectionBehavior =
[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`; `isOpaque=false`;
`backgroundColor=.clear`; `hasShadow=true`; `titleVisibility=.hidden`;
`titlebarAppearsTransparent=true`; `isMovableByWindowBackground=false`;
`hidesOnDeactivate=false`; `animationBehavior=.none`. Overrides
`canBecomeKey`/`canBecomeMain` → `true`. **`setContent<Content:View>(_:)`** builds
a *local* `NSHostingView(rootView: view)`, sets autoresizing `[.width,.height]`,
assigns to `contentView` — **called once at setup; the hosting view is not stored
and `rootView` is never reassigned (Tier 6).** `slideIn()`: `targetScreen()` →
`visibleFrame`; off-screen frame (`y = minY − barHeight`); `alphaValue=1`;
`makeKeyAndOrderFront(nil)`; animate to on-screen over 0.28 s `.easeOut`.
`slideOut(completion:)`: animate off-screen over 0.2 s `.easeIn`, then
`orderOut(nil)` + completion. `targetScreen()`: screen under the mouse, else
`NSScreen.main`. `resignKey()` → `super` + `onResignKey?()`.

### `Sources/Cliphoard/UI/PanelViewModel.swift`
`@MainActor final class PanelViewModel: ObservableObject`. `@Published`: `query`,
`activeKind: ClipKind?`, `pinnedOnly: Bool`, `selection: Int = 0`,
`presentToken: Int = 0`. `let store: ClipStore`. Callbacks `onPaste`, `onClose`.
**`var results: [ClipItem] { store.filtered(...) }`** — a plain computed property,
**NOT `@Published`**; `PanelViewModel` does **not** subscribe to or forward
`store.objectWillChange`. Intents: `resetSelection`, `moveSelection` (wraps modulo
count), `commitSelection`, `deleteSelection` (delete + clamp selection),
`pinSelection`, `quickSelect(n)` (paste `results[n-1]`).

### `Sources/Cliphoard/UI/ContentView.swift`
`struct ContentView: View` with `@ObservedObject var model` and
`@ObservedObject var store`. `body`: `VStack(spacing:0){ toolbar; Divider; cards;
footer }` over `VisualEffectBackground(material: .hudWindow, blending:
.behindWindow)`, `clipShape(RoundedRectangle(cornerRadius:16))`, 1-pt
`Color.primary.opacity(0.12)` border, 8-pt horizontal/top padding.
- `toolbar`: "Cliphoard" title + `categoryChips` + search `TextField($model.query)`
  (width 180; `onChange(query)` → `resetSelection`).
- `categoryChips`: "All", "Pinned", then `ForEach(ClipKind.allCases)` rendering a
  chip **only if `counts[kind] > 0`**.
- `cards`: `ScrollViewReader { proxy in ScrollView(.horizontal) {
  LazyHStack(spacing:14) { let results = model.results; if empty → emptyState else
  ForEach(results.enumerated(), id:\.element.id) { ClipCardView(...).id(idx)
  .onTapGesture { model.selection = idx } } } } }` with three `onChange` hooks:
  `onChange(model.selection)` → `scrollTo(sel, anchor:.center)`;
  `onChange(model.results.first?.id)` → `selection=0` + `scrollTo(0,
  anchor:.leading)`; `onChange(model.presentToken)` → `scrollTo(0,
  anchor:.leading)`. **These hooks only *scroll*; they never *rebuild* the tree —
  the entire (insufficient) live-refresh mechanism (Tier 6).**
- `emptyState`: tray icon + "Nothing copied yet" / "No matches".
- `footer`: key-hint chips (`←→`, `↩`, `⌘1–9`, `⌘P`, **`⌫`** — the in-app footer
  label uses bare `⌫`, though the code requires `⌘⌫`) + `"N item(s)"`.

### `Sources/Cliphoard/UI/ClipCardView.swift`
`struct ClipCardView`. Inputs: `item`, `index`, `selected`, `storeDir`,
`onActivate`/`onPin`/`onDelete`; `@State hovering`. Frame
`Theme.cardWidth × Theme.cardHeight` = **220×250**. Background
`VisualEffectBackground(material: .contentBackground, blending: .withinWindow)`.
`header` (kind icon, `sourceApp ?? kind.title`, pin glyph, `⌘n` badge for
`index < 9`). `content` per kind: image (NSImage from disk, fill+clip) · color
(`Theme.color(fromHex:)` swatch + hex label) · file (`doc.fill` + last path
component, `.lineLimit(2)`) · link (link glyph + blue text, `.lineLimit(6)`) ·
text (`.lineLimit(11)`, top-leading). `footer`: `characterCountLabel` + relative
time. Selection ring (`Theme.accent`, 2.5 pt) + `scaleEffect(1.0)`; else
0.18/0.08 1-pt border + `scaleEffect(0.97)` + spring; `onHover`; double-click →
`onActivate`; context menu Paste / Pin-Unpin / Delete; `.help(item.preview)`.

### `Sources/Cliphoard/UI/Theme.swift`
`enum Theme`: `cardWidth = 220`, `cardHeight = 250`, `accent =
Color.accentColor`, `color(fromHex:)` (handles 3/6/8-digit hex → `Color`).
`struct VisualEffectBackground: NSViewRepresentable` wrapping
`NSVisualEffectView` (`material` default `.hudWindow`; `state = .active`).

### `Sources/Cliphoard/Support/Feedback.swift`
`@MainActor enum Feedback`: `soundEnabled` (UD `"soundEnabled"`, default true),
`soundName` (UD `"soundName"`, default **`"Tink"`**), `availableSounds` (**14**:
Tink, Pop, Glass, Morse, Ping, Bottle, Frog, Funk, Hero, Purr, Submarine, Sosumi,
Blow, Basso), `play(named:)` (`NSSound`, volume 0.4, falls back to
`NSSound.beep()`), `playCapture()` (guarded by `soundEnabled`).
`enum DebugLog`: `enabled` (UD `"debugLog"`, default false), append-only writer to
`…/Cliphoard/debug.log` with ISO-8601 timestamps (a fresh `ISO8601DateFormatter()` is
allocated per write).

### Bundle / build
`Resources/Info.plist`: `CFBundleIdentifier = ai.axiotic.ditto`, version `1.0.0`,
`LSUIElement = true`, `LSMinimumSystemVersion = 13.0`,
`NSAppleEventsUsageDescription`, `NSHighResolutionCapable`,
`CFBundleIconFile = Cliphoard`, `NSHumanReadableCopyright`.
`Scripts/build-app.sh <config=release>`: `swift build -c`, assembles
`build/Cliphoard.app`, copies binary + Info.plist, renders icon via
`Scripts/make-icon.swift` (gradient `#5C6BF5`→`#8C4DEB` rounded rect + white
`doc.on.clipboard.fill` SF Symbol → 10 PNG sizes → `.iconset` → `iconutil`
`.icns`), then **ad-hoc `codesign --force --deep --sign -`**.
> The in-script comment claims ad-hoc signing makes permissions "stick to a stable
> identity" — this is **misleading**: ad-hoc `--sign -` mints a *new* identity each
> build, which is the very reason the Accessibility grant does not survive rebuilds
> (Tier 6.6).

`Scripts/make-icon.swift`: gradient (indigo→purple) clipboard glyph.
`Makefile`: `build` (`swift build`) · `app` (`build-app.sh`, release default) ·
`run` (`app` + `open`) · `install` (`rm -rf /Applications/Cliphoard.app` then copy) ·
`clean` (`swift package clean` + `rm -rf build .build`).

---

## TIER 5 — Current Verified State

| Area | Status | Evidence (re-verified 2026-06-17) |
| --- | --- | --- |
| Compiles (debug + release) | ✅ | `Package.swift` valid; prior `swift build` / `build-app.sh` clean |
| App bundle + icon + launch | ✅ | `/Applications/Cliphoard.app` running (one process via `pgrep -fl Cliphoard`) |
| Accessory launch + status item | ✅ | `.accessory` + `LSUIElement`; status-item code present |
| Capture text/link/color/image/file | ✅ | live `history.json` holds **27 items**; `debug.log` shows `→ captured text/…` |
| Capture while bar closed / backgrounded | ✅ | App-Nap assertion present; `debug.log` captured a Chrome HTML copy (`change #70`) while bar closed |
| Continuous capture (App Nap defeated) | ✅ (fixed) | activity assertion in `start()`; live `debug.log` advances change counts past the App-Nap window |
| Own-paste suppression | ✅ | live `debug.log`: three `→ skipped (our own paste)` entries (changes #71–#73) |
| Dedup / pin / delete / clear / trim / unlimited | ✅ | logic present; live `historyLimit=0` honored (27 items > any nonzero default) |
| Persistence | ✅ | `history.json` present (**119143 bytes**), `load()`/`save()` exercised |
| Global hotkey `⌃⌥⌘V` + Darwin toggle | ✅ | registered; toggle observer present |
| Capture sound + 14-sound picker | ✅ | live `soundName=Frog`, `soundEnabled=1` |
| Debug log | ✅ | **`…/Cliphoard/debug.log` exists (1569 bytes), populated**; live `debugLog=1` |
| **Bar live/refresh on copy & reopen** | ❌ | **primary open defect — Tier 6** |
| Auto-paste (`⌘V`) | ⚠️ | works only if Accessibility granted |
| **Visual QA of the panel UI** | ⚠️ | **never performed** — dev session was headless; nobody has watched the bar render |

**Live persisted state** (`defaults read ai.axiotic.ditto`): `debugLog = 1`,
`historyLimit = 0` (Unlimited), `soundEnabled = 1`, `soundName = Frog`. Note
`soundName` is `Frog`, not the code default `Tink`, and `historyLimit` is `0`, not
the code default `200` — both set via the status menu. The 27 captured items,
custom sound, Unlimited history, and debug logging on are all consistent with a
hands-on debugging session of the refresh defect.

> **Evidence-provenance note (correcting the verifiers):** Verification Report 2
> claimed there is *no* `debug.log` on disk and that the cited log lines are
> unverifiable narrative. That is **wrong** — `~/Library/Application
> Support/Cliphoard/debug.log` exists and contains exactly the cited markers
> (`→ captured`, `→ skipped (our own paste)`). The capture/suppression behavior is
> therefore directly evidenced. **However**, neither the log nor any on-disk
> artifact *proves a render failure occurs* — the refresh defect itself is a
> user-reported symptom plus a consistent static reading of the code, not a fact
> derivable from source alone. **First action for any agent with a real display:
> watch the bar render and refresh.**

---

## TIER 6 — Open Defects

### 6.1 PRIMARY — "the floating bar does not refresh"

**Symptom (user, verbatim across turns):** "when I copy something it doesn't go in
it" · "shows old, not new" · "restarting the app refreshes the clipboard but it
doesn't happen on its own" · "copying doesn't produce a new slot in the bar" ·
"still not refreshing properly".

**What is PROVEN:**
- **Backend capture is correct** even with the bar closed / app not frontmost
  (`history.json` grows to 27 items; `debug.log` shows `→ captured`). **Not a
  capture bug.**
- **The model is current at open time.** A prior instrumented run logged
  `store.items == model.results` count — the value the view *should* render is
  present and correct when `slideIn()` runs. **Not a data bug.**
- Therefore this is a **SwiftUI-in-`NSHostingView`-in-`NSPanel` render bug**: the
  hosting view inside `FloatingPanel` does not re-render `ContentView` to reflect
  `ClipStore` mutations — on reopen, while open, or both.

**Structural smoking gun:** `panel.setContent(ContentView(model, store))` runs
**once** at launch (`setupPanel`). The `NSHostingView` is a *local* in
`setContent` (not stored), so `rootView` cannot even be reassigned without a
refactor. `slideIn()` only animates the frame + `makeKeyAndOrderFront`; the panel
spends almost all its life `orderOut`. Refresh relies entirely on
`@ObservedObject` observation surviving `orderOut → slideIn`, plus three
`onChange` hooks that only *scroll*, never *rebuild*.

**Already tried (necessary but insufficient):** (1) App-Nap opt-out — fixed
*capture*, not refresh; (2) `onChange(model.results.first?.id)` +
`onChange(model.presentToken)` to snap to newest; (3) resetting
`query/activeKind/pinnedOnly` + bumping `presentToken` in `show()`; (4) ensuring a
single clean installed instance.

### 6.2 Ranked root-cause hypotheses

**H1 (highest confidence) — The `NSHostingView` in an ordered-out `NSPanel`
coalesces/drops SwiftUI updates, and `slideIn()` never forces a re-evaluation;
compounded by `PanelViewModel.results` being a non-published computed property
that silently depends on `store`.**
`ContentView` observes two objects (`@ObservedObject var model`, `@ObservedObject
var store`). The live data flows through `store`; `model.results` is
`store.filtered(...)` with **no `@Published` backing on `model`** and **no
forwarding of `store.objectWillChange`**. While the window is `orderOut`, an
`NSHostingView`'s `@ObservedObject` subscriptions can be coalesced/dropped, so on
reorder AppKit redisplays the *last rendered* tree, not a freshly evaluated one —
exactly "needs a restart." The `onChange(model.results.first?.id)` hook is
especially fragile because it derives from a non-published path and only fires as
a side effect of a `body` pass that may never run.
*Fix:* (a) refactor `FloatingPanel` to **store** the `NSHostingView`, then add
`refresh()` that reassigns `rootView` and forces layout:
`hosting.rootView = ContentView(model:model, store:store); hosting.needsLayout =
true; hosting.layoutSubtreeIfNeeded()`, called at the top of `show()` on every
present — or migrate to `NSHostingController` set as `panel.contentViewController`.
(b) Additionally, make `PanelViewModel` republish store changes in `init`
(`store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }`)
to collapse the two-object ambiguity into one deterministic update path. (a) fixes
the *reopen* case regardless of (b); (b) fixes the *live-while-open* case.

**H2 (medium) — The panel never truly becomes key, severing input/observation
timing.** `.nonactivatingPanel` + `.accessory` activation can leave
`panel.isKeyWindow == false` after `slideIn()`. The local key monitor is gated on
`self.panel.isKeyWindow`, so if the panel isn't key, **keyboard navigation also
silently dies** — a second symptom to check. Verify `panel.isKeyWindow == true`
immediately after `slideIn()`.

**H3 (test, don't assume) — `ContentView.body` is not re-executing on
`store.items` change.** Confirm with `let _ = Self._printChanges()` (or a `print`)
at the top of `body`. If `body` does **not** re-run on capture → observation
problem (H1's republish). If it **does** re-run but pixels don't change → display/
redisplay problem (H1's `rootView` reassignment).

**H4 (lower) — Auto-dismiss masks "live-while-open."** `resignKey → onResignKey →
hide` dismisses the bar the moment focus moves to another app to copy, so "fill
while visible" is structurally impossible today; the only supported flow is **copy
→ summon**. Additionally, `resignKey` fires whenever the panel loses key status
for *any* reason (e.g. the AX prompt or About alert calling `NSApp.activate`),
which can auto-dismiss the bar — a plausible contributor to perceived flakiness.
Decide product behavior: document copy-then-summon, or add a "pin open / no
auto-dismiss" mode.

**H5 (cheap to rule out) — Stale duplicate instance** (an old login-item build)
masking fixes during manual testing. *Currently ruled out:* `pgrep -fl Cliphoard`
shows exactly one process from `/Applications/Cliphoard.app`.

### 6.3 Secondary / related issues found while reading source

- **`ClipStore.add` dedup-bump path does not `save()`** (`ClipStore.swift`,
  add-branch returns after `existing.lastUsedAt = Date()` + `move(...)`). When a
  duplicate is re-copied, the reorder/timestamp change lives only in memory and is
  never persisted until some other `save()` fires; after restart the order can
  differ from what the user last saw. Independent of the render bug but produces
  "order looks wrong" reports. *Fix:* call `save()` (and decide whether
  `Feedback.playCapture()` should fire on a dup-bump).
- **`presentToken` only drives `scrollTo`, not a rebuild;** the `show()` resets of
  `query/activeKind/pinnedOnly` likewise only change inputs to an un-re-evaluated
  `body`.
- **`move(_:toFront:)` inserts at 0 then immediately `sortStable()`,** so the raw
  front-insert is overridden by the pinned-first/recency sort — the explicit
  `insert(at:0)` is partly redundant.
- **`isLink` operator precedence** (`(A && B) || C`) — host-less `mailto:` still
  classifies as `.link`; parenthesize for clarity.
- **`ClipboardMonitor.stop()` is never invoked** — the App-Nap activity assertion
  is held for the whole process lifetime (benign).
- **No CFNotification observer removal** in `AppDelegate` (process-lifetime
  singleton, benign).

### 6.4 Debugging protocol (requires a real display)

1. **Confirm re-evaluation.** Add `let _ = Self._printChanges()` (or a `print`) at
   the top of `ContentView.body`. Copy items with the bar **open** and watch the
   console. `body` does NOT re-run on `store.items` change → **H1/H3 observation**.
   `body` re-runs but the screen doesn't change → **H1 display/redisplay**.
2. **Isolate the panel.** Stand up a throwaway `.regular` `NSWindow` hosting the
   *same* `ContentView(model, store)`. Regular window updates live but panel
   doesn't → **H1/H2 (panel-specific)**. Neither updates → **H3 (observation)**.
3. **Check key status.** Log `panel.isKeyWindow` right after `slideIn()`'s
   animation completes → tests **H2** (and explains dead keyboard nav if false).
4. **Apply fixes in order:** H1 (a) store the hosting view + reassign `rootView` /
   move to `NSHostingController` on every `show()`; then H1 (b) republish
   `store.objectWillChange` through `model`. Re-test **reopen first** (highest
   value), then live-while-open.
5. **Decide live-while-open product behavior (H4).** Either document copy-then-
   summon, or add a pin-open / no-auto-dismiss mode.
6. **Rule out H5** (`pgrep -fl Cliphoard`; one installed instance).

### 6.5 Acceptance criteria for "refresh fixed"

- Bar **closed** → copy N items → `⌃⌥⌘V` → newest item is the first card and all N
  present, **every time, no restart.**
- Bar **open** (if a pin-open mode is added) → copying elsewhere inserts a new
  front card within ≤ 0.5 s while the bar stays open.
- Keyboard nav (`←→ ↩ ⌘1–9`) works on the freshly summoned bar (validates H2).
- **Visually confirmed on a real display** — not just `history.json`.

### 6.6 SECONDARY DEFECT — Accessibility grant does not survive rebuilds

`build-app.sh` ad-hoc signs (`codesign --force --deep --sign -`), so the code
identity changes on **every rebuild**. macOS keys the Accessibility grant to code
identity, so it is forgotten on each rebuild → the auto-paste `⌘V` silently fails
until re-granted, and the menu re-shows "Grant Accessibility…". The launch-time
prompt was intentionally removed (it nagged on every launch/reinstall); the prompt
is now lazy (`commit` when `!AXIsProcessTrusted()`, once via `didPromptAX`) plus a
menu item. **Durable fix: a stable self-signed identity** — must be user-approved
(it writes to the login keychain).

---

## TIER 7 — Prioritized Backlog

**P0 — Correctness (blocking)**
1. **Fix the refresh defect (Tier 6).** Refactor `FloatingPanel` to store the
   `NSHostingView`; reassign `rootView` / adopt `NSHostingController` on each
   `show()`; republish `store.objectWillChange` through `PanelViewModel`. **Verify
   on a real display.**
2. **First-ever visual QA pass** of the whole panel on a real display: layout,
   contrast, empty state, very long text (11-line clamp), large images,
   multi-monitor `targetScreen()`.
3. **Persist the dup-bump reorder in `ClipStore.add`** (call `save()`), so
   reopened/after-restart order matches the last in-memory order.

**P1 — Permission durability & distribution**
4. **Stable code signing** so the AX grant survives rebuilds. Add a user-run,
   one-time `Scripts/setup-signing.sh` creating a self-signed "Cliphoard Local
   Signing" identity; have `build-app.sh` prefer it over ad-hoc; fix the
   misleading "stable identity" comment in `build-app.sh`. (Must be user-approved
   — modifies login keychain.)
5. First-run onboarding explaining the Accessibility requirement.
6. Optional Developer-ID signing + notarization.

**P2 — Paste parity**
7. Paste-as-plain-text modifier (e.g. `⌥↩` / `⌥`-held quick-paste) — strip `rtf`
   in `Paster.writeToPasteboard`.
8. Paste stack / queue — multi-select, ordered paste; new selection model in
   `PanelViewModel`.
9. Named pinboards beyond the single `pinned` boolean — a `board: String?` on
   `ClipItem`, board chips in `categoryChips`.
10. Customizable global hotkey (recorder UI; persist; re-`register` `HotKey`).
11. Smart actions: open links, copy color as rgb/hsl (context-menu extensions in
    `ClipCardView`).
12. In-app Settings window replacing the status submenu.
13. Doc/keyboard-model polish: README line 14/31 (`⌘⌫`) already agrees with the
    code; the in-app footer label shows bare `⌫` and should read `⌘⌫`; note
    `↑/↓` are no-op-by-design.

**P3 — Sync & scale**
14. iCloud or file-based sync.
15. Large-history performance with 5k+ items / large images (cards currently load
    full `NSImage(contentsOf:)` per render → add on-disk thumbnails; `LazyHStack`
    already virtualizes).

**P4 — Quality / CI**
16. Add a test target (none exists). Unit tests: `detectKind`, `signature` dedup,
    `trim`/unlimited, persistence round-trip, RTF/image/file fidelity.
17. Snapshot/UI tests for the bar; macOS CI (GitHub Actions) building the app +
    running tests.

---

## TIER 8 — Base Reference

### 8.1 Build / run commands
```
make build      # swift build (debug)
make app        # Scripts/build-app.sh → build/Cliphoard.app (release default)
make run        # app + open build/Cliphoard.app
make install    # rm -rf /Applications/Cliphoard.app then copy build/Cliphoard.app there
make clean      # swift package clean + rm -rf build .build

swift build [-c release]                 # direct SwiftPM build
Scripts/build-app.sh [debug|release]     # assemble + icon + ad-hoc codesign
```
Scriptable toggle (no hotkey needed): post the Darwin notification
`ai.axiotic.ditto.toggle` (CFNotificationCenter Darwin name, `.deliverImmediately`)
that `AppDelegate.setupRemoteToggle` listens for.

### 8.2 File map (`Sources/Cliphoard/`)
```
App/
  Main.swift            @main struct Main; .accessory; objc_setAssociatedObject retain
  AppDelegate.swift     conductor; status menu; panel/hotkey/toggle wiring; handleKey; commit
  HotKey.swift          Carbon RegisterEventHotKey; sig 'DTOH' (0x4454_4F48), id 1
Clipboard/
  ClipItem.swift        ClipKind enum; ClipItem class (Codable, Identifiable); signature
  ClipStore.swift       @Published items; add/trim/sortStable/save/load; historyLimit
  ClipboardMonitor.swift 0.4s timer; App-Nap assertion; capture priority; detectKind
  Paster.swift          writeToPasteboard; paste(into:) CGEvent ⌘V after 0.12s
UI/
  FloatingPanel.swift   NSPanel; barHeight 380; slideIn 0.28s / slideOut 0.2s; setContent (once)
  PanelViewModel.swift  @Published query/activeKind/pinnedOnly/selection/presentToken; results (computed)
  ContentView.swift     toolbar/cards/footer; 3 onChange scroll hooks; .hudWindow background
  ClipCardView.swift    220×250 card; per-kind content; .contentBackground material
  Theme.swift           cardWidth/Height 220/250; VisualEffectBackground (default .hudWindow)
Support/
  Feedback.swift        Feedback (14 sounds, default Tink); DebugLog (→ debug.log)
Resources/Info.plist    ai.axiotic.ditto; 1.0.0; LSUIElement; LSMinimumSystemVersion 13.0
Scripts/                build-app.sh (ad-hoc codesign); make-icon.swift
Package.swift · Makefile · README.md
```

### 8.3 Persistence layout (`~/Library/Application Support/Ditto/`)
```
history.json    JSONEncoder([ClipItem]), atomic write; load() + sortStable on init
<uuid>.png      image payloads (TIFF → NSBitmapImageRep → PNG); deleted with the item
debug.log       append-only, ISO-8601-stamped; written only when DebugLog.enabled
```
Live at draft time: `history.json` = 119143 bytes / 27 items; `debug.log` = 1569
bytes (contains `→ captured` and `→ skipped (our own paste)` markers).

### 8.4 Constants & defaults
```
Global hotkey        ⌃⌥⌘V  = kVK_ANSI_V + (controlKey|optionKey|cmdKey)
HotKey id            EventHotKeyID(signature: 0x4454_4F48 'DTOH', id: 1)
Poll interval        0.4 s, tolerance 0.1, RunLoop.main / .common
App-Nap reason       "Monitoring the clipboard for new copies"
Panel                contentRect 800×380; barHeight 380; level .mainMenu+1
                     styleMask [.borderless, .nonactivatingPanel, .fullSizeContentView]
                     collectionBehavior [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
slideIn / slideOut   0.28 s easeOut / 0.2 s easeIn
Paste delay          0.12 s before CGEvent ⌘V (virtualKey 0x09, .maskCommand, .cghidEventTap)
Card                 220 × 250; lineLimit text 11 / link 6 / file 2
Backgrounds          panel .hudWindow/.behindWindow; card .contentBackground/.withinWindow
History limits       0 (Unlimited) / 100 / 200 / 500 / 1000 / 5000; trim guard: historyLimit > 0
detectKind link      no spaces, <2048 chars, scheme ∈ {http,https,ftp,mailto}+host, or mailto
detectKind color     ^#?([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8}|[0-9A-Fa-f]{3})$
Sounds (14)          Tink, Pop, Glass, Morse, Ping, Bottle, Frog, Funk, Hero, Purr,
                     Submarine, Sosumi, Blow, Basso (NSSound volume 0.4; fallback beep)
UserDefaults keys    historyLimit (200) · soundEnabled (true) · soundName ("Tink") · debugLog (false)
Live UserDefaults    historyLimit=0 · soundEnabled=1 · soundName=Frog · debugLog=1
Bundle id            ai.axiotic.ditto · version 1.0.0 · CFBundleIconFile Cliphoard
```

### 8.5 Decisions log
- **`@main struct Main`, not `main.swift`** — avoids the top-level-code vs
  `@MainActor` conflict under SwiftPM.
- **Carbon `RegisterEventHotKey`** — the only reliable no-entitlement system-wide
  shortcut API.
- **`.accessory` + `LSUIElement`** — menu-bar utility; no Dock icon, no main
  window.
- **App-Nap opt-out** — the timer must keep polling while backgrounded; this fixed
  the capture stall (does NOT fix the refresh defect).
- **No launch-time AX prompt** — it re-nagged after every ad-hoc rebuild changed
  code identity; replaced by a lazy once-prompt + a conditional menu item.
- **Ad-hoc codesign** — convenient for local dev, but mints a new identity each
  build → AX grant lost on rebuild (Tier 6.6). Move to a stable self-signed
  identity.
- **Single `pinned` boolean** (not named boards) — current scope; named pinboards
  are planned.
- **Auto-dismiss on `resignKey`** — keeps the bar transient, but makes
  "live-while-open" impossible; revisit with a pin-open mode (H4).

### 8.6 Environment notes
- Built/run on macOS 26 / Darwin 25.6 / arm64, Swift 5.9 tools; min deploy
  macOS 13.
- Auto-paste `⌘V` requires Accessibility; the clip is on the pasteboard regardless.
- The original development/debugging session was **headless**: `screencapture`
  failed and synthetic hotkeys via `osascript`/System Events were swallowed (the
  automation host lacked Accessibility). **No one has visually watched the bar
  render** — capture verification is via `history.json` + `debug.log`, and the
  render-bug hypotheses, while consistent with the code, are not provable from
  static source. Any agent with a real display should watch the bar first.
- Exactly one `Cliphoard` process currently runs, from `/Applications/Cliphoard.app`.

---

### One-paragraph handoff
Cliphoard reliably **captures** every copy (text/link/color/image/file) into a
persistent, unlimited, pinnable, searchable history (live: 27 items,
`historyLimit=0`, sound `Frog`, debug on), suppresses its own paste-backs
(proven in `debug.log`), and summons a Paste-style slide-up `NSPanel` on `⌃⌥⌘V`.
The one blocking problem is that the **bar's SwiftUI content does not refresh** to
reflect `ClipStore` — capture and data are proven correct at open time, so the bug
lives in the `NSHostingView`-inside-`NSPanel` update path, made worse by
`setContent` running only once at launch with the hosting view unstored and
`rootView` never reassigned. Start by refactoring `FloatingPanel` to store the
hosting view and reassign `rootView` (or move to `NSHostingController`) on every
`show()`, republish `store.objectWillChange` through `PanelViewModel`, verify
`panel.isKeyWindow` after `slideIn()` (it also gates keyboard nav), fix the
non-persisting dedup-bump in `ClipStore.add`, and **watch it render on a real
display** — the original session was headless. Separately, move off ad-hoc signing
so the Accessibility grant (required for auto-paste `⌘V`) survives rebuilds.
