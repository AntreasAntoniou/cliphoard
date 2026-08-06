# Cliphoard — Useful Tags: Deterministic Clusters, Behavioural Signals, Gated Topics

**Date:** 2026-08-06 · **Branch:** `rename/cliphoard` · **Status:** design (approved) → building

## 1. Evidence (why this exists)

Audited all **202 real clips** (text 124, link 46, image 21, color 6, file 5) with
`Cliphoard --analyze-tags` against the current General basket, on-device:

| Axis | median cos | **margin (top1−top2)** | dominant |
|---|---|---|---|
| Content type | 0.42 | **0.10** | link 29% |
| Domain | 0.36 | 0.08 | web 41% |
| **Intent** | 0.35 | **0.04** | cite 27% |
| **Sensitivity** | 0.33 | **0.04** | ephemeral 32% |

Re-run on **embeddinggemma-300m** (34× larger): margins **equal or worse**
(0.06/0.04/0.03/0.03) — everything flattened to ~0.4-similar.

**Conclusions.** (a) Intent and Sensitivity are coin flips — a cancer-research
sentence was tagged `Sensitivity=pii(0.17)`, `Intent=read-later(0.09)`.
(b) Content type merely re-derives the known `kind` field. (c) **The root cause is
the technique, not model capacity**: argmax cosine against a bare tag-*word*
embedding, forced one-per-axis across 8 mutually-indistinguishable synonyms.

## 2. Principles

1. **Tiered precedence, cheapest-and-surest first:** deterministic rules → exact
   metadata → behaviour → embedding → user tags. The embedder is the *last* resort.
2. **Confident-or-blank.** No forced argmax. **Blank is a valid, common outcome.**
3. **Fail-closed, presence-only for sensitivity.** Only ever *add* a protective tag.
   **Never emit a positive "safe/public" label** — absence of a badge is the only
   honest signal, because no detector can prove safety.
4. **Every emitted VALUE maps to one glance-action** (paste/open/fill/cite/pin/
   delete/redact). No action → it does not ship. This deletes actionless defaults
   (`prose`, `one-shot`).
5. **Gate the vocabulary, not just the clip.** A candidate embedding bucket ships
   only if it clears the margin harness on real clips.
6. **≤2–3 tags per clip**, ordered by certainty.

## 3. Clusters

### Tier 1 — Deterministic (margin-1.0, no model, at capture)

**3.1 Secret / Credential** — `deterministic-rule`
- Tier-1 zero-FP signatures (tag immediately): `-----BEGIN … PRIVATE KEY-----`;
  vendor prefixes `AKIA…`, `gh[pousr]_…`, `xox[baprs]-…`, `sk_live_…`, `AIza…`,
  `sk-…`; JWT `eyJ….….…`.
- Tier-2 generic entropy, gated hard: len ≥ 24, Shannon ≥ 3.5 b/char, ≥2 charset
  classes, single token, not a plausible checksum. **Must clear an FP audit** against
  the real clips (git SHAs, UUIDs, base64, minified code) before it is *trusted*;
  until then it may flag but must not drive a destructive action.
- No match → blank. **Glance:** key badge + masked preview; reveal-to-paste.

**3.2 Financial** — `deterministic-rule`
- `card` = 13–19 digit run passing **Luhn AND a mandatory IIN/brand-prefix** check
  (Luhn alone passes ~10% of random runs); `iban` = mod-97 == 1; `crypto` = BTC
  bech32/base58check, ETH `0x`+40hex with EIP-55 **only when mixed-case**;
  `routing` = ABA 9-digit 3-7-1 mod-10. Tag only on a passing validator.

**3.3 PII (identity)** — `deterministic-rule`, **severity-split**
- `email`/`phone` → **informational badge only** (no mask, no TTL, no index
  exclusion — these are copied precisely to be used).
- `national-id`/`address` → protective treatment (mask + caution). Fire rarely.
- The split is what prevents tap-through alarm fatigue.

