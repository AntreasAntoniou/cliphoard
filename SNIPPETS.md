# Snippets — design spec

**Goal:** close the biggest functional gap in most clipboard managers — a library of *saved,
reusable* clips (email signatures, addresses, boilerplate, canned replies, code
templates) that live separately from the ephemeral copy history.

## Concept: history vs. snippets vs. pins

| | History clip | Pinned clip | **Snippet** |
|---|---|---|---|
| Lifetime | trimmed over time | kept from trimming | **permanent, curated** |
| Origin | auto-captured on copy | a promoted history clip | **explicitly authored / saved** |
| Editable | no | no | **yes (title + content)** |
| Organized | recency | recency | **named, grouped into folders** |

Pinning answers "don't lose this for a while." Snippets answer "I reuse this on
purpose." They're a distinct, hand-curated collection — not the firehose.

## Data model

New encrypted table (mirrors `clips`; content sealed via `Crypto` at rest):

```sql
CREATE TABLE snippets (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,            -- encrypted
  content TEXT NOT NULL,          -- encrypted (the text to paste)
  rtf BLOB,                       -- encrypted, optional rich text
  group_name TEXT,                -- folder ("Email", "Code", …); null = ungrouped
  keyword TEXT,                   -- optional abbreviation for expansion (phase 3)
  created_at REAL NOT NULL,
  last_used_at REAL NOT NULL,
  use_count INTEGER NOT NULL
);
```

A `Snippet` model parallels `ClipItem`. Snippets are embedded for semantic search
in their own vector space (reuse `ClipIndexer`/`TagSpace`), so "find my refund
template" works.

## UX (phased)

### v1 — the library (MVP)
- A **"Snippets"** chip in the bar's category row (alongside All/Pinned/…). Selecting
  it shows the snippet library instead of history, using the same card/list/spotlight
  layouts and the same keyboard model (↑↓/Enter to paste, ⌘C to copy).
- **Save as snippet:** a context-menu / ⌘S action on any history card → opens a small
  editor prefilled with the clip's content; user sets a title (and optional group).
- **New snippet:** ⌘N in snippet mode → blank editor.
- **Edit / delete:** context menu on a snippet card → edit (reopens the editor) / delete.
- **Editor sheet:** title field, multiline content, group picker (free-text combobox),
  Save / Cancel. Renders inside the bar (same surface as Settings) — no extra window.
- Snippets paste exactly like clips (synthetic ⌘V into the frontmost app).

### v2 — organization
- **Groups/folders** shown as sub-filters within Snippets (segmented or a sidebar in
  the Spotlight layout). Drag-to-reorder; collapse/expand.
- **Sort:** by recency, use count, or alphabetical.

### v3 — keyword expansion (opt-in, more invasive)
- Assign an **abbreviation** (e.g. `;sig`, `;addr`). Typing it in any app auto-expands
  to the snippet. Requires a keystroke monitor (Accessibility, already granted) +
  careful backspace/replace via synthetic events. Off by default; per-snippet opt-in.
  This is the TextExpander-style feature — biggest value, highest risk; ship last.

## Integration points

- **Storage:** extend `Database` with `snippets` CRUD (same `Crypto.seal/open` path)
  and a `SnippetStore` (mirrors `ClipStore`, `@MainActor ObservableObject`).
- **Search:** snippet vectors via the existing embedder; the Snippets scope filters to
  them. Essence/Tag/Exact modes all apply within the scope.
- **UI:** `ContentView` gains a snippet mode flag in `PanelViewModel`; reuse
  `ClipCardView`/`clipRow` with a `Snippet`-shaped view model, or a thin adapter.
- **Privacy:** snippets are encrypted at rest like clips; they never leave the Mac.

## Edge cases
- Empty title → derive from first line of content.
- Duplicate keyword → reject in the editor with inline validation.
- Very long content → same truncation/preview rules as clips.
- Snippet referencing rich text → keep `rtf`; plain-paste (Option) strips formatting.
- Deleting the active group → snippets fall back to ungrouped.

## Effort
- **v1:** ~1 focused pass (new table + `SnippetStore` + editor sheet + chip wiring).
- **v2:** small (grouping UI + sort).
- **v3:** medium-high (reliable keystroke expansion + tests), ship independently.

## Non-goals
- No cloud sync of snippets (see [PRIVACY.md](PRIVACY.md) — *Why there's no sync*).
- No shared/team snippet libraries (would require a server).
