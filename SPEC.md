# Ditto — Engineering Specification & Handoff

> **Byzantine pyramid.** Read top‑down. The apex is the single irreducible idea.
> Each tier below widens — adding breadth and resolution — until the base, which
> is the exhaustive ground‑level reference. An agent in a hurry reads the top
> three tiers; an agent *continuing the work* reads to the base.

```
                                   ╱╲
                                  ╱T0╲                 APEX — the one sentence
                                 ╱────╲
                                ╱  T1  ╲               PRINCIPLES
                               ╱────────╲
                              ╱    T2    ╲             FEATURE SURFACE
                             ╱────────────╲
                            ╱      T3      ╲           ARCHITECTURE & DATA FLOW
                           ╱────────────────╲
                          ╱        T4        ╲         COMPONENT SPEC (exhaustive)
                         ╱────────────────────╲
                        ╱          T5          ╲       STATE — built & verified
                       ╱────────────────────────╲
                      ╱            T6            ╲     OPEN DEFECTS (refresh bug)
                     ╱────────────────────────────╲
                    ╱              T7              ╲   BACKLOG — what must be built
                   ╱────────────────────────────────╲
                  ╱                T8                ╲ BASE — build, files, decisions
                 ╱────────────────────────────────────╲
                ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
```

Repository: **https://github.com/AntreasAntoniou/ditto** · Local: `~/Projects/ditto`
Last updated: 2026‑06‑17 · Platform: macOS 13+ (built & run on macOS 26 / arm64, Swift 5.10, Xcode 15.4)

---

## T0 — APEX (the one sentence)

**Ditto is a native macOS menu‑bar clipboard manager whose history bar slides up
from the bottom of the screen on `⌃⌥⌘V`, mirroring the feature set of the “Paste” app.**

---

## T1 — PRINCIPLES

1. **Native, not Electron.** Swift + AppKit + SwiftUI only. No web stack, no
   account, no telemetry, no network calls.
2. **Background‑first.** Runs as an `.accessory` (LSUIElement) app: no Dock icon,
   a menu‑bar status item, and a single floating panel.
3. **Capture is sacred.** Anything the user copies — at any time, in any app,
   whether the bar is open or closed — must be recorded. This is the product’s
   core promise and the source of the current open defect (see **T6**).
4. **Keyboard‑driven.** Summon, navigate, paste, pin, delete — all without the
   mouse.
5. **Local & durable.** History persists to `~/Library/Application Support/Ditto`.
6. **Paste parity.** When a feature decision is ambiguous, do what Paste does.

---

## T2 — FEATURE SURFACE

### Implemented (see T5 for verification status)
- Slide‑up floating bar from the bottom edge of the active screen.
- Global hotkey **`⌃⌥⌘V`** (Control+Option+Command+V) to toggle the bar.
- Automatic capture & classification of pasteboard content into kinds:
  **text, link, color (hex), image, file**.
- Persisted history with **configurable limit** including **Unlimited**.
- Per‑item **pinning** (survives trimming, floats to front).
- **Search** (substring across text / file path / color).
- **Category filters**: All · Pinned · Text · Links · Colors · Images · Files
  (with live counts; only non‑empty categories show).
- **Auto‑paste**: selecting a clip writes it to the pasteboard and issues `⌘V`
  into the previously‑focused app.
- **Keyboard**: `←→` navigate, `↩` paste, `⌘1–9` quick‑paste, `⌘P` pin,
  `⌘⌫` delete, `esc` dismiss.
- **Capture sound**: subtle tick on capture, **choosable** from 14 system
  sounds, with on/off toggle.
- **Launch at login** (SMAppService).
- **Privacy**: honors `org.nspasteboard` transient/concealed markers.
- **Diagnostics**: optional debug log of every pasteboard event.
- **App Nap opt‑out** so background polling never stalls.
- **Scriptable toggle** via Darwin notification `ai.axiotic.ditto.toggle`.

### Not yet built (see T7)
iCloud/file sync · paste stack/queue · paste‑as‑plain‑text · in‑app settings
window · customizable hotkey UI · smart actions on links/colors · RTF/file/image
fidelity round‑trip tests · onboarding/permission UX · notarized signed build.

---

## T3 — ARCHITECTURE & DATA FLOW

### Process shape
A single `.accessory` `NSApplication`. `AppDelegate` owns everything. There is no
main window — only the menu‑bar `NSStatusItem` and one `FloatingPanel` (NSPanel).

