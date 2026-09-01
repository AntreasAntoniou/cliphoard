# Privacy Policy

**Short version: Cliphoard keeps everything on your Mac. Nothing you copy ever leaves
your device. There is no telemetry, no analytics, and no account.**

## What Cliphoard stores, and where

Cliphoard saves your clipboard history so you can get items back later. Everything is
stored **locally** on your Mac, under:

```
~/Library/Application Support/Ditto/
  ditto.sqlite        clipboard history (text, links, colors, file references), encrypted
                      — including text read out of images (see below), encrypted
  *.png               image clips and their thumbnails, encrypted at rest
```

Semantic-search embeddings are computed **on-device** (Apple CoreML) and stored in
the same local database. No clipboard content, embedding, or usage data is ever
transmitted anywhere.

## Reading text inside images

**Cliphoard reads the text inside your images so you can search them.** If you copy a
screenshot, a chart, or a photo of a document, Cliphoard uses Apple's Vision framework —
entirely on your Mac, with no network involved — to recognise any text in it. That text
is then searchable exactly like a text clip, and is stored encrypted alongside it. It
also computes a *perceptual fingerprint* of the image so it can show you visually similar
images; that fingerprint is a list of numbers, not a picture and not words, and it is
encrypted too.

We want to be plain about why this matters, because it is a real change and not a
cosmetic one. **A screenshot's contents are unreadable to search until they are
recognised, and searchable afterwards.** If you screenshot a password manager, a banking
page, or someone else's private message, recognition is what would make those words
findable. So Cliphoard refuses to store recognised text when it looks like:

- a credential, API key, or private key
- a high-entropy string that *might* be a secret even if it matches no known format
- a one-time code
- payment-card or bank details
- a full postal address

In those cases the image is still kept, still pastable, still visible in your history —
Cliphoard simply does not write down what it read, so the words never become searchable
and never reach the search model. Images copied from apps on your exclusion list are
never analysed at all.

**Two honest limitations.** First, recognition is imperfect: if a character is misread,
a credential may no longer match the patterns above, which is why the high-entropy rule
is deliberately broad. Second, the one-time-code detector cannot recognise the format
used by authenticator apps (a code shown as two short groups, like `482 913`, with no
surrounding words), so those are not reliably withheld — treat authenticator screenshots
as you would any other secret.

You can turn this off entirely in **Settings → Read text in images**, and **Forget
recognised text** deletes everything that has already been read, in one action. Turning
it off stops all future recognition; it does not by itself erase what was already read,
which is what the Forget button is for.

## Encryption

Everything Cliphoard persists is encrypted at rest with **AES-GCM**: clip **content**
(text, rich text, file paths, colors) in the database, and **image clips and their
thumbnails** as sealed payload files on disk. Sealed values carry an `enc1:` marker;
opening is non-destructive and falls back gracefully, so a re-key never loses data.
The encryption key is bound to your Mac's **Secure Enclave** where one is present —
the key is derived inside the Enclave and its material can never be extracted from
the chip, so copying the database (or the payload files) to another machine is
useless, and no Touch ID prompt is required. On Macs without a Secure Enclave the key
lives in your login Keychain.

## Making screenshots pasteable in web apps — off by default

macOS puts a screenshot on the clipboard in a format browsers cannot read, so pasting one
into Messenger, Gmail or any other web app silently does nothing. Cliphoard can fix that by
adding a format they understand.

**It is off unless you turn it on, and here is exactly what it does when you do.**

To add a format to the clipboard, macOS requires you to *own* it, and taking ownership means
clearing it first — there is no API to add a format in place. (`addTypes` on a clipboard you
do not own returns `-1` and writes nothing; the Pasteboard Manager's own error is
`notPasteboardOwnerErr` — "client did not clear the pasteboard".) So Cliphoard reads every
format on the clipboard, builds a replacement carrying them plus a standard PNG, and writes it
back. Legacy aliases from the NeXT era are the one exception: macOS rejects them as invalid
identifiers when writing, and re-creates them from the modern format afterwards, so they come
back on their own.

If that write fails, the original is put back from what was read. **And if that restore also
fails, the clipboard is left empty.** That is the one way this feature can lose something you
had. It is unlikely — nothing fallible happens between reading the originals and writing them
back — but it is possible, the app logs it loudly when it happens, and a document that exists
to hide nothing should not omit it.

