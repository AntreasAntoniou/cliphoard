# Cliphoard — "Best of Both" Tagging + Per-Clip Supercard

**Date:** 2026-08-04 · **Branch:** `rename/cliphoard` · **Status:** design (approved, pre-plan)

## 1. Problem

The current organization scheme — a 10×10 facet cube (`TagBaskets.general`) classified
by `TagSpace.classifyDimensions` — feels *less relevant* than the earlier flat "baskets"
did. The cause is mechanical, not cosmetic:

- `classifyDimensions` (`Sources/Cliphoard/Search/DeepSearch.swift:455`) is a plain
  **argmax per dimension with no confidence threshold**. On the default cube, **every clip
  gets exactly 10 tags — one per axis — no matter how weak the match.** Most are noise.
- The vocabulary (Salience, Structure, Temporal span, Action, Source, Language…) is
  generic/academic and doesn't match how the user actually thinks about clips.
- Tags barely affect search: in `smart` mode they contribute only a bounded **+0.20**
  boost (`DeepSearch.swift:617`); facets *filter* but never *rank*.
- There is **no per-clip detail view** and **no way to add your own tags**. The card shows
  only 2 tags + a "+N" chip (`ClipCardView.swift:174`); tap = paste; context menu =
  Paste/Pin/Delete. Custom tags have no home in the data model at all.

## 2. Goals

Recover baskets' relevance without losing the cube's structure, and add user agency:

1. **Only real tags show.** A clip carries the 0–N tags that actually apply, not a forced 10.
2. **Curated, meaningful vocabulary** — plus a library of **10 specialized baskets** the
   user can add and switch between, each tuned to a workflow.
3. **Custom tags** you add per clip, first-class in search and filtering.
4. **A per-clip supercard** — expand any clip into a detail inspector with full content,
   metadata, the full tag set, and a custom-tag editor.
5. **On-point search** — custom tags rank strongly; auto-tags contribute meaningfully.

Non-goals (YAGNI): *learned axis/topical vocabulary* (the shipped axes never self-modify);
per-dimension thresholds (start global); a separate detail *window* (use an inspector);
re-embedding on vocabulary change (re-tag from cached vectors instead). **In scope** and
distinct from the above: an opt-in, suggestion-only **custom-tag learning** loop (§5.1) —
it suggests *your* tags, it never edits the axis vocabulary.

## 3. The three-layer tag model

Every clip is described by up to three layers. All auto-assignment is **confidence-gated**.

| Layer | Shape | Assignment | Example |
|---|---|---|---|
| **Axes** | 4 structured dimensions | argmax per axis, kept only if cosine ≥ τ (else the axis is blank) | `code` · `software` · `reuse` |
| **Topical** | one flat curated pool | nearest-few (top-K ≤ 3) kept only if cosine ≥ τ | `swift` · `regex` |
| **Yours** | user custom tags | typed by the user; never auto | `#client-acme` |

### 3.1 Confidence gate (τ)

- One **global** cosine floor `τ` (a `Double`), default provisional **0.28** — *to be
  calibrated*, see §9.
- `classifyDimensions` becomes: for each dimension slice, take the argmax tag **only if**
  its cosine ≥ τ; otherwise the dimension contributes nothing.
- `classify` (flat/topical) becomes: return the top-K ids **filtered** to cosine ≥ τ
  (currently it returns top-K unconditionally).
- τ is surfaced in Settings with a **live "avg tags/clip" readout** computed over the
  current store, so it can be dialed against real data rather than guessed.

### 3.2 Extending `TagBasket` to carry both axes and a topical pool

Today a `TagBasket` is *either* dimensional *or* flat (`Sources/Cliphoard/Search/TagBaskets.swift:25`).
The hybrid needs both in one basket. Extension:

- Add `var topical: [String]` to `TagBasket` (default `[]`, Codable-resilient like
  `dimensions`).
- The flat `tags` view becomes `dimensions.flatMap(\.tags) + topical` — a single
  contiguous id space: **axis ids first** (fixed-width slices, unchanged
  `range(ofDimension:)`), **topical ids appended** as the tail range.