### The capture loop (works — verified)
```
NSPasteboard.general
      │  (changeCount polled every 0.4s; timer in .common run‑loop modes;
      │   process held awake by an NSProcessInfo activity assertion)
      ▼
ClipboardMonitor.poll()  ──class/skip──►  capture() → ClipItem
      │                                        │
      │  (sourceApp stamped from frontmost app)│
      ▼                                        ▼
ClipStore.add(item)  ──dedup by signature──►  items.insert(0) + trim() + save()
      │                                        │
      ▼                                        ▼
@Published items  (drives SwiftUI)        history.json + <uuid>.png on disk
      │
      └── Feedback.playCapture()  (subtle sound)
```

### The presentation path (this is where the open defect lives — see T6)
```
HotKey (Carbon)  ─or─  Darwin toggle  ─or─  menu “Open Ditto”
      ▼
AppDelegate.toggle() → show()
      │  capture previousApp; reset model.query/filters; model.presentToken++ ;
      │  NSApp.activate; panel.slideIn()
      ▼
FloatingPanel (NSPanel, borderless, nonactivating)
      │  contentView = NSHostingView(rootView: ContentView(model, store))
      ▼
ContentView (SwiftUI)  reads  model.results  ← store.filtered(items)
```

### The paste path (works)
```
commit(item) → store.markUsed → monitor.suppressNextChange()
      → Paster.writeToPasteboard(item) → (if AX trusted) hide+Paster.paste(⌘V)
```

### Key invariants
- All mutation of `ClipStore`/UI happens on the **main actor**.
- `ClipStore` is the single source of truth; the panel is a pure projection.
- `monitor.suppressNextChange()` prevents Ditto’s own paste write from being
  re‑captured.

---

## T4 — COMPONENT SPEC (exhaustive)

### `Sources/Ditto/App/Main.swift`
`@main struct Main` with `@MainActor static func main()`. Creates
`NSApplication`, sets delegate, `setActivationPolicy(.accessory)`, retains the
delegate via associated object, `app.run()`. (Not named `main.swift` on purpose,
so top‑level‑code rules don’t conflict with `@MainActor`.)

### `Sources/Ditto/App/AppDelegate.swift`
The conductor. Owns `store`, `monitor`, `model`, `panel`, `hotKey`, `statusItem`.
- `applicationDidFinishLaunching`: status item, panel, hotkey, remote toggle,
  `monitor.start()`. **Deliberately does NOT prompt for Accessibility** (that
  re‑nagged every launch / reinstall).
- `rebuildMenu()`: builds the status menu — Open · History Limit (Unlimited /
  100 / 200 / 500 / 1000 / 5000) · Launch at Login · Play Sound on Copy · Copy
  Sound (14 choices) · Debug Logging · [Grant Accessibility… if untrusted] ·
  Clear Unpinned · About · Quit.
- `show()/hide(paste:)`: drives `panel.slideIn/slideOut`, tracks `previousApp`,
  `isVisible`, `isClosing` (recursion guard for resignKey→hide).
- `commit(item)`: write to pasteboard always; prompt AX once lazily if missing;
  paste only if trusted.
- `handleKey(_:)`: local `NSEvent` monitor active while panel is key. Carbon key
  codes: esc=53, ←=123, →=124, ↑/↓ swallowed, ↩=36/76, ⌘⌫ delete, ⌘P pin,
  ⌘1–9 quick‑select. Non‑matching events pass through to the search field.
- `setupHotKey()`: registers `⌃⌥⌘V` via `HotKey` (Carbon modifiers
  `controlKey|optionKey|cmdKey`, key `kVK_ANSI_V`).
- `setupRemoteToggle()`: Darwin notification observer `ai.axiotic.ditto.toggle`.

### `Sources/Ditto/App/HotKey.swift`
Carbon `RegisterEventHotKey` wrapper. Single hotkey, callback `onPressed`.
Carbon is deprecated but the most reliable system‑wide shortcut without extra
entitlements.

### `Sources/Ditto/Clipboard/ClipItem.swift`
`final class ClipItem: Codable, Identifiable`. Fields: `id`, `kind` (`ClipKind`
enum: text/link/color/image/file), `text`, `rtf: Data?`, `payloadFile: String?`
(relative png filename for images), `filePath: String?`, `colorHex: String?`,
`createdAt`, `lastUsedAt`, `pinned`, `sourceApp`, `useCount`. Derived: `preview`,
`characterCountLabel`, `signature` (dedup key).

