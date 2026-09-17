# Changelog

## 1.0.1

### Move to another Mac

*Settings → Move to another Mac*, and the headless equivalents `--export-history <path>` /
`--import-history <path>`.

**Export** writes your whole history into one encrypted `.cliphoard` file: every clip's
content, rich text, file paths, colours, your tags, recognised image text, the app each clip
came from, pin state, timestamps, use counts and detector flags — plus the image payloads
themselves and the Vision prints behind "clips that look like this". The search index is
**not** in the file; it is recomputed on the new Mac (about seven minutes for an
8,000-clip store, in the background, with the app usable throughout), which keeps the file
roughly 60 MB smaller on a store that size and unties it from whichever search model you
happen to be using.

**Import** merges. It never deletes, it never re-tags, and it never bumps a clip's dates: a
clip already on the new Mac is skipped, whether it matches by id or by content, and the two
counts are reported separately. Everything lands in one transaction, and the row count is
re-read from the database afterwards rather than trusted from the tally — if anything is
wrong, nothing is imported. A snapshot of the previous database is written beside it
(`ditto.sqlite.pre-import-…`, via `VACUUM INTO`, so it is consistent with the write-ahead
log rather than a half-copy) before a single row is written, and the result banner says
where it is.

**How the file is protected.** One authenticated stream: AES-256-GCM in 1 MiB chunks, each
chunk bound to the file's 48-byte header, its own position and whether it is the last — so a
truncated, reordered, spliced or modified file is refused rather than partly read, including
the case where it was cut exactly on a chunk boundary. The key is stretched from your
passphrase with PBKDF2-HMAC-SHA256, a fresh 16-byte random salt and at least 600,000
iterations (calibrated to your Mac, and the floor is compiled in so a file cannot ask for
less). The passphrase needs at least 12 characters, there is a Generate button, and **there
is no recovery**: nothing is escrowed, no backup key exists, and a lost passphrase means a
file nobody can open.

**What it refuses to do.** Both directions refuse in safe mode, and both refuse if the
history could not be read in full — an export of a partial read would silently lose clips,
and the usual next step after an export is to wipe the old Mac. An export that cannot
decrypt some of its own rows or images refuses too, and will only proceed once you say so —
in which case the file records the counts, so the destination says it as well. A partial
export can never present itself as a complete one.

**Two command-line flags**, for moving a history without touching the interface:
`--export-history <path> [--store-dir <dir>] [--allow-unreadable]` and
`--import-history <path> [--store-dir <dir>] [--dry-run] [--set-unlimited | --accept-trim]`.
The passphrase is read from stdin only — never from the arguments, where `ps` would show it.
`--dry-run` checks every chunk's tag to the end of the file and prints what would be
imported, writing nothing at all. `--set-unlimited` exists because the history limit
defaults to 200 and trimming deletes rows *and* unlinks their images: the import lifts the
limit before it writes, or refuses, rather than letting your next copy quietly evict the
history that just arrived.

### Also in this release

- **The file picker no longer hides the bar.** Settings is drawn inside the floating panel,
  so any system window taking key focus dismissed the whole interface underneath it.
  "Choose…" in *Import* had no guard at all.

## 1.0.0 — 2026-09-11

### What it is

The first release of Cliphoard: a fast, private, open-source clipboard manager for macOS 13+
(Universal, Apple Silicon and Intel). Press ⌃⌥⌘V and your history slides up from the bottom
of the screen — text, rich text, links, hex colours, files and images — searchable by
meaning as well as by exact text, with on-device search models, 17 themes, three layouts,
stackable tag baskets, text recognition inside screenshots, image search by description or
by example, and an importer for the clipboard managers already on your Mac. Native Swift,
no Electron, no account, no cloud.

### Also in this release