- New `var topicalRange: Range<Int>` = `[dimensions.count * dimensionSize ..< tags.count]`.
- `ClipIndexer.tags(for:embedder:)` (`DeepSearch.swift:500`) runs **both** classifiers and
  merges the id lists: thresholded `classifyDimensions` over the axis prefix +
  thresholded `classify(topK: 3)` restricted to `topicalRange`.
- **Invariant:** every dimension in a basket holds the same number of tags
  (`dimensionSize`). All baskets in this spec use **`dimensionSize = 8`**.
- `fingerprint` already hashes `tags`, so adding `topical` changes the fingerprint and
  triggers a cheap re-tag from cached vectors — no re-embedding (per the code's own note
  at `TagBaskets.swift:23`).

### 3.3 Basket composition — General baseline + specialized overlay

A clip is never tagged by a single specialized basket in isolation. **General is always
on** and supplies the baseline axes; the user optionally selects **one specialized
overlay** (Developer, Finance, …) that layers its axes + topical on top.

- Implemented as a derived **composed basket** built on the fly:
  `composed.tags = General.tags + overlay.tags` — General's axis ids first, then General
  topical, then the overlay's axes, then overlay topical: one contiguous id space. With
  no overlay selected, the composed basket **is** General.
- Thresholded `classifyDimensions` runs over *all* axis slices from both baskets; the
  thresholded topical classifier runs over *both* topical ranges, merged.
- `ModelEmbedding.tags` stays a single `[Int]` indexing the composed flat view. The
  composition is deterministic from `(generalID, overlayID)` and its `fingerprint` folds
  in both, so switching the overlay changes the fingerprint → cheap re-tag from cached
  vectors (no re-embed).
- **State:** `TagBaskets.overlayID: String?` replaces the single `activeID` (General is
  implicit, always present); `TagBaskets.composed` returns the derived basket.

## 4. The basket library

`TagBaskets.builtIn` grows from `[general]` to **`[general] + the 10 specialized baskets`**;
the editable flat `custom` basket stays. **General is always on** as the baseline; the
picker lets the user add specialized baskets to a roster and choose **one optional overlay**
(`overlayID`, or none) from it — see §3.3. Switching the overlay re-tags from cached
vectors (fast).

All axis vocabularies are 8 tags (id-slice width). Topical pools are ~16 words.

### 4.0 General (default, hybrid) — `id: general`

- **Content type:** text, code, link, command, image, file, document, number
- **Domain:** software, web, business, finance, personal, academic, design, admin
- **Intent:** reuse, reference, share, task, read-later, edit, login, cite
- **Sensitivity:** public, internal, personal-info, confidential, credential, financial, pii, ephemeral
- **Topical:** url, email, phone, address, path, date, amount, name, quote, command, color, id, password, note, link, code

### 4.1 Developer — `id: dev`

- **Artifact:** code, config, command, log, error, snippet, diff, schema
- **Language:** python, javascript, swift, shell, sql, markup, rust, go
- **Intent:** reuse, debug, reference, share, edit, run, cite, archive
- **Sensitivity:** public, internal, credential, token, api-key, pii, confidential, ephemeral
- **Topical:** git, regex, docker, kubernetes, api, endpoint, stacktrace, dependency, env-var, path, uuid, url, json, yaml, test, build

### 4.2 Writer / Content — `id: writer`

- **Form:** draft, quote, note, outline, headline, paragraph, list, revision
- **Domain:** fiction, essay, blog, script, academic, marketing, personal, journalism
- **Intent:** edit, cite, publish, reference, reuse, share, read-later, archive
- **Tone:** formal, casual, persuasive, technical, humorous, neutral, urgent, draft
- **Topical:** title, intro, conclusion, citation, epigraph, dialogue, metaphor, hook, cta, byline, footnote, excerpt, summary, tagline, pullquote, caption

### 4.3 Designer — `id: design`

- **Asset:** color, font, spec, asset-link, measurement, icon, gradient, shadow
- **Domain:** ui, brand, print, web, motion, product, illustration, type
- **Intent:** reuse, reference, share, edit, apply, cite, archive, sample
- **Source:** figma, sketch, photoshop, illustrator, browser, canva, code, notes
- **Topical:** hex, rgba, hsl, px, rem, spacing, radius, opacity, css, tailwind, breakpoint, grid, palette, token, kerning, leading

