# Privacy Policy

**Short version: Yank keeps everything on your Mac. Nothing you copy ever leaves
your device. There is no telemetry, no analytics, and no account.**

## What Yank stores, and where

Yank saves your clipboard history so you can get items back later. Everything is
stored **locally** on your Mac, under:

```
~/Library/Application Support/Ditto/
  ditto.sqlite        clipboard history (text, links, colors, file references), encrypted
  *.png               image clips and their thumbnails, encrypted at rest
```

Semantic-search embeddings are computed **on-device** (Apple CoreML) and stored in
the same local database. No clipboard content, embedding, or usage data is ever
transmitted anywhere.

## Encryption

Everything Yank persists is encrypted at rest with **AES-GCM**: clip **content**
(text, rich text, file paths, colors) in the database, and **image clips and their
thumbnails** as sealed payload files on disk. Sealed values carry an `enc1:` marker;
opening is non-destructive and falls back gracefully, so a re-key never loses data.
The encryption key is bound to your Mac's **Secure Enclave** where one is present —
the key is derived inside the Enclave and its material can never be extracted from
the chip, so copying the database (or the payload files) to another machine is
useless, and no Touch ID prompt is required. On Macs without a Secure Enclave the key
lives in your login Keychain.

The only data that is *not* encrypted is what cannot be: the live system pasteboard
and the in-memory copy of the clip you are pasting, which are plaintext by necessity
while in use. Every value Yank writes to disk going forward is sealed before it
touches the filesystem. One caveat for upgrades: if you ran an older, pre-encryption
build, those earlier builds saved some image payloads unencrypted. On first launch the
new build re-seals them in place, but because macOS filesystems (APFS) are
copy-on-write, the freed unencrypted blocks are not zeroed and may remain recoverable
in unallocated disk space until the OS reuses or trims them. So treat the storage
folder as sensitive and use the exclusion list for apps where you copy secrets.

## What Yank does NOT do

- ❌ No network requests. Yank makes no outbound connections for its core
  functionality and sends your data to no server — ours or anyone else's.
- ❌ No telemetry, analytics, crash reporting, or usage tracking.
- ❌ No account, sign-in, or cloud sync.
- ❌ No advertising or third-party SDKs.

## Sensitive content

Yank deliberately tries **not** to capture secrets:

- It ignores pasteboards apps mark as transient, concealed, or auto-generated —
  the flags password managers (1Password, Keychain, etc.) use.
- You can add any app to an exclusion denylist (`excludedBundleIDs`) so Yank
  never records what you copy from it.
- Clip contents are never written to logs.

That said, a clipboard manager inherently stores what you copy. Treat the local
database as sensitive, and use the exclusion list for apps that handle secrets.

## Permissions

- **Accessibility** — used solely to paste the selected clip into the app you were
  using (by synthesizing ⌘V). Yank does not read other apps' contents.
- **Input monitoring / global hotkey** — to summon the bar with ⌃⌥⌘V.

## Your control

- **Delete a clip:** select it and press ⌘⌫.
- **Clear history:** remove unpinned items from the bar, or quit Yank and delete
  the folder above.
- **Uninstall:** drag Yank to the Trash and delete `~/Library/Application Support/Ditto/`.

## Why there's no sync (on purpose)

Every other major clipboard manager sells cross-device sync. Yank deliberately
does not — and never will — and that is a feature, not an omission.

**Your clipboard is the single most sensitive ambient stream on your computer.**
In the course of a normal day it transiently holds passwords (copied from your
password manager), one-time 2FA codes, API keys and tokens, private messages,
addresses, and card numbers. A clipboard *manager* persists that stream. A
clipboard history is, in effect, a concentrated archive of your secrets.

Given that, the most important property by far is: **it must be impossible to
exfiltrate.** If the data never leaves the device, there is no sync server to
breach, no vendor who can read it, no cloud copy to subpoena, no account to phish,
and no network path for malware to abuse. "It physically cannot leave your Mac" is
a stronger, simpler promise than any amount of policy.

**But what about end-to-end-encrypted sync?** E2E is genuinely better than
plaintext cloud — but it still weakens the core guarantee. It requires an account
(identity + metadata), a server (an attack surface and an availability
dependency), and key management (a key that can be lost, leaked, or compelled);
and it means your secrets *do* leave the device, just wrapped. "We sync, but it's
encrypted" is a caveated story. **"It cannot leave" is not.** For a tool whose
whole job is to hold your secrets, we choose the absolute.

Being open source makes this auditable: you can read the source and confirm there
are zero network calls. Add sync and that verifiable fact becomes "trust our
crypto and our server" — a weaker trust model we're not willing to ask of you.

**If you want sync anyway,** you remain in control: point the store
(`~/Library/Application Support/Ditto/`) at your own synced folder (iCloud Drive,
Syncthing, etc.) at your discretion. That's your choice to make — not a default we
impose, and not data we ever hold.

## Changes

Any future change to this policy will appear in this file in the public repository,
with the change visible in the Git history.

_Last updated: 2026-06-25._