### `Sources/Ditto/Clipboard/ClipStore.swift`
`@MainActor ObservableObject`. `@Published private(set) var items`. Methods:
`add` (dedup by signature → move to front else insert@0, trim, save, play sound),
`togglePin`, `delete`, `clearUnpinned`, `markUsed`, `filtered(kind,query,pinnedOnly)`,
`counts()`, `trim()` (skips when `historyLimit == 0` = unlimited), `save()/load()`
(JSON at `~/Library/Application Support/Ditto/history.json`). `historyLimit` is a
UserDefaults‑backed computed var (default 200; **currently set to 0/unlimited**).

### `Sources/Ditto/Clipboard/ClipboardMonitor.swift`
`@MainActor`. `start()` creates a `Timer(0.4s)` added to `RunLoop.main` in
`.common` modes **and** begins an `NSProcessInfo` activity assertion
(`.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled`) to defeat
App Nap. `poll()` compares `changeCount`, logs to `DebugLog`, skips
own‑paste/transient/concealed, calls `capture()`, stamps `sourceApp`, `store.add`.
`capture()` priority: file URL → image (persist png) → string (classify
link/color/text, grab RTF). `suppressNextChange()` sets `ignoreChangeCount`.

### `Sources/Ditto/Clipboard/Paster.swift`
`writeToPasteboard(item,store)` (image/file/rtf+string). `paste(into:)` activates
the previous app and posts `⌘V` via `CGEvent` (needs Accessibility).

### `Sources/Ditto/UI/FloatingPanel.swift`
`NSPanel` subclass: borderless, nonactivating, `.fullSizeContentView`, clear
background, level `.mainMenu+1`, joins all spaces. `barHeight = 380`.
`setContent(_:)` wraps a SwiftUI view in `NSHostingView` (autoresizing) and
assigns to `contentView`. `slideIn()/slideOut()` animate the frame from below the
`visibleFrame` of the screen under the mouse. `resignKey` → `onResignKey` (used to
auto‑dismiss). **This component is central to the T6 defect.**

### `Sources/Ditto/UI/PanelViewModel.swift`
`@MainActor ObservableObject`. `@Published`: `query`, `activeKind`, `pinnedOnly`,
`selection`, `presentToken`. `results` computed = `store.filtered(...)`. Intents:
`moveSelection`, `commitSelection`, `deleteSelection`, `pinSelection`,
`quickSelect`. Callbacks `onPaste`, `onClose` wired by AppDelegate.

### `Sources/Ditto/UI/ContentView.swift`
The bar. VStack: toolbar (title, category chips, search field) · cards
(horizontal `ScrollView`+`LazyHStack` of `ClipCardView`, inside `ScrollViewReader`)
· footer (shortcut hints + count). `onChange(model.selection)` scrolls selection
into view; `onChange(model.results.first?.id)` snaps to front on new clip;
`onChange(model.presentToken)` snaps to front on open. **These onChange handlers
are the current (insufficient) refresh mechanism — see T6.**

### `Sources/Ditto/UI/ClipCardView.swift`
Per‑item card (220×250). Header (kind icon, sourceApp, pin, `⌘n`), type‑specific
body (text/image/color swatch/file/link), footer (size + relative time). Hover,
double‑click to paste, context menu (Paste/Pin/Delete).

### `Sources/Ditto/UI/Theme.swift`
Palette, `color(fromHex:)`, `VisualEffectBackground` (NSVisualEffectView wrapper).

### `Sources/Ditto/Support/Feedback.swift`
`Feedback`: `soundEnabled`, `soundName` (default “Tink”), `availableSounds` (14),
`play(named:)`, `playCapture()`. `DebugLog`: `enabled` (UserDefaults `debugLog`),
append‑only writer to `…/Ditto/debug.log`.

### Bundle / build
`Resources/Info.plist` (LSUIElement, bundle id `ai.axiotic.ditto`,
NSAppleEventsUsageDescription, min macOS 13). `Scripts/build-app.sh` builds
release, assembles `build/Ditto.app`, renders icon via `Scripts/make-icon.swift`
+ `iconutil`, **ad‑hoc** codesigns. `Makefile`: `build|app|run|install|clean`.

---

## T5 — STATE: BUILT & VERIFIED