### 4.4 Researcher / Academic — `id: research`

- **Content:** citation, quote, data, note, abstract, figure, definition, hypothesis
- **Field:** cs, ml, biology, physics, medicine, social, humanities, math
- **Intent:** cite, read-later, annotate, reference, reuse, share, verify, archive
- **Source:** paper, book, preprint, dataset, web, slides, email, notes
- **Topical:** doi, bibtex, arxiv, citation, dataset, equation, p-value, methodology, abstract, reference, corpus, benchmark, hypothesis, figure, table, appendix

### 4.5 Finance / Business — `id: finance`

- **Doc:** invoice, figure, contract, email, receipt, statement, quote, report
- **Sensitivity:** public, internal, financial, pii, confidential, credential, legal, ephemeral
- **Intent:** reference, reuse, share, cite, submit, reconcile, archive, edit
- **Party:** client, vendor, internal, bank, tax, partner, investor, personal
- **Topical:** amount, iban, invoice, tax, vat, currency, account, balance, deadline, po-number, quote, budget, expense, revenue, contract, terms

### 4.6 Personal / Life — `id: personal`

- **Category:** contact, address, credential, note, link, booking, id, reminder
- **Sensitivity:** public, personal-info, pii, credential, health, financial, private, ephemeral
- **Intent:** reuse, reference, share, login, schedule, read-later, save, archive
- **Recurrence:** momentary, today, this-week, recurring, evergreen, scheduled, expired, undated
- **Topical:** phone, email, address, otp, password, booking, tracking, wifi, appointment, birthday, gift-idea, recipe, url, code, pin, membership

### 4.7 Marketing / Social — `id: marketing`

- **Channel:** post, ad, email, dm, story, thread, newsletter, landing
- **Asset:** copy, headline, cta, hashtag, link, caption, subject, bio
- **Intent:** publish, schedule, reuse, reference, edit, share, test, archive
- **Audience:** broad, niche, customer, lead, internal, press, community, personal
- **Topical:** hashtag, cta, utm, caption, headline, subject-line, emoji, mention, link, tagline, hook, offer, promo-code, handle, bio, thread

### 4.8 Data / Analyst — `id: data`

- **Structure:** table, json, csv, query, chart, schema, key-value, blob
- **Domain:** sales, product, finance, ops, marketing, research, engineering, hr
- **Intent:** reuse, reference, analyze, share, cite, transform, archive, verify
- **Sensitivity:** public, internal, pii, confidential, financial, aggregated, raw, ephemeral
- **Topical:** sql, csv, json, schema, query, column, join, aggregate, dashboard, metric, kpi, pivot, dataset, api, endpoint, regex

### 4.9 DevOps / Sysadmin — `id: devops`

- **Artifact:** command, config, log, secret, script, manifest, endpoint, path
- **Environment:** prod, staging, dev, local, ci, cloud, on-prem, test
- **Intent:** run, debug, reference, reuse, deploy, monitor, archive, share
- **Sensitivity:** public, internal, credential, token, ssh-key, secret, pii, ephemeral
- **Topical:** ssh, kubernetes, docker, ip, port, env-var, path, dns, cert, systemd, cron, terraform, ansible, endpoint, hostname, namespace

### 4.10 Legal / Admin — `id: legal`

- **Doc:** clause, id, reference, date, form, letter, notice, statement
- **Sensitivity:** public, confidential, legal, pii, privileged, financial, personal, ephemeral
- **Intent:** reference, cite, submit, sign, reuse, share, file, archive
- **Party:** client, court, counterparty, self, agency, employer, vendor, personal
- **Topical:** case-no, statute, clause, date, deadline, signature, reference-no, ni-number, passport, address, jurisdiction, party, exhibit, form, notice, docket

## 5. Custom tags — data model & persistence

User tags are content the user owns; they must survive model swaps and re-embeds (which
regenerate the per-model `embeddings` rows). So they live on the clip, not the embedding.

- **`ClipItem`** (`Sources/Cliphoard/Clipboard/ClipItem.swift:43`): add
  `var userTags: [String] = []` (Codable; normalized lowercase, trimmed, de-duped, order
  preserved).
