# Ditto — Design Bake-off

A 20-agent creative team designed **10 themes** (color/material) and **10 layouts** (structure) as HTML mockups of the bar, all showing the same six sample clips. Headless Chrome rendered them; a 5-lens visual-QA committee (brand, legibility, task-speed, native-craft, density) judged them in isolation, an adversary stress-tested the front-runners, and the result was synthesized below.

**View the mockups:** source HTML in `design/mockups/html/` (open any in a browser); contact sheets `design/themes-sheet.png` and `design/designs-sheet.png`. Re-render with headless Chrome at the width/height in `design/mockups/manifest.json`.

---

# Ditto Clipboard Bar — Final Integrated Recommendation

## How I weighted this
Five independent lenses: **brand/emotion** (Vesna), **legibility/contrast** (Okwe), **task-speed** (Lin), **native-craft** (Soderberg), **density/scale** (Ravi). I counted how many lenses backed each option, then folded in the adversary stress-tests — which hit the front-runners hard, especially on the contrast-vs-mood fault line. Dissent is preserved, not averaged away.

---

## (1) THEMES — ranked

1. **swiss-grayscale** — *Verdict: the consensus daily driver — 3 lenses (legibility, speed, density) put it top-3; only loses points on warmth and the red double-use.* **← COUNCIL PICK**
2. **midnight-glass** — *Verdict: wins the half-second "premium Mac" impression (brand + native craft), but the adversary lands a fatal low-contrast-metadata blow that swiss avoids.*
3. **paper-ink** — *Verdict: quiet, unanimous-adjacent — top-3 for both legibility and density, near-black ink on warm paper reads crisply with zero stress-test exposure.*
4. **arctic-nord** — *Verdict: the safest native pick — HIG-correct muted material (craft) plus low-chroma calm at scale (density), no lens hated it.*
5. **high-contrast-accessible** — *Verdict: the polarizer — #1 for legibility AND speed, but actively hated by brand, craft, and density (oversized type clips the email body). Belongs as an a11y mode, not the default.*
6. **forest-calm** — *Verdict: brand loves the restful sage, but speed says it washes metadata into "near-illegible gray mud." Mood-first, scan-hostile.*
7. **sunset-warmth** — *Verdict: cozy golden-hour warmth (brand + craft like it) undone by a major adversary flaw — warm-on-warm collapses state signaling and ignores macOS Light/Dark.*
8. **brutalist-mono** — *Verdict: speed likes the hard cell borders, but brand and craft call it abrasive web brutalism; single-lens niche at best.*
9. **solarized** — *Verdict: only mentioned to be avoided (legibility): muted base pushes metadata to borderline-failing AA.*
10. **synthwave** — *Verdict: avoided by two lenses (legibility, density): glow ≠ contrast, and per-cell magenta swamps content at 248 clips. Bottom.*

---

## (2) DESIGNS — ranked

1. **spotlight-palette** — *Verdict: broadest backing — top-3 across brand, legibility, speed, AND native-craft (4 lenses). The adversary flaw (wasteful preview pane, ambiguous selection) is real but fixable.* **← COUNCIL PICK**
2. **compact-list-rows** — *Verdict: the density/speed workhorse — top-3 for legibility, speed, native-craft, and density (4 lenses), and the only front-runner the adversary says SURVIVES daily use. "Compact" is a misnomer to fix (3-line rows → 1 line).*
3. **spotlight-rail** — *Verdict: legibility's and craft's favorite — the most convincingly Mac-native structure (Raycast DNA, ⌘ glyphs, syntax-highlighted detail). Not stress-tested = lower exposure.*
4. **ditto-plainline** — *Verdict: pure density (speed + density top-3), but brand calls it "unfinished/generic" and legibility flags low-contrast metadata columns. The functional minimalist.*
5. **timeline-spine** — *Verdict: brand-only love (calm narrative rhythm); no other lens scored it. Charming, unproven on speed/density.*
6. **ditto-dashboard** — *Verdict: density's clever pick — the ONLY layout that designs for overflow ("213 more in history"). But brand calls it joyless enterprise admin. Strong dissent both ways.*
7. **coverflow-carousel** — *Verdict: brand finds it cinematic and delightful — but legibility, speed, craft, AND density all call it disqualifying (one legible card; catastrophic at 248). 1 lens loves it, 4 condemn it.*
8. **polaroid-grid** — *Verdict: avoided by speed, craft, and density — tilted taped photos, ~8 clips/screen, a "craft-fair gimmick." Bottom.*