| Area | Status | Evidence |
|---|---|---|
| Compiles (debug+release) | ✅ | `swift build` / `build-app.sh` clean |
| App bundle + icon + launch | ✅ | runs as accessory, status item visible |
| Capture text/link/color/image/file | ✅ | classified correctly in `history.json` |
| Capture **while bar closed** | ✅ | 3 copies w/ pane closed → all 3 at top |
| Capture **continuous (App Nap)** | ✅ (fixed) | activity assertion added |
| Dedup, pin, delete, clear, trim | ✅ | logic exercised; unlimited honored |
| Persistence across restart | ✅ | history reloads; reload shows current set |
| Global hotkey `⌃⌥⌘V` | ✅ | toggles without crash |
| Sound on capture + picker | ✅ | 14 sounds, preview on select |
| Debug log | ✅ | `change #N types=[…] → captured …` |
| **Bar live/refresh on reopen** | ❌ | **see T6 — primary open defect** |
| Auto‑paste (⌘V) | ⚠️ | works *if* Accessibility granted |
| Visual QA of the panel UI | ⚠️ | NOT done — headless session can’t screencapture |

> **Critical caveat for the next agent:** the development session was headless —
> `screencapture` returns *“could not create image from display”* and synthetic
> hotkeys via `osascript`/`System Events` are swallowed (no Accessibility for the
> automation host). **Nobody has visually watched the bar render.** All capture
> verification is via `history.json` and the debug log. The refresh defect is
> therefore diagnosed indirectly. **First action for a continuing agent with a
> real display: actually watch it.**

---

## T6 — OPEN DEFECTS (the refresh bug — deep dive)

### Symptom (user, verbatim across turns)
- “when I copy something it doesn’t go in it”
- “shows old, not new”
- “restarting the app refreshes the clipboard but it doesn’t happen on its own”
- “copying doesn’t produce a new slot in the bar”
- “still not refreshing properly”

### What is PROVEN about it
- The **backend captures correctly** even while the bar is closed and while the
  app is not frontmost (`history.json` grows; debug log shows `→ captured`).
- At `show()` time the **model is current**: an earlier instrumented log line
  read `store.items=8 model.results=8` — i.e. the data the view *should* render
  is present and correct at the moment the panel opens.
- Therefore this is **NOT a capture bug** and **NOT a data bug**. It is a
  **UI refresh / SwiftUI‑in‑NSPanel rendering bug**: the `NSHostingView` inside
  the `FloatingPanel` is not re‑rendering to reflect `ClipStore` changes — either
  live while open, or on reopen, or both.

### What has already been tried (and did NOT fully resolve it)
1. App Nap opt‑out (fixed the *capture* stall; the user still reports refresh
   problems, so this was necessary but not sufficient).
2. `onChange(model.results.first?.id)` and `onChange(model.presentToken)` to snap
   the strip to the newest item on new‑clip and on open.
3. Resetting `query`/`activeKind`/`pinnedOnly` and bumping `presentToken` in
   `show()`.
4. Ensuring a single clean installed instance (killed strays, installed to
   `/Applications`).