- **`clips` table** (`Sources/Cliphoard/Clipboard/Database.swift:26`): add a new
  **`user_tags TEXT`** column. Additive migration: `ALTER TABLE clips ADD COLUMN
  user_tags TEXT` guarded by a column-exists check; existing rows read as `[]`.
- **Encryption at rest:** serialize as a joined string and seal with **`Crypto.sealStrict`**
  (fail-closed, `enc1:`-marked), consistent with the 2026-07-24 launch-QA hardening. A row
  whose `user_tags` cannot be sealed refuses to persist the tag change (never writes
  plaintext), mirroring `insert`/`upsertEmbedding`.
- Read path: decrypt via `Crypto.open`; a legacy/plaintext value passes through (migration
  resilience), then is re-sealed on next write.
- **In-memory tag index:** `ClipStore` maintains a `userTagIndex: [String: [ClipItem]]`
  alongside the existing `tagIndex`, kept in sync on insert/update/delete, powering O(1)
  filter-by-user-tag and autocomplete (distinct-tag enumeration).

### 5.1 Custom-tag learning (opt-in suggestions)

Your tags never auto-apply — but once you've used one enough, Cliphoard **suggests** it on
similar future clips (accept/dismiss), so your vocabulary grows from use. This is the
light, opt-in form of the adaptive idea; the axis vocabulary stays fixed.

- **Signal (no model training, no new persisted vectors for v1):** for each user tag
  applied to ≥ `minApplies` clips (default **4**), compute a **centroid** = mean of the
  active-model vectors of the clips carrying it (all available from `userTagIndex` + the
  `embeddings` cache).
- **Suggest:** on a given clip, for each eligible tag not already on it, if
  `cosine(clip.vector, centroid) ≥ σ_suggest` (default **0.45**, separate from τ), surface
  it in the supercard's **Suggested** row. Rank by cosine, cap at 3.
- **Accept** → a normal `userTags` write (§5). **Dismiss** → persist a `(tag, clipID)`
  pair in a small **`user_tag_dismissals`** table so it isn't re-suggested for that clip.
- **Settings:** a global toggle (**default on**). Entirely mechanical — a handful of
  cosines per opened clip; centroids recompute incrementally as tags are applied.

## 6. Search & ranking

- **`smart`** (`DeepSearch.swift:601`, default) gains a **user-tag term**:
  `score = (exact ? 10 : 0) + neural + autoTagBoost + userTagBoost`, where
  `userTagBoost = (queryMatchesAUserTag ? 3.0 : 0)` — a strong signal well above the
  auto-tag ceiling (+0.20). "Matches" = the normalized query token equals a user tag, or
  the query's nearest topical/axis tag id set intersects the clip's user tags by name.
- **Filtering:** `store.items(matchingFacets:)` (`ClipStore.swift:223`) extends to union
  user-tag buckets, so user tags act as facet chips. A dedicated "Your tags" facet group
  is added to the filter UI (`ContentView.swift:723`).
- **`.tag` mode** and `nearestTag` also consider user tags as candidate targets.
- Auto-tag boost is retained as-is (bounded); the relevance win comes from thresholding
  (less noise in the shared-tag set) + the strong user-tag term.

## 7. Supercard — per-clip detail inspector

A new SwiftUI view, `ClipDetailView`, presented as a **right-side inspector / sheet**
(not a new window).

- **Triggers** (tap stays = paste, unchanged):
  - An **expand chevron** button on `ClipCardView` (revealed on hover / always for the
    selected card).
  - A **keyboard shortcut** on the selected card (proposed: `→` / `⌘↩`).
  - **Clicking the "+N" overflow chip** opens the inspector scrolled to the tag section.
- **Contents:**
  1. **Full content** — scrollable; RTF rendered when present, else text; image/color
     preview for those kinds.
  2. **Metadata** — kind, source app, created, last used, use count, pinned.
  3. **Tags, grouped by layer** — Axes (with dimension names), Topical, and **Yours**.
     Shows the *full* thresholded set, not the card's 2 + "+N".
  4. **Custom-tag editor** — add/remove chips; input with **autocomplete** from the
     distinct existing user tags; Enter commits, ⌫ on empty removes the last.
  5. **Suggested tags** (when any) — accept/dismiss chips from the learning loop (§5.1);
     accept adds the tag, dismiss hides it for this clip. Hidden when the toggle is off.
  6. **Actions** — Paste, Pin/Unpin, Delete, Copy (and copy-variant if applicable).
