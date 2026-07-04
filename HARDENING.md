# Cliphoard — Hardening Audit

_A 10-persona usability/functionality/intuitiveness audit. Each persona was a distinct user/expert with a hard negative constraint (forced orthogonality); every high-severity finding was adversarially refuted before inclusion. 10 personas · 68 raw findings · 17 confirmed after refutation._

---

# CLIPHOARD HARDENING AUDIT

Synthesis of 10 persona audits + adversarial refutation verdicts. Source root: `/Users/antreas/Projects/ditto/Sources/Cliphoard/`.

Scoring note: each issue ranked by **severity (post-refutation) × confidence × lens-count (independent personas) × adversary-confirmation**. Findings the refuter downgraded are reported at the revised severity, but where multiple independent lenses converged on the same root cause I flag that convergence as a confidence multiplier even when each lens individually rated it lower.

---

## 1. BOTTOM LINE — the 4 things hurting Cliphoard most right now

**1. The silent-paste-without-Accessibility trap is the worst first-run experience in the app.** Four separate personas (margo, tomas, knox, chaos) independently hit the same defect from different angles, and the refuter confirmed every one. `AppDelegate.commit` (lines 209–221) writes the clip to the pasteboard, then calls `hide(paste: AXIsProcessTrusted())`. When untrusted: the bar slides away identically to success, no Cmd-V fires, no HUD/banner/sound, and the one-shot `didPromptAX` (line 21) means after the first dismissed prompt every future Enter is a feedback-free no-op. The single most-advertised action ("↩ Paste", `ContentView.swift:441`) silently does nothing. **This is the #1 fix** — highest cross-lens convergence (4 lenses) at confirmed medium-to-high severity.

**2. "Encrypted at rest" is a partially false trust claim — image clips are plaintext PNGs on disk.** `ClipboardMonitor.persistImage` writes `try png.write(to: url)` plus a `-thumb.png` sidecar as raw PNG, never sealed (`ClipCardView.cachedImage` reads them back with plain `NSImage(contentsOf:)`). README.md (lines 29, 85) and onboarding's "Private by design" card make an uncaveated encryption promise. Screenshotted 1Password vaults, 2FA QR codes, recovery sheets land in the clear. Confirmed at **high**, confidence 0.97. The project's own `STATUS.md:11` already admits "plaintext SQLite + plain PNGs."

**3. Accessibility is broken for VoiceOver users — the core job is unreachable or silently wrong.** Two confirmed high-severity defects compound: clip cards have no `.isButton` trait and no `.accessibilityAction`, so pin/delete are unreachable and paste is only awkwardly reachable via a synthesized tap (`ClipCardView.swift:64–68`); and keyboard selection is a model `Int` decoupled from the VoiceOver cursor (`AppDelegate.swift:161` global NSEvent monitor → `PanelViewModel.selection`), so a VO user can hear card 5 announced while Enter pastes card 1 — a **silent wrong-clip paste**, the worst kind of clipboard bug.

**4. The summon hotkey is a hardcoded 4-finger chord that cannot fail gracefully or be rebound.** `⌃⌥⌘V` is a literal (`AppDelegate.swift:285–289`); Settings shows it as a dead keycap (`SettingsView.swift:91–97`); `HotKey.register` discards `RegisterEventHotKey`'s `OSStatus` (`HotKey.swift:33`). If another tool owns the combo, the app's *single entry point* dies with zero feedback and no recovery. Flagged by two personas (dex, soren). Refuted to medium as a feature-preference, but the **unhandled-failure-on-sole-entry-point** is a real robustness bug regardless of the rebind debate.

---

## 2. FINDINGS BY THEME

### A. Onboarding & discoverability