- **File clips open.** Double-click a file clip (a PDF, a document, an image file) and it opens
  in its default app; `⌘O` does the same for the selected clip. Right-click and the inspector
  gain **Open**, **Reveal in Finder** and **Copy Path**; `⌥⌘C` copies the path as plain text
  (Finder's own "Copy as Pathname" chord). A file clip no longer pastes on a mouse click — click
  selects, double-click opens, and ↩ / `⌘1–9` / right-click → Paste still paste it. Every other
  clip kind is unchanged. If the file has been moved or deleted, Open and Reveal are greyed with
  the reason and the bar says which path is gone; Copy Path still works.
- **Quit is discoverable.** `⌘Q` quits from the bar, the inspector and Settings; the safe-mode
  banner carries Quit and Relaunch; Settings → General has a Quit button. If clips are held
  unsaved (safe mode), quitting asks first and names how many.

### Privacy in this release

- **Encrypted at rest, AES-GCM.** Clip content — text, rich text, file paths, colours,
  tags, recognised text and, new in this release, the name of the app each clip came from
  — is sealed in the database; image clips and their thumbnails are sealed payload files
  on disk; the semantic search index is sealed too. Stored in the clear, on purpose: the
  row id, clip kind, timestamps, pin state, use count and the small detector flags.
- **One-time migration on first launch.** Builds before 1.0.0 stored the source-app name
  in the clear. 1.0.0 seals it on first launch and compacts the database; your history is
  kept. (APFS is copy-on-write, so freed unencrypted blocks may linger in unallocated
  space until the OS reuses or trims them — see PRIVACY.md.)
- **The key.** On a Mac with a Secure Enclave, a P-256 private key is generated inside the
  Enclave and never leaves it; the AES key is derived from it (key agreement + HKDF). A copy
  of that derived key is kept in your login Keychain marked this-device-only — never synced,
  never in the database. Macs without a Secure Enclave use a random key in the login
  Keychain. No Touch ID prompt is involved.
- **Password-manager clips are quarantined, not hidden.** Pasteboards marked transient,
  concealed or auto-generated are never stored. A clip that still arrives from a known
  password manager is stored encrypted but flagged *password app* and excluded from every
  search index — no embedding, no tags, no recognition. It stays visible and pastable in
  your history; delete it with ⌘⌫. Exclude any app entirely with
  `defaults write io.antreas.cliphoard excludedBundleIDs -array com.example.app`.
- **No network.** Nothing you copy ever leaves your Mac. The app's only outbound calls are
  optional, download-only fetches of a search model you have not installed yet (the ogma
  models from HuggingFace, the others from our GitHub release); they carry none of your
  data. No telemetry, no analytics, no account.
- **Screenshots are made pasteable in web apps — on by default, with a switch.** macOS puts
  a screenshot on the clipboard in a format browsers cannot read, so pasting one into
  Messenger, Gmail or any web app silently does nothing (the first issue filed against this
  project); Cliphoard adds a PNG they understand. To do that it has to take ownership of the
  clipboard and rewrite it — the only time it does anything to the clipboard beyond reading
  it and writing the clip you picked. Your screenshot is carried across; apps that ask for
  TIFF get a standard-range image; the clipboard's owner shows as Cliphoard; and if both the
  rewrite and the restore fail the clipboard is left empty (unlikely, logged loudly). Turn it
  off in *Settings → Make screenshots pasteable in web apps*. Full detail in PRIVACY.md.

### Fixed

- The inspector now opens in its own centred window above the bar, instead of inside it.

### Not notarized yet

> **1.0.0 is not yet notarized by Apple** (the notarized build and Homebrew tap ship in 1.0.1).
> First launch: open it once, then *System Settings → Privacy & Security → Open Anyway*, or
> `xattr -dr com.apple.quarantine /Applications/Cliphoard.app`. When 1.0.1 replaces it, macOS
> treats it as a new app: re-grant Accessibility once and click **Always Allow** when Cliphoard
> asks for its keychain key (Deny freezes history read-only; nothing is deleted).

The build is signed with the project's local self-signed certificate, still named
"Ditto Local Signing" from the app's former name.

### Deferred to 1.0.1

- Touch ID hiding for password-manager clips
- A Settings UI for excluded apps
- The notarized build and Homebrew tap

### Known issues

- A launch during a dark wake can enter read-only safe mode until relaunch.
- The keychain may ask for confirmation on each launch until the key reaches the
  data-protection keychain.
- The one-time-code detector cannot recognise the format authenticator apps use (a code
  shown as two short groups with no surrounding words), so recognised text from those
  screenshots is not reliably withheld — see PRIVACY.md.

### Licences

- The app is MIT.
- Bundled: the OpenVision-Tiny image and text towers, Apache-2.0 — licence text shipped
  inside the `.app` and at the root of the DMG (`LICENSE-Apache-2.0.txt`).
- On demand, never bundled: the ogma models (MIT) and all-MiniLM-L6-v2 (Apache-2.0).
- Full attribution in `THIRD-PARTY-NOTICES.md`.

**SHA-256:** `f439daa3510b9e27c2c52341f932e6fce7be0981b585a0d188a56c5c6483a85e`