Four consequences, none of them hidden:

- **Cliphoard becomes the clipboard's owner.** Anything that inspects the owner to see where
  content came from will see Cliphoard rather than the app that produced it.
- **Apps that ask for TIFF get a standard-range image.** Measured on an HDR screenshot: the
  TIFF goes from 16-bit Display P3 to 8-bit sRGB. The original is still there in its own
  format, byte for byte, for anything that asks for it.
- **The clipboard is rewritten at all**, which is the only time Cliphoard does anything to it
  other than read, or write the clip you picked.
- **It can, rarely, be left empty** — only if both the rewrite and the restore fail. Logged
  loudly when it happens.

It never runs on a clipboard marked transient, concealed or auto-generated, on an app you
have excluded, or on anything that is not an image. Leave it off and Cliphoard only observes.

The only data that is *not* encrypted is what cannot be: the live system pasteboard
and the in-memory copy of the clip you are pasting, which are plaintext by necessity
while in use. Every value Cliphoard writes to disk going forward is sealed before it
touches the filesystem. One caveat for upgrades: if you ran an older, pre-encryption
build, those earlier builds saved some image payloads unencrypted. On first launch the
new build re-seals them in place, but because macOS filesystems (APFS) are
copy-on-write, the freed unencrypted blocks are not zeroed and may remain recoverable
in unallocated disk space until the OS reuses or trims them. So treat the storage
folder as sensitive and use the exclusion list for apps where you copy secrets.

## What Cliphoard does NOT do

- ❌ No network requests carrying your data. Cliphoard sends your clips to no
  server — ours or anyone else's. Its single outbound call is an *optional*,
  user-initiated, download-only fetch of a search model — the ogma models from
  HuggingFace (`huggingface.co/axiotic/ogma-*`), everything else from our GitHub
  Releases. Nothing about you is sent: these are plain GETs for public files
  when you select a tier that isn't bundled (nothing about you or your
  clipboard is sent; just an HTTPS file download).
- ❌ No telemetry, analytics, crash reporting, or usage tracking.
- ❌ No account, sign-in, or cloud sync.
- ❌ No advertising or third-party SDKs.

## Sensitive content

Cliphoard deliberately tries **not** to capture secrets:

- It ignores pasteboards apps mark as transient, concealed, or auto-generated —
  the flags password managers (1Password, Keychain, etc.) use.
- You can add any app to an exclusion denylist (`excludedBundleIDs`) so Cliphoard
  never records what you copy from it.
- Clip contents are never written to logs.

That said, a clipboard manager inherently stores what you copy. Treat the local
database as sensitive, and use the exclusion list for apps that handle secrets.

## Permissions

- **Accessibility** — used solely to paste the selected clip into the app you were
  using (by synthesizing ⌘V). Cliphoard does not read other apps' contents.
- **Input monitoring / global hotkey** — to summon the bar with ⌃⌥⌘V.

## Your control

- **Delete a clip:** select it and press ⌘⌫.
- **Clear history:** remove unpinned items from the bar, or quit Cliphoard and delete
  the folder above.
- **Uninstall:** drag Cliphoard to the Trash and delete `~/Library/Application Support/Ditto/`.

## Why there's no sync (on purpose)

Every other major clipboard manager sells cross-device sync. Cliphoard deliberately
does not — and never will — and that is a feature, not an omission.

**Your clipboard is the single most sensitive ambient stream on your computer.**
In the course of a normal day it transiently holds passwords (copied from your
password manager), one-time 2FA codes, API keys and tokens, private messages,
addresses, and card numbers. A clipboard *manager* persists that stream. A
clipboard history is, in effect, a concentrated archive of your secrets.

Given that, the most important property by far is: **it must be impossible to
exfiltrate.** If the data never leaves the device, there is no sync server to
breach, no vendor who can read it, no cloud copy to subpoena, no account to phish,
and no network path that carries clip data. "Your clips physically cannot leave
your Mac" is a stronger, simpler promise than any amount of policy. (The only
outbound request the app can make at all is the optional model download above —
download-only, carries nothing.)

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