| # | Problem · Impact · Fix | Severity | Lenses |
|---|---|---|---|
| A1 | **No on-screen cue that clicking a card pastes it.** `ContentView.footer` (438–454) lists only keyboard hints; mouse-paste lives in `PanelViewModel.click` (126–133) as undocumented two-step "click selects, second click on already-selected card pastes." First click glows blue → nothing; second → pastes + dismisses (reads as a misclick). Fix: hover/selection "Click to paste" affordance + footer mouse hint; strongly consider single-click-to-paste. | medium (was critical) | margo, tomas, chaos |
| A2 | **Onboarding never maps the actual bar.** `OnboardingView` (44–83) covers hotkey/privacy/semantic-search/AX only — never the gear (icon-only Settings), chips-as-filters, or how to retrieve a clip. Fix: one labeled tour screenshot ("search here / filter by type / gear = settings / click to paste"); add a "Settings" label/tooltip to the gear. | high | margo |
| A3 | **"Essence search" is meaningless jargon as the default placeholder.** `DeepSearch.mode` defaults to `.essence`, rendering "Essence search" + sparkles (`ContentView.swift:77–80`); Settings explains it as "Essence = full vector similarity" (`SettingsView.swift:161`). Fix: default placeholder "Search your clips"; plain-language mode labels ("Smart — by meaning", "Exact — the words you type", "Tag — by category"). | low (was high) | margo |

### B. Search & keyboard flow

| # | Problem · Impact · Fix | Severity | Lenses |
|---|---|---|---|
| B1 | **Essence (semantic) is the default and reorders away the obvious recent match; no in-bar way to switch modes.** `essence()` ranks by cosine (substring only +1), thresholds 0.12, and returns top ~12 "best guesses" even on no hit (`DeepSearch.swift:318–329`). Mode is changeable only via the gear→Picker; `handleKey` has no mode-cycle case. A dev searching a literal token they *know* they copied can't get deterministic substring without a mouse trip into Settings. Fix: in-bar mode cycle (Tab or ⌘E) shown in footer; prefilter exact substring matches strictly above semantic; consider defaulting Exact for queries < 4 chars; keep choice ephemeral per-summon. | high | dex, tomas, priya |
| B2 | **Arrows are stolen from the search field.** `handleKey` unconditionally routes ←/→ to `moveSelection` (235–273); caret can't move inside the query — typo recovery means Delete-and-retype. Fix: use ↑/↓ for nav; let plain ←/→ fall through to the TextField; never swallow ⌘←/⌥← caret motion. | medium | dex |
| B3 | **No jump/page navigation.** `moveSelection` is ±1 only; no Home/End/PageUp/Down (history up to 5000). Reaching item 40 = 40 keypresses. Fix: Home/End + ⌘↑/⌘↓ to first/last, PageUp/Down by viewport. | medium | dex |
| B4 | **Category chips and Settings are mouse-only.** Chips have no keyboard binding (`categoryChips` 113–133); Settings opens only via gear (no ⌘, binding). Fix: bind ⌘, to toggle Settings (free); ⌃1–7 or query prefixes (`kind:link`) for chips; direct Pinned toggle. | low–medium | dex |
| B5 | **⌘C globally hijacked to "copy selected clip"** even when the search field has a text selection (`handleKey:260`); ⌃C alias is unusual. Fix: only intercept ⌘C when field has no active selection; drop ⌃C. | low | dex |

### C. Native / HIG & panel behavior

| # | Problem · Impact · Fix | Severity | Lenses |
|---|---|---|---|
| C1 | **`NSApp.activate(ignoringOtherApps:true)` defeats the `.nonactivatingPanel`.** `show()` (line 188) force-activates Cliphoard right before `slideIn()`, demoting the host app and stealing the global menu bar — the exact thing `.nonactivatingPanel`+`canBecomeKey=true` was chosen to avoid. All the downstream compensation (re-activate previousApp, 0.12s activate-then-Cmd-V dance, resignKey juggling) exists to paper over this self-inflicted activation. Fix: drop the `activate` call; become key via `makeKeyAndOrderFront` without activating; the paste path then no longer needs to re-activate or wait. **This is soren's root-cause finding and is upstream of C5, F1, and the paste-latency issue.** | high (lone-but-deep) | soren |
| C2 | **Hardcoded `⌃⌥⌘V`, no rebind, no failure handling.** (See Bottom Line #4.) `RegisterEventHotKey`/`InstallEventHandler` return values discarded (`HotKey.swift:22,33`). Fix: key-recorder in Settings (KeyboardShortcuts pkg), persist, re-register live, surface `OSStatus` failure; ship a saner 2-key default. | medium (was high) | dex, soren |
| C3 | **"Automatic" theme won't live-update on system appearance flip.** Presets set a concrete `scheme`; `.system` resolves `effectiveAppearance` once at token-build time with no KVO observer (`Theme.swift:92–94`, `ContentView.swift:46`). Sunset auto-switch / Control-Center toggle leaves a long-lived open bar wrong. Fix: observe `AppleInterfaceThemeChangedNotification` / KVO `effectiveAppearance` → refresh. | high | soren |
| C4 | **⌘1–9 badges are positional, not stable.** Badge `"⌘\(index+1)"` and `quickSelect` both index `model.results`, which re-sorts pinned-first on every add/pin/filter (`ClipCardView.swift:93–97`, `AppDelegate.swift:268–270`). "My password is ⌘3" mispastes after any new copy — dressed as a stable accelerator it isn't. Fix: freeze numbering to unfiltered recency, OR bind ⌘1–9 to pinned clips in pin order (priya's variant), OR make it unmistakably ephemeral. | medium | soren, priya |
| C5 | **resignKey auto-dismiss + own AX prompt strand the user; multi-monitor placement follows mouse not focus.** `onResignKey→hide()` (155–158) fires when the app's *own* `promptAccessibility()` steals key; `slideIn` targets the screen under the mouse; `show()` resets query/kind/selection so an accidental dismiss is a full reset. Fix: suppress onResignKey while a known prompt/System-Settings hand-off is in flight; prefer the focused/host screen; preserve query across same-session re-summon. | medium | soren, ada, chaos |
| C6 | **Non-native About + misleading ⌘Q.** `about()` hand-rolls an NSAlert instead of `orderFrontStandardAboutPanel` (no icon/version); "Quit" carries keyEquivalent 'q' on a click-only menu so ⌘Q only works while the menu is open (`AppDelegate.swift:329–336, 96–147`). Fix: standard About panel; drop the fake 'q' or register a real global Quit. | low | soren |