**3.4 Shape (structure)** — `deterministic-rule`, **`kind == .text` only**
- First-match-wins, **after** the sensitive detectors: `url` (scheme://), `command`
  (leading `$`/`#` or first token ∈ {git,cd,brew,sudo,docker,kubectl,npm,pip,ssh,curl}),
  `code` (fence / brace+semicolon+indent density), `json`/`yaml`, `path` (`~?/…`,
  no spaces), `color` (`^#?[0-9a-f]{3,8}$`), `value` (single-token number/amount/id).
- **Default/prose → BLANK.** Subdivides the 61% of clips `kind` cannot split.

### Tier 2 — Metadata & behaviour (exact, free, model-independent)

**3.5 Source / Provenance** — `metadata-behavioral`
`clip.sourceApp` → friendly name/glyph. Always show the raw app name; an optional
role bucket (web/shell/code/chat/notes/mail) is convenience only. **Glance:** one tap
filters history to that origin.

**3.6 Reuse & Lifecycle** — `metadata-behavioral`
Emit only the confident extremes, **blank the ambiguous middle**:
`sticky` (pinned OR useCount ≥ 3) · `throwaway` (age > 7–14d AND useCount == 0 AND
!pinned) · `fresh` (age < 1h AND useCount == 0). Thresholds are **placeholders to be
calibrated** against the real useCount/age distribution. Replaces the semantic Intent
axis outright.

**3.7 Link-disposition** — `metadata-behavioral`, **`kind == .link` only**
`to-open` (age < 1h, useCount == 0) · `read-later` (useCount == 0, age > 1h) ·
`reference` (host/path ∈ doi.org/arxiv/pubmed/scholar, or DOI/ISBN pattern).
`useCount == 1` → blank.

**3.8 One-time code (OTP)** — `hybrid`
Isolated 4–8 digit run near {code, verification, one-time, OTP, passcode, 2FA}, **or**
a login/verify/magic URL with a high-entropy token param. Auth-ish `sourceApp` +
recency is a **confidence booster, not a hard AND**. Short TTL; auto-drop after first
paste. **Glance:** pinned to top with a countdown.

**3.9 Sensitive-Source quarantine** — `metadata-behavioral`
Frontmost bundle-id ∈ user-editable denylist (1Password, Bitwarden, KeePassXC, Apple
Passwords) **or** pasteboard hints `org.nspasteboard.ConcealedType` /
`AutoGeneratedType`. Exact match, never probabilistic. A secret must beat **both** the
byte rules and the origin net to reach trusted plaintext history.

### Tier 3 — User-owned

**3.10 Your labels + suggestions** — `hybrid`
`userTags` primary and **model-immune**. Suggestions in two gated tiers:
(a) deterministic-flag chips composed from 3.1–3.9 — ship now, one tap promotes to a
durable userTag; (b) centroid learning from prior hand-applies — **add the missing
margin-over-next-tag check** (today `suggestedUserTags` gates on absolute σ = 0.45
only, dangerously near the ~0.4 flattening zone) plus a ≥4-sample minimum.

### Tier 4 — Embedding (probationary)

**3.11 Coarse Topic** — `embedding-prototype`, **opt-in, must earn its place**
~6 **mutually-disjoint** buckets: `tech-code`, `money-finance`, `people-contact`,
`place-travel`, `health-medical`, `writing-prose`. Each is an L2-normalised **centroid
of ≥8 concrete example phrases** (health: "colorectal cancer screening results", "MRI
scan appointment", "dosage 20mg twice daily") — **never the bare word**.
Accept top1 only if `top1 ≥ absoluteFloor(embedder)` **AND** `(top1−top2) ≥ δ`; else
**blank**. **Validated offline** by the extended `--analyze-tags` harness on the real
clips; any bucket that coin-flips is **dropped before ship**. Sensitive-flagged clips
are **excluded from the embedding index entirely**.

## 4. Drop list

- **Sensitivity axis** (0.04 margin, actively harmful false confidence) → 3.1–3.3, 3.9.
- **Intent axis** (0.04 margin; intent is behaviour) → 3.6, 3.7, 3.8.
- **Content-type axis** (redundant with `kind`) → read `kind`; 3.4 for text.
- **Domain axis** (0.08, abstract, no action) → dropped, not replaced.
- **Argmax-vs-tag-word technique**; **force-assignment** (one tag per axis per clip);
  the **`dimensionSize = 8` invariant** (8 synonyms per axis *is* the root cause).
- The duplicated Intent/Sensitivity axes **across every specialist basket**.
- The 16 topical **word** tags as forced embedding tags — reassign url/email/path/
  command/phone/color/amount to deterministic rules.
- Any positive **"public/safe"** label, anywhere.
- Uniform mask+TTL for email/phone; ungated co-occurrence learning; a standalone
  "today" chip (no distinct action).

## 5. Architecture

- **One synchronous detector pass** in `ClipStore.add`, **before** the CoreML embed and
  **before** the SQLite write (sub-ms vs a tens-of-ms forward pass). It keeps the model
  off the copy hot path and lets a detector **veto** indexing/persistence of a secret.
- Result stored as a compact **flag set on the clip** (`ClipFlags`, an `OptionSet`
  persisted as an INTEGER column) so chips render with no recompute.
- **Source / Lifecycle / Link-disposition are derived at render time** from existing
  `ClipItem` fields — no migration, and they survive any model/vocab switch.
- New files: `Search/Detectors.swift` (Tier 1, pure), `Search/DerivedTags.swift`
  (Tier 2, pure). Both are pure functions over a clip → unit-testable without a store.

## 6. Testing

Detector precision (each signature/checksum fires exactly on valid input and **not** on
git SHAs, UUIDs, base64, minified code); Luhn **requires** IIN; `prose` never emitted;
Shape runs only on text, Link-disposition only on links; lifecycle blanks the middle;
**no positive safe/public label is ever produced**; sensitive-flagged clips never enter
the embedding index; suggestion margin gate rejects a near-tie; harness scores
candidate centroids and reports per-bucket margin.

## 7. Rollout

Blank-by-default. Ship Tiers 1–3; Coarse Topic stays behind the harness gate and ships
only for buckets that clear floor+margin on the real corpus. Calibrate every
behavioural threshold against the real distribution before enabling cull/pin actions.

## 8. Preserved dissent

- **Embeddings in/out:** one lens argues for *zero* embeddings (purity + ~200-clip data
  sparsity); others keep one gated lane. **Resolution: deterministic + behavioural core
  ships regardless; Coarse Topic must clear the harness or it is cut.**
- Whether email/phone deserve even an informational badge (decide on real behaviour).
- Financial as its own cluster vs folded into one Trust-&-Safety family.
- Learned suggestions: ship-now vs wait-for-volume (tiering honours both).
- Source raw app name vs normalised role bucket (recommendation: always show raw).