(Masonry mentioned only in passing by density as a space-waster; unranked for lack of coverage.)

---

## (3) Single best overall

- **Best THEME: swiss-grayscale.** Three orthogonal lenses (legibility, speed, density) independently put it top-3 — the only theme with that breadth among the "serious" options — and it has no fatal adversary verdict (its flaw is the fixable red double-duty, not a contrast failure). It is the theme that survives the all-day, hundreds-of-clips loop.
- **Best DESIGN: spotlight-palette.** Backed by four of five lenses (brand, legibility, speed, craft) — the widest cross-lens support in the whole bake-off. Its adversary flaws (empty preview pane for short clips, faint selection) are layout-tuning fixes, not metaphor failures like coverflow/polaroid.

---

## (4) SHORTLIST to implement in SwiftUI

**Themes (Theme-preset picker, 3 presets):**

| Preset | Why | Effort / Risk |
|---|---|---|
| **swiss-grayscale** (default) | Council pick; survives daily use; broad lens support | **Low.** Grayscale + one accent. Risk: red is overloaded for pinned AND selected — split these (e.g. blue/accent ring for selection, red reserved for pinned) to defuse the adversary's "warning signal" critique. |
| **midnight-glass** | Owns the premium first-impression; native `.ultraThinMaterial` vibrancy | **Medium.** Real SwiftUI `Material` + glow. Risk: MUST raise metadata/footer contrast to ≥4.5:1 or it fails daily use per adversary. Don't ship the low-contrast footer. |
| **high-contrast-accessible** | a11y mode, not default; #1 legibility+speed | **Low.** Hook to macOS *Increase Contrast*. Risk: low — but keep type sane so it doesn't clip body text. |

(paper-ink is the natural 4th if a "light/warm" preset is wanted — zero stress-test exposure, near-unanimous among serious lenses.)

**Designs (layout option, 1 primary + 1 alt):**

| Layout | Why | Effort / Risk |
|---|---|---|
| **spotlight-palette** (primary) | Best overall; 4-lens support; keyboard-first find-then-paste | **Medium.** Search + results + preview split. **Must-fix from adversary:** make selection a strong focus ring/checkmark (not faint fill), bind preview to the selected row, collapse/narrow the preview for short-text clips so the list isn't starved to ~8 rows, and add truncation indicators. |
| **compact-list-rows** (alt / dense mode) | Only front-runner that survives daily use; density+speed champion | **Low–Medium.** Single-column rows. **Must-fix:** make it actually compact (1 line, not 3), add zebra/separators so right-aligned metadata can't be misread, and a visible selection ring + ellipsis on truncation. |

This gives the product owner a premium-feeling palette layout on a legible default theme, with a dense list as the power-user alternative and a built-in a11y theme.

---

## (5) Notable dissents (preserved, not averaged)

- **high-contrast-accessible is the great splitter.** #1 for BOTH legibility and speed (Okwe, Lin) yet explicitly *avoided* by brand, native-craft, and density. It is right for an accessibility mode and wrong for a default — ship it as a toggle, not the face of the product.
- **coverflow-carousel: 1 lens adores it, 4 condemn it.** Brand calls it "cinematic and delightful"; legibility, speed, craft, and density all call it disqualifying. The delight is real but it cannot be the primary layout — at most an optional "browse" flourish.
- **ditto-dashboard: lone density champion.** The only design that answers "what happens past the visible set" ("213 more in history" + per-kind counts) — a genuinely important capability brand dismisses as "joyless." Steal its overflow affordance even if you don't ship its chrome.
- **midnight-glass vs. swiss-grayscale is the bake-off's core tension.** Brand + craft crown the glass; legibility + speed + density + the adversary crown grayscale. I broke it for swiss on daily-survivability — but midnight-glass earns the #2 preset *only if* its metadata contrast is fixed.
- **timeline-spine** got real love from exactly one lens (brand) and silence from the rest — promising but unvalidated; not shortlist-ready without speed/density evidence.