# Privacy Policy

**Short version: Yank keeps everything on your Mac. Nothing you copy ever leaves
your device. There is no telemetry, no analytics, and no account.**

## What Yank stores, and where

Yank saves your clipboard history so you can get items back later. Everything is
stored **locally** on your Mac, under:

```
~/Library/Application Support/Ditto/
  ditto.sqlite        clipboard history (text, links, colors, file references)
  *.png               image clips and their thumbnails
```

Semantic-search embeddings are computed **on-device** (Apple CoreML) and stored in
the same local database. No clipboard content, embedding, or usage data is ever
transmitted anywhere.

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

_Last updated: 2026-06-19._