### D. Accessibility

| # | Problem · Impact · Fix | Severity | Lenses |
|---|---|---|---|
| D1 | **Cards expose no button trait / no VO actions** → VO users can read a clip but cannot pin/delete it and can only awkwardly paste via synthesized tap (`ClipCardView.swift:64–68`). Fix: `.accessibilityAddTraits(.isButton)` + `.accessibilityAction` for activate/pin/delete; apply to `clipRow` too. | high (was critical) | ada |
| D2 | **Keyboard selection decoupled from VO cursor** → silent wrong-clip paste (`AppDelegate.swift:161` monitor → `PanelViewModel.selection`; cards lack `.focusable`/`@AccessibilityFocusState`). Fix: focusable cards keyed by clip id, bidirectional with `model.selection`, route keys through the responder chain. | high (was critical) | ada |
| D3 | **Several text elements fail WCAG AA on themed surfaces.** Literal `.foregroundStyle(.blue)` links (`ClipCardView.swift:143`) compute ~3.84:1 on One Dark #282c34; `.tertiary` ⌘N index / ETA ~2.25–2.62:1; 9pt tag chips ~3.83:1 (not large text). The line-194 comment ("was .tertiary — failed AA") confirms it's a known issue. Fix: per-theme link/de-emphasized tokens ≥4.5:1; contrast check across all presets. | high | ada |
| D4 | **No Dynamic Type.** All fonts hardcoded `.system(size:N)` (body 12, source 11, footer/count 10, tags 9); fixed 220×250 cards, `lineLimit(11)`. Low-vision users cannot enlarge anything. Fix: text styles + `@ScaledMetric` for sizes/paddings. | high | ada |
| D5 | **`accessibilityHint` duplicates `accessibilityValue`** (both `characterCountLabel`, `ClipCardView.swift:66–67`) → VO speaks the count twice, never says the card is actionable. Fix: hint = action ("Double-tap to paste"). Trivial, high confidence (0.95). | medium | ada |
| D6 | **Touch targets < 44pt** (chips ~22pt, 15pt gear, bare play.circle, 9pt tag chips). Fix: `.frame(minWidth:44,minHeight:44)` or expanded `.contentShape`. | medium | ada |
| D7 | **Motion ignores Reduce Motion** (380pt slide 0.28s, selection spring, scroll re-center; no `accessibilityReduceMotion` read). Fix: fade/instant + crossfade + non-animated scrollTo. | medium | ada |
| D8 | **Selected/active state is color-only** for chips and cards (no `.isSelected` trait, no non-color cue). Fix: add trait + checkmark/filled-vs-outline. | medium | ada |

### E. Privacy & trust