- The inspector observes the same `PanelViewModel`; edits to user tags write through the
  store (§5) and update the index immediately so search/filter reflect them without a
  re-summon.

## 8. Migration & compatibility

- **DB:** one additive column (`user_tags`); no destructive change. Old DBs open fine.
- **Vocabulary switch:** changing the active basket (or shipping the curated General)
  changes the basket fingerprint → clips re-tag from **cached vectors**, no re-embedding.
- **Old cube tags:** clips previously tagged on the 10×10 cube simply re-tag under the new
  basket on next classification pass; their cached vectors are reused.
- **Hashing fallback embedder:** tag display already suppressed when the signature isn't
  "ogma" (`ContentView.swift:596`) — unchanged; user tags still show (they're not
  model-derived).

## 9. Open calibration item (τ)

The correct τ depends on the tag-name-vs-content cosine distribution for the shipped ogma
embedder, which differs from the query-vs-content distribution the existing search floors
(0.40 / 0.58) were tuned for. Plan: ship τ = 0.28 provisional, expose it in Settings with
the live "avg tags/clip" readout, and calibrate against a real clipboard during
implementation (target: ~2–5 auto-tags on a typical clip, 0 on genuinely ambiguous ones).
If a single global τ can't satisfy both axes and topical, split into `τ_axis` / `τ_topical`
before going per-dimension.

## 10. Testing

- **Thresholding:** unit tests that a synthetic weak vector yields 0 axis tags and 0
  topical tags below τ, and the argmax/top-K above τ; boundary at τ.
- **Basket id-space:** `range(ofDimension:)` + `topicalRange` partition `tags` exactly;
  fingerprint changes when `topical` changes; all 11 built-in baskets have equal-width
  dimensions (== `dimensionSize`).
- **Custom tags at rest:** a clip with user tags persists them **sealed** (`enc1:`), the
  plaintext never appears on disk (mirrors `testClipContentColumnsAreSealedAtRest`), and
  round-trips via `loadAll`; seal-failure refuses the write.
- **Migration:** opening a pre-column DB adds `user_tags`, existing rows read `[]`.
- **Search:** a user-tag match outranks a neural-only match; thresholding reduces the
  shared-auto-tag set vs the old always-10 behavior.
- **Composition:** the composed basket's id space = General ⊕ overlay with no gaps or
  overlaps; switching the overlay changes the fingerprint; with no overlay, `composed`
  equals General exactly.
- **Suggestions:** a tag applied ≥ `minApplies` is suggested on a clip within `σ_suggest`
  and not otherwise; accept adds it; a dismissal persists and suppresses re-suggestion for
  that clip; suggestions never auto-apply and vanish when the toggle is off.
- **Indexes:** `userTagIndex` stays consistent across insert/update/delete.

## 11. Affected files (map)

- `Search/TagBaskets.swift` — add `topical`; curate `general`; add 10 baskets;
  `overlayID` + `composed` (§3.3).
- `Search/DeepSearch.swift` — τ threshold in `classify` / `classifyDimensions`;
  `topicalRange`; composition-aware merge in `ClipIndexer.tags`; `userTagBoost` in `smart`;
  `nearestTag`; the suggestion centroid/cosine helper (§5.1).
- `Clipboard/ClipItem.swift` — `userTags` field.
- `Clipboard/Database.swift` — `user_tags` column + `user_tag_dismissals` table;
  migration; sealed read/write.
- `Clipboard/ClipStore.swift` — `userTagIndex`, `items(withUserTag:)`, facet union,
  distinct-tags enumeration; dismissal read/write; centroid inputs.
- `UI/ClipCardView.swift` — expand chevron; "+N" chip opens inspector.
- `UI/ClipDetailView.swift` — **new** supercard inspector (incl. Suggested-tags row).
- `UI/ContentView.swift` / `UI/PanelViewModel.swift` — inspector presentation & wiring;
  "Your tags" facet group.
- `UI/SettingsView.swift` — τ control + avg-tags readout; **overlay picker + basket
  roster**; suggestions on/off toggle.
