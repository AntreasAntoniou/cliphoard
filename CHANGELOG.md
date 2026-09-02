# Changelog

## 1.0.0 — 2026-09-02

### What it is

The first release of Cliphoard: a fast, private, open-source clipboard manager for macOS 13+
(Universal, Apple Silicon and Intel). Press ⌃⌥⌘V and your history slides up from the bottom
of the screen — text, rich text, links, hex colours, files and images — searchable by
meaning as well as by exact text, with on-device search models, 17 themes, three layouts,
stackable tag baskets, text recognition inside screenshots, image search by description or
by example, and an importer for the clipboard managers already on your Mac. Native Swift,
no Electron, no account, no cloud.

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

- Encrypted, passphrase-protected export/import for moving history to a new Mac
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

**SHA-256:** (filled at release)