| # | Problem · Impact · Fix | Severity | Lenses |
|---|---|---|---|
| E1 | **Image clips stored as plaintext PNGs** contradicting README's encryption claim. (Bottom Line #2.) Fix: AES-GCM seal PNG bytes before write (or BLOB in SQLite); decrypt on read; restrictive POSIX perms on store dir; until then correct README/PRIVACY. | high (conf 0.97) | vera |
| E2 | **The exclusion denylist has no UI.** `excludedBundleIDs` is read at `ClipboardMonitor.swift:71` and never written anywhere in Sources; PRIVACY.md (35–40) tells users they can exclude apps "so Cliphoard never records what you copy from it" — populatable only via `defaults write`. The primary user-facing privacy control is illusory. Fix: a Privacy/Excluded-apps Settings section with an app picker + "exclude the app this clip came from" card action. | high | vera |
| E3 | **At-rest encryption is largely cosmetic in its own threat model.** 256-bit key in login keychain with `kSecAttrAccessibleAfterFirstUnlock`, no `kSecAttrAccessControl`/Secure-Enclave; unsandboxed; key sits beside the ciphertext. Any same-user process reads both. (Not separately refuted, but the substance overlaps E1's confirmed encryption-overclaim.) Fix: bind key with `.userPresence`/Secure Enclave OR stop overselling and document the real model ("on a running logged-in Mac, same-user processes can decrypt; equals FileVault + login keychain"). | high (lone, conf 0.9) | vera |
| E4 | **Plain-copied secrets are captured.** `shouldSkip` only honors denylist + Transient/Concealed/AutoGenerated flags; `cat .env\|pbcopy`, terminals, browser reveal-fields, JWTs land in `capture()` and get indexed/tagged (tag baskets literally include "api key"/"access token"/"password"). Fix: opt-in content heuristics (entropy, `KEY=`/`TOKEN=`, JWT/PEM/AWS shapes), per-clip "never store from this app", concealed marker. | medium (was high) | vera, priya |
| E5 | **Source-app + timestamps stored in cleartext** (`Database.insert`): a per-clip behavioral map (which app, when, how often) survives even when the body is encrypted. Fix: encrypt `source_app` or document it; option to not record it. | medium | vera |
| E6 | **Legacy plaintext survives migration:** `history.migrated.json` kept forever unencrypted; WAL/-shm sidecars not scrubbed by VACUUM; `storeKey` failure → ephemeral key but `dbEncryptedV1` still set → next launch can't decrypt, silently returns ciphertext as "text". Fix: securely delete/encrypt the migrated JSON; `wal_checkpoint(TRUNCATE)` or `VACUUM INTO`; verify `readKey()` round-trips before setting the flag. | medium | vera |
| E7 | **`Crypto.seal` failure silently writes plaintext** into the DB (returns original on any failure, only NSLogs); indistinguishable from legacy rows, so no sweep catches them. Fix: treat seal failure as fatal-for-that-clip or mark a `plaintext-fallback` flag; periodic re-seal sweep. | medium | vera |

### F. Performance

| # | Problem · Impact · Fix | Severity | Lenses |
|---|---|---|---|
| F1 | **Synchronous CoreML embedding on the main actor in the capture path.** `ClipStore.add` runs `ClipIndexer.index(item)` synchronously before insert (`ClipStore.swift:143`) from the @MainActor 0.4s poll; `OgmaEmbedder.run` does tokenize + `model.prediction` inline. Refuter's caveat: ids are capped to 256 tokens so the *inference* is fixed-size, and the tokenizer Viterbi is per-word (≈linear), so the freeze is bounded — but the unbounded HashingEmbedder trigram loop and a single huge whitespace-free token are the real tail risks. **The load-bearing fix is an upfront length cap, not just deferral** (note: `reindexStale` is itself `@MainActor` and does NOT move inference off-main). Fix: cap searchText to a few KB before embed; move ingest indexing into a genuine off-actor task that writes the vector back. | medium (was high) | lin, knox |
| F2 | **Essence search re-embeds the query + scans all items on every keystroke, no debounce.** `onChange(of: model.query)` only calls `resetSelection()`; ResultsKey includes `query` so every keystroke is a cache miss → full synchronous CoreML query embed + cosine scan (`ContentView.swift:86`, `DeepSearch.swift:318`). Only bites when a real ogma model is active (default HashingEmbedder is cheap). Fix: debounce ~120–200ms; run embed/scan off-main; cache last query vector for filter toggles. | high | lin |
| F3 | **Essence embeds un-indexed items inline during the query scan.** `item.embeddings[sig]?.vector ?? embedder.embed(...)` (`DeepSearch.swift:321–322`): mid-reindex or post-model-switch, a search runs N CoreML inferences per keystroke. Fix: treat missing vector as "not indexed" — skip/substring-only, never embed inside the per-keystroke loop. | medium | knox, lin |
| F4 | **Image copy decodes → re-encodes full PNG → generates thumbnail synchronously on main actor** (`persistImage` 130–161); 6K Retina grab = tens of MB of TIFF+bitmap+PNG live at once. Fix: move encode+thumbnail to background; placeholder then swap; encode thumb from source CGImage not the just-written PNG. | medium | lin |
| F5 | **App Nap disabled for entire process lifetime** + 0.4s timer 24/7 (`ClipboardMonitor.swift:21–39`); persistent laptop battery drain. Fix: NSPasteboard observation / back off on battery / scope `beginActivity` to actual work. | medium | lin |
| F6 | **Per-body O(n) `counts()` + per-card `tagNames()` + `fileExists` stat on every render** (`ContentView.swift:121,382–392`). Stacks with F2 on the keystroke path. Fix: cache counts as derived published value; memoize tag names with the results cache; cache thumbnail-exists. | low | lin |
| F7 | **Unbounded image cache + full-res Spotlight preview decode** (`ClipCardView.swift:19,31`; `ContentView.swift:352–356` `NSImage(contentsOf:)` no downsample). Fix: set `countLimit`/`totalCostLimit` with pixel-area cost; use thumbnail in preview unless zoomed. | low | knox |

### G. Robustness / edge-cases

| # | Problem · Impact · Fix | Severity | Lenses |
|---|---|---|---|
| G1 | **Image dedup never fires** — signature is `"img:"+payloadFile` where payloadFile is a fresh UUID per capture (`ClipItem.swift:155–162`, `ClipboardMonitor.swift:134`), so identical images never match and `persistImage` writes a new full-res PNG each time. With default historyLimit 200, dupes evict genuine text clips. Fix: hash PNG/TIFF bytes (SHA256) for both signature and filename; skip write if file exists. | high (conf 0.93) | knox |
| G2 | **Incoming copy hijacks selection while the bar is open** → Enter/⌘⌫ act on the wrong clip. `onChange(of: store.lastAddedID)` forces `model.selection = idx` of the new clip; commit/delete read `r[selection]` by index (`PanelViewModel.swift:135–152`, `ContentView.swift:195–199`). Silent wrong-paste / wrong-delete. Fix: only auto-move when the user hasn't navigated since summon; track selection by clip id, not index. | medium | knox, chaos |
| G3 | **Reindex/reclassify keeps indexing items deleted mid-pass** → FK-violation log spam + wrong progress denominator (`ClipStore.swift:252–318`). Cosmetic. Fix: `guard items.contains` before indexing; recompute total against live items. | low | knox |
| G4 | **Whitespace-trivial re-copies create duplicates** (`signature = "text:"+text`, exact match) → noise crowds out the genuinely-older clip at the 200 limit. Fix: optional normalized dedup key (trim trailing whitespace), keep raw text for paste fidelity. | medium | priya |

### H. Defaults & friction

| # | Problem · Impact · Fix | Severity | Lenses |
|---|---|---|---|
| H1 | **`~0.32s` baked-in paste latency loses to raw Cmd-V on every repeat.** Paste fires only in `slideOut`'s completion handler (0.2s anim) then `asyncAfter(0.12s)` before synthetic Cmd-V (`Paster.swift:37–43`, `FloatingPanel.swift:92`). Structurally slower than the system clipboard on the hot path. **Root cause is shared with C1** (the re-activate exists only because show() force-activated). Fix: write pasteboard + fire Cmd-V immediately on commit, animate out concurrently; replace the 0.12s sleep with `didActivateApplicationNotification` (or skip re-activate when target is already frontmost). | medium (was high) | priya, dex |
| H2 | **"Clear Unpinned History" wipes everything with no confirmation, no undo** (`AppDelegate.swift:299`, `SettingsView.swift:225`; menu item sits next to "Welcome"/"About"). `role:.destructive` only tints red. Fix: NSAlert confirm ("Delete N clips? Can't be undone") from both entry points; bonus ~10s undo window. | low (was high) | chaos |
| H3 | **⌘⌫ deletes with no confirm/undo** (`deleteSelection` 147–152, removes payload+row immediately); compounded by G2's selection-steal. Fix: toast-with-Undo; suppress selection-jump in the window after a delete intent. | medium | chaos |
| H4 | **Code/paths/URLs render in proportional font** (`.system(size:12)`; monospace only for hex caption) → shell commands and diffs are mushy and hard to verify before pasting into a prod shell. Fix: monospace when content looks like code/path/URL (cheap heuristic). | medium | priya |
| H5 | **Long clips silently truncated with no full-payload peek in the default layout** (`lineLimit(11)`; scrollable preview exists only in Spotlight layout). Pasting partially blind into destructive shells. Fix: Space/⌘Y peek popover in every layout with char/line count. | medium | priya |
| H6 | **Settings overloaded; two overlapping search knobs.** 8 sections; Search exposes Mode (Exact/Tag/Essence) AND Embedding model (Off/Low/Normal) that silently interact. Fix: collapse to one "Search: Fast/Smart" choice deriving the model; move Tags/Debug behind "Advanced"; trim default theme list. | medium | tomas |
| H7 | **Mode change silently flips on the embedding model and kicks a full reindex**, shown only in a thin bar outside the Settings sheet; the force-changed model picker is then `.disabled` and unreadable (`SettingsView.swift:140–163`, `AppSettings:18–31`). Fix: surface "Essence needs a model — loading, re-indexing N clips" in Settings; keep the picker readable. | low | chaos |
| H8 | **Permissions section nags** with a self-relaunch button + "still showing? macOS applies it on relaunch" caveat (`SettingsView.swift:243–250`). Reads as the app blaming the OS. Fix: re-check on app-activation (already wired) and auto-refresh silently. | low | tomas |
| H9 | **Category chips appear/disappear by content** (rendered only if count > 0, 113–133) → unlearnable, unstable taxonomy; no tooltips. Fix: show fixed chip set always, dim empties; add tooltips ("Pinned = clips you've kept"). | medium | margo |
| H10 | **Footer crams 7 tiny low-contrast hints** (size 10, secondary/tertiary) — it's the *only* tutorial yet the least readable element. Fix: show 2–3 core actions by default, reveal rest on held ⌘ or "?"; enlarge keycaps. | medium | margo, tomas |

---

## 3. EXPERT ASSIGNMENTS — build plan by owning role

**macOS / AppKit engineer** (heaviest load — owns the structural root causes)
- C1 drop `NSApp.activate(ignoringOtherApps:)` from `show()` — *do this first; it unlocks H1 and simplifies C5.*
- H1 decouple paste from slide-out animation; event-driven activation wait.
- E1 encrypt image PNGs (with security engineer).
- E2 build the Excluded-apps Settings UI + card action.
- D2 focusable cards + `@AccessibilityFocusState`, route keys through responder chain (with a11y specialist).
- G1 hash image bytes for signature+filename.
- C2/C3 hotkey re-register + appearance KVO observer; surface `OSStatus`.
- C5 suppress onResignKey during own prompts; focus-screen placement.
- F1/F4/F5 off-actor embedding + image encode + App-Nap scoping.
- B2/B3/B4/B5 keyboard routing fixes; C6 native About.

**Interaction designer**
- A1 click-to-paste affordance (lead the single-vs-double-click decision).
- A2 onboarding bar tour.
- B1 in-bar mode cycle + footer indicator.
- C4 ⌘1–9 stable-numbering decision.
- G2/H3 selection-by-id + delete undo UX.
- H6 Settings IA collapse; H9 stable chips; H10 footer redesign; D6 hit targets.

**Accessibility specialist**
- D1 button trait + named VO actions (cards + clipRow).
- D3 per-theme contrast tokens + audit across presets.
- D5 fix hint/value duplication (quick win).
- D4 Dynamic Type / `@ScaledMetric`; D7 Reduce Motion; D8 non-color selected cues.

**Performance engineer**
- F1 upfront length cap (the actual fix) + genuine off-main embed.
- F2 debounce + off-main query embed + last-query-vector cache.
- F3 stop embed-on-read in essence; F6/F7 caching + cache limits.

**Security engineer**
- E1 AES-GCM for images (with AppKit eng); E3 key access-control / honest threat-model doc.
- E4 content-heuristic secret skipping; E5 encrypt source_app; E6 migration cleanup; E7 seal-failure handling.

**UX writer**
- A3 plain placeholder + mode descriptions; H7 model-load messaging; H8 permissions copy; H10 hint wording; correct README/PRIVACY encryption claims (with security eng).

**QA engineer**
- G3 reindex-vs-delete guard.
- Build regression tests for the AX-untrusted paste path (#1), image dedup (G1), and the selection-steal race (G2) — the three "silent wrong outcome" bugs that need automated coverage.

---

## 4. SEQUENCED HARDENING ROADMAP

**Phase 0 — Stop the silent failures (ship first; these are correctness/trust, not polish)**
1. **AX-untrusted paste feedback** — inline banner/HUD "Copied — press ⌘V"; stop gating on one-shot `didPromptAX`. (Bottom Line #1; margo/tomas/knox/chaos.)
2. **Image encryption OR honest docs** — at minimum correct README/PRIVACY today; encrypt PNGs next. (E1; trust claim is currently false.)
3. **G1 image dedup + G2 selection-by-id** — both cause silent wrong/duplicated data; cheap and high-value.
4. **H2/H3 destructive-action confirmation + undo** — guard against irreversible bulk/single delete.

**Phase 1 — Structural macOS correctness**
5. **C1 drop force-activate** — root cause; then **H1 paste latency** falls out almost for free.
6. **D1 + D2 VoiceOver actions + focus binding** — make the core job reachable for AT users.
7. **C2 hotkey failure detection** (+ rebind UI) — protect the sole entry point.

**Phase 2 — Trust & defaults**
8. **E2 exclusion-list UI** (makes a documented promise real); **E3** threat-model honesty; **E4–E7** secret handling + migration cleanup.
9. **B1 search defaults** — exact-substring prefilter + in-bar mode cycle.
10. **A1/A2/A3/H9/H10** discoverability + onboarding + plain copy.

**Phase 3 — Performance & a11y depth**
11. **F1/F2/F3** off-main + debounce + length cap (only urgent once a real ogma model ships by default).
12. **D3/D4/D7** contrast, Dynamic Type, Reduce Motion; **C3** appearance KVO; **F4–F7** image/render caching.

---

## 5. NOTABLE DISSENTS & WHAT NEEDS THE HUMAN

- **Refuter vs. personas on severity (preserve the dissent, don't average it):** the refuter systematically downgraded UX-writing/discoverability findings (A1 critical→medium, A3 high→low, H2 high→low, H1 high→medium). I report the revised severities, **but** A1 and the AX-paste cluster were each independently surfaced by 3–4 personas — that cross-lens convergence is a real signal the single-finding refutation didn't weigh. **Human call:** whether "4 personas hit the same wall" should override a per-finding "recoverable, so medium" verdict. I lean yes for prioritization.

- **C1 (force-activate) is a lone but high-conviction finding (soren only, conf 0.83).** No other persona named it, yet it is the *upstream cause* of the paste-latency tail, the re-activation dance, and part of the resignKey fragility. Preserved at high. **Human verification needed:** dropping `NSApp.activate` must be tested to confirm the search field still gets first responder and Cmd-V still lands in the host app — soren asserts it will, but this is the one change that could regress focus if wrong.

- **E3 (cosmetic encryption) is also effectively lone (vera, conf 0.9)** and wasn't in the confirmed set, yet it's the strongest version of the trust critique. **Human decision:** product/marketing call — either harden the key (Secure Enclave / `.userPresence`, with UX cost) or rewrite the security claims to be modest. This is a positioning decision, not purely engineering.

- **B1 / default search mode** has genuine tension between personas: margo wants "just type and find it" (Exact-leaning), dex/priya want deterministic substring, while the product clearly bet on Essence as "the headline experience" (`DeepSearch.swift:73`). **Human call:** keep Essence as the brand default with an exact-substring prefilter, or flip the default to Exact. All personas agree the *current* behavior (semantic-only reorder with a top-12 fallback on no match) is wrong.

- **F1/F2 severity hinges on a shipping decision:** both only bite hard once a real ogma CoreML model is the default (today's HashingEmbedder fallback is cheap). **Human input:** if you intend to bundle ogma-small as default, these jump back to high and must lead Phase 3; if the hashing fallback stays default, they're deferrable.