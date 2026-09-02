# Cliphoard — launch checklist

Rewritten 2026-08-17. The previous version predated semantic image search, the import
framework and the branch consolidation, and described a recovery procedure that is finished.

**State of the world right now:** `main` is the shipping branch and carries everything.
496 tests, 0 failures, 5 skips. The site is live and accurate. Licensing is clean end to end
— MIT app, MIT/Apache-2.0 models, nothing proprietary. **No release has ever been cut.**

Everything below is ordered by dependency, not by effort. Steps 1–4 are yours and nothing
downstream can start without them.

---

## 1. Enrol in the Apple Developer Program — BLOCKS EVERYTHING

**Verified absent:** `security find-identity -v -p codesigning` returns no
`Developer ID Application` identity, and there are 0 Developer ID certificates in the
keychain.

$99/year, 24–48h approval. Then create a **Developer ID Application** certificate (not Mac
App Store, not Development) and install it.

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"   # must print one
```

**This is worth more than "so we can ship".** `Scripts/Cliphoard.entitlements` requests
`keychain-access-groups`, which moves the encryption keys into the **data-protection
keychain** — the one with no ACLs, which therefore never prompts. That entitlement only takes
effect when signed with a real team identity. Every `storeBlob` on an unsigned build returns
`-34018`, which is why this project hit repeated keychain-prompt storms during development.
They were structural to running unsigned. A notarised release makes that entire class of
incident impossible.

## 2. Add the 7 CI secrets

**Verified absent:** `gh secret list -R AntreasAntoniou/cliphoard` returns nothing.
`.github/workflows/release.yml` reads exactly these:

| secret | what it is |
|---|---|
| `MACOS_CERT_P12` | base64 of the exported `.p12` (cert + private key) |
| `MACOS_CERT_PASSWORD` | password you set when exporting the `.p12` |
| `KEYCHAIN_PASSWORD` | any string; CI uses it for a temporary keychain |
| `MACOS_DEVID` | e.g. `Developer ID Application: Antreas Antoniou (TEAMID)` |
| `APPLE_ID` | your Apple ID email |
| `APPLE_TEAM_ID` | 10-character team id |
| `APPLE_APP_PASSWORD` | app-specific password from appleid.apple.com, **not** your Apple ID password |

```bash
base64 -i Certificates.p12 | pbcopy
gh secret set MACOS_CERT_P12 -R AntreasAntoniou/cliphoard
# …repeat for the other six
gh secret list -R AntreasAntoniou/cliphoard   # must show 7
```

## 3. Create and publish the Homebrew tap

**Verified absent:** `AntreasAntoniou/homebrew-tap` does not exist.

```bash
gh repo create AntreasAntoniou/homebrew-tap --public \
  --description "Homebrew tap for Cliphoard"
```

The cask already exists in-repo at `Casks/cliphoard.rb`; it gets copied to the tap **after**
step 4 produces a real checksum.

## 4. Cut the first release — one pass

**Verified:** the cask carries the all-zero placeholder sha256, and that is the EXPECTED
state going into the first cut: the sha is the DMG's, which cannot exist before the release
builds it. `Scripts/release.sh` writes the real sha256 into `Casks/cliphoard.rb` from the
signed+notarised DMG at the end of the run, and `release.yml` commits that to `main` after
the GitHub Release is published. The hard "never publish a zero sha" gate lives where a cask
is actually published — `Scripts/publish-cask.sh` — plus the cask's own Ruby preflight.

```bash
gh workflow run Release --ref main && gh run watch   # 0. unsigned CI dry run: no secrets, nothing published
git tag v1.0.0 && git push origin v1.0.0             # 1. the release (tag == v<Info.plist>, cask version matches)
# wait for the Release workflow: it fails by NAME on any missing secret, else publishes the DMG
git pull                                              # picks up "cask: sha256 of Cliphoard-1.0.0.dmg"
grep '^  sha256' Casks/cliphoard.rb                   # must no longer be all zeros
bash Scripts/publish-cask.sh ../homebrew-tap          # 2. refuses a placeholder; re-downloads the DMG, checks the sha
brew install --cask AntreasAntoniou/tap/cliphoard     # the real proof
```

## 5. Accessibility pass — hardware, not automatable

22 `accessibilityLabel` call sites exist, so the scaffolding is there, but nobody has driven
the app with VoiceOver on. Needed: a VoiceOver run over the panel, the inspector, the search
mode picker and the new image controls; plus a rendered WCAG AA contrast check across all 17
themes. Contrast can be measured from screenshots; VoiceOver cannot be faked.

---

## What I can do the moment 1–3 land

Nothing here is blocked on anything except your steps above.

- **Dry-run the release end to end**: `gh workflow run Release --ref main` builds an unsigned DMG on CI with no secrets and publishes nothing — the first-ever CI compile of this app, so run it before any tag.
- **Update `README.md`** the way the site was updated. It is not WRONG — it already says
  three tiers and permissive licences — but it predates image search, reference-image
  matching, stacking baskets and the import framework.
- **Write the migration note** people arriving from Paste will look for: `--import-scan`,
  `--import-from`, and that every batch is tagged and reversible.
- **Screenshots for the new features.** The site's search section still shows only the two
  old text-search shots; there is no image of image-search working, which is the headline
  capability.
- **Reap orphaned models.** 327 MB of the licence-retired EmbeddingGemma still sits in
  `~/Library/Application Support/Ditto/models` on any machine that ever selected it, and the
  new OpenVision towers are now duplicated there too (bundle + store). Retiring a tier does
  not uninstall it; nothing reaps orphaned model directories.

## Two decisions that are yours

**Bundle size.** The app is **74 MB** because both OpenVision towers ship inside it. They
could download on first use instead — `ModelAssets` already does exactly that for MiniLM,
with SHA-256 pinning. That halves the download for everyone who never searches images, at the
cost of a wait the first time they do. Say which and I will wire it.

**Semantic image search: on or off by default?** It is currently on. Arguments both ways are
real: it is the feature that makes Cliphoard different, and it is also the feature that reads
your screenshots. It can already be switched off in Settings, with a button that erases what
was read.

---

## Done — do not redo

- `main` is the shipping branch; it was 60 commits behind with 14 empty merge commits of its
  own. Everything is consolidated and pushed.
- Site rewritten and accurate: four search directions, ogma named as ours, open-weights story,
  stacking baskets, two new security items, five new comparison rows. Three stale claims
  removed (a withdrawn Gemma tier still being advertised, "10 dimensions with 10 values",
  and a network claim that was no longer complete).
- `models-v1` release notes corrected — they were still advertising the withdrawn Gemma asset
  under "Gemma Terms of Use" on a public repo.
- Push protection resolved properly. Two synthetic vendor-token fixtures in the detector tests
  were tripping GitHub secret scanning; history was rewritten to split the literals rather
  than clicking "allow this secret", which would have recorded an allowed secret against a
  public repo and taught the wrong habit. Backups at `backup/pre-secret-rewrite-*`.
- Licensing verified clean: MIT app · MIT ogma models (ours) · Apache-2.0 MiniLM ·
  Apache-2.0 OpenVision. Nothing carries restrictions beyond the app's own MIT licence.