### Leading hypotheses (ranked) for the next agent
1. **NSHostingView in an ordered‑out NSPanel drops/*coalesces* SwiftUI updates.**
   While the panel is `orderOut`, the view’s window is effectively off‑screen;
   updates published by `ClipStore` may not be applied, and `slideIn()` may not
   force a fresh evaluation. Even though `model.results` is current *value‑wise*,
   the rendered tree may be stale.
   **Fix to try first:** on every `show()`, **reassign the rootView** so AppKit is
   forced to rebuild:
   `hostingView.rootView = ContentView(model: model, store: store)` — or switch to
   `NSHostingController` set as `panel.contentViewController` and refresh it. Add a
   `FloatingPanel.refresh()` that does `hostingView.rootView = …;
   hostingView.needsLayout = true; hostingView.layoutSubtreeIfNeeded()`.
2. **The panel/hosting view is retained but its SwiftUI environment/observation
   is severed** because the panel never properly becomes key (nonactivating +
   accessory). Verify `panel.isKeyWindow` is actually true after `slideIn()`; if
   not, the `@ObservedObject` updates may still apply but input/scroll won’t.
3. **Two observable objects, one path.** `ContentView` observes both `model` and
   `store`. Confirm with a breakpoint/log that `ContentView.body` actually
   re‑executes when `store.items` changes while the panel is **visible**. If body
   does NOT re‑run, the subscription is the problem; if it DOES run but the screen
   doesn’t change, it’s a display/redisplay problem (hypothesis 1).
4. **Stale duplicate instance** masking the fix during manual testing (the user
   may have an old login‑item build running). Ensure exactly one process.

### Recommended debugging protocol (with a real display)
1. Build a **throwaway regular‑window harness**: a normal `NSWindow` (activation
   policy `.regular`) hosting the *same* `ContentView(model, store)`. Copy things
   and watch. If the regular window updates live but the panel doesn’t →
   confirms hypothesis 1/2 (panel‑specific). If neither updates → confirms
   hypothesis 3 (observation).
2. Add a temporary `let _ = Self._printChanges()` (SwiftUI) or a `print` in
   `ContentView.body` to confirm re‑evaluation timing.
3. Apply hypothesis‑1 fix (rootView reassignment / NSHostingController) and
   re‑test both live‑while‑open and reopen.
4. Decide product behavior for **live‑while‑open**: today the panel auto‑dismisses
   on `resignKey`, so a user cannot keep it open and copy elsewhere (focus moves →
   dismiss). The supported flow is **copy → summon**. If the user expects the bar
   to fill *while visible*, either (a) document copy‑then‑summon clearly, or
   (b) add a “pin open / don’t auto‑dismiss” mode.

### Acceptance criteria for “refresh fixed”
- With the bar **closed**, copy N items; press `⌃⌥⌘V`; the newest item is the
  first card and all N are present — **every time, no restart**.
- With the bar **open** (if a pinned‑open mode is added), copying in another app
  inserts a new card at the front within ≤0.5s.
- Visually confirmed on a real display (not just `history.json`).

---

## T7 — BACKLOG (what must be built, prioritized)

**P0 — Correctness**
- [ ] **Fix the refresh defect** (T6). Highest priority. Visually verify.
- [ ] Visual QA pass of the entire panel UI on a real display (layout, contrast,
      empty state, long text, large images).

**P1 — Permission durability & distribution**
- [ ] **Stable code signing** so the Accessibility grant survives rebuilds.
      Add `Scripts/setup-signing.sh` (user‑run, one‑time, needs their password)
      that creates a self‑signed code‑signing identity “Ditto Local Signing”
      and have `build-app.sh` prefer it over ad‑hoc. *Note: a prior attempt to do
      this automatically was correctly blocked — it modifies the login keychain
      and must be explicitly user‑approved.*
- [ ] First‑run onboarding explaining the Accessibility requirement.
- [ ] Optional: Developer ID signing + notarization for distribution.

**P2 — Paste parity features**
- [ ] Paste stack / queue (collect multiple, paste in order).
- [ ] Paste‑as‑plain‑text modifier (e.g. `⌥↩`).
- [ ] In‑app Settings window (replaces/augments the menu): hotkey picker, limit,
      sound, sync, appearance.
- [ ] Customizable global hotkey (record UI; persist; re‑register `HotKey`).
- [ ] Smart actions on links (open) and colors (copy as rgb/hsl).
- [ ] Pinboards as first‑class named groups (beyond a single pinned flag).

**P3 — Sync & scale**
- [ ] iCloud or file‑based sync across machines.
- [ ] Large‑history performance (virtualized list already via LazyHStack; verify
      with 5k+ items and big images; consider thumbnailing).

**P4 — Quality**
- [ ] Unit tests: classification (`detectKind`), dedup `signature`, trim/unlimited,
      persistence round‑trip, RTF/image/file fidelity.
- [ ] UI tests / snapshot tests for the bar.
- [ ] CI (GitHub Actions, macOS runner) building the app and running tests.

---

## T8 — BASE (build, files, decisions, environment)

### Build & run
```bash
cd ~/Projects/ditto
make app        # → build/Ditto.app (release, icon, ad‑hoc signed)
make run        # build + open
make install    # copy to /Applications/Ditto.app
make build      # debug binary only
make clean
swift build     # plain debug compile
```
Manual bundle: `bash Scripts/build-app.sh release`.
Toggle without hotkey (for tests):
```bash
swift -e 'import Foundation; CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("ai.axiotic.ditto.toggle" as CFString), nil, nil, true)'
```
Inspect state:
```bash
cat "~/Library/Application Support/Ditto/history.json"
cat "~/Library/Application Support/Ditto/debug.log"      # if Debug Logging on
defaults read ai.axiotic.ditto                            # historyLimit, soundName, …
```

### File map
```
Package.swift                      executableTarget "Ditto", macOS 13, links AppKit/SwiftUI/Carbon/UTType
Makefile                           build/run/install/clean
Resources/Info.plist               LSUIElement, bundle id ai.axiotic.ditto
Scripts/build-app.sh               assemble + icon + ad‑hoc sign
Scripts/make-icon.swift            gradient + SF Symbol → .iconset → .icns
Sources/Ditto/App/Main.swift       @main entry
Sources/Ditto/App/AppDelegate.swift   conductor: menu, panel, hotkey, keyboard, paste
Sources/Ditto/App/HotKey.swift     Carbon global hotkey
Sources/Ditto/Clipboard/ClipItem.swift     model
Sources/Ditto/Clipboard/ClipStore.swift    history: dedup/pin/trim/persist (@Published)
Sources/Ditto/Clipboard/ClipboardMonitor.swift  poll + classify + App Nap opt‑out
Sources/Ditto/Clipboard/Paster.swift       pasteboard write + ⌘V
Sources/Ditto/UI/FloatingPanel.swift       slide‑up NSPanel + NSHostingView  ← refresh defect
Sources/Ditto/UI/PanelViewModel.swift      bar state + intents
Sources/Ditto/UI/ContentView.swift         bar layout + onChange refresh hooks
Sources/Ditto/UI/ClipCardView.swift        per‑item card
Sources/Ditto/UI/Theme.swift               palette + VisualEffect bg
Sources/Ditto/Support/Feedback.swift       capture sound + debug log
SPEC.md                            this document
README.md                          user‑facing overview
```

### Persistence
- Index: `~/Library/Application Support/Ditto/history.json` (JSON array of ClipItem).
- Image payloads: `~/Library/Application Support/Ditto/<uuid>.png`.
- Settings: UserDefaults domain `ai.axiotic.ditto`
  (`historyLimit` 0=unlimited, `soundEnabled`, `soundName`, `debugLog`).

### Constants worth knowing
- Poll interval **0.4s**, tolerance 0.1, `.common` run‑loop modes.
- Panel height **380**, card **220×250**.
- Hotkey **`⌃⌥⌘V`** = `controlKey|optionKey|cmdKey` + `kVK_ANSI_V`.
- Default history limit **200** (currently overridden to **0 / unlimited**).

### Decisions log (why things are the way they are)
- **Polling, not pasteboard notifications.** macOS has no public pasteboard‑change
  notification; polling `changeCount` is the standard approach (Maccy/Flycut do
  the same). 0.4s balances latency vs. wake‑ups.
- **App Nap opt‑out via activity assertion.** Background accessory apps get
  napped; that froze the poll timer → “only refreshes after restart”. The
  assertion uses `…AllowingIdleSystemSleep` so the Mac can still sleep normally.
- **Carbon hotkey.** Deprecated but the only no‑entitlement system‑wide hotkey
  API that’s reliable.
- **Ad‑hoc code signing.** Chosen for zero‑setup local builds, but it changes the
  app’s code identity on **every rebuild**, so macOS forgets the Accessibility
  grant and re‑prompts. This is the documented cause of “always asking for
  permission.” The durable fix is a stable self‑signed identity (P1) — must be
  user‑approved because it writes to the login keychain.
- **No launch‑time AX prompt.** Removed because it nagged on every launch and
  after every reinstall; now lazy (only when a paste needs it) + a menu item.
- **`@main struct` (not `main.swift`).** Avoids the top‑level‑code vs
  `@MainActor` conflict under SwiftPM.
- **Darwin‑notification toggle.** Lets headless tests/scripts open the bar without
  Accessibility (which synthetic key events require).

### Environment notes for whoever continues
- Build host: macOS 26 (Darwin 25.6), arm64, Swift 5.10, Xcode 15.4.
- `gh` has two accounts; repo lives under **AntreasAntoniou** (switch active
  account to push: `gh auth switch --user AntreasAntoniou`). Commits use
  `antreas@axiotic.ai`.
- The dev session was **headless** — re‑verify anything visual on a real screen.
```
```

---

### One‑paragraph handoff (if you read nothing else)
Ditto is a working native macOS clipboard manager: it reliably **captures** every
copy (text/link/color/image/file) into a persistent, unlimited, pinnable, searchable
history, plays a choosable sound, and summons a slide‑up bar on `⌃⌥⌘V`. The one
unsolved problem is that the **floating bar’s SwiftUI content does not refresh to
reflect the store** — capture and data are proven correct (the model holds the
right items at open time), so the bug is in the `NSHostingView`‑inside‑`NSPanel`
update path; start with **T6 hypothesis 1** (reassign `rootView` / use
`NSHostingController` on each `show()`), and **verify on a real display** because
the original session was headless and never watched the UI render.
