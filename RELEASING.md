# Releasing Cliphoard

Cliphoard is distributed directly (Developer ID + notarization), not via the Mac App
Store — a clipboard manager that synthesizes ⌘V and registers a global hotkey
can't run under the App Sandbox.

## One-time setup

1. **Apple Developer Program** ($99/yr) → create a **Developer ID Application**
   certificate (Xcode → Settings → Accounts, or developer.apple.com).
2. **Notary credentials** stored in your keychain (used by `Scripts/release.sh`):
   ```sh
   xcrun notarytool store-credentials cliphoard-notary \
     --apple-id "you@example.com" --team-id "ABCDE12345"
   # password = an app-specific password from appleid.apple.com
   ```
3. **(For CI)** add these repository secrets:
   `MACOS_CERT_P12` (base64 of the .p12), `MACOS_CERT_PASSWORD`,
   `KEYCHAIN_PASSWORD`, `MACOS_DEVID` (`Developer ID Application: Name (TEAMID)`),
   `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`.

## Cut a release

**Prove the CI path first (no secrets, no tag, nothing published):** Actions → Release →
Run workflow, or `gh workflow run Release --ref main`. It restores the pinned models, builds,
runs `verify-bundle`, and packages an UNSIGNED DMG. It is the first place the app is ever
compiled by CI, so a red run here is a finding, not a release.

**Locally:**
```sh
DEVID="Developer ID Application: Your Name (ABCDE12345)" \
NOTARY_PROFILE=cliphoard-notary \
bash Scripts/release.sh
# → build/Cliphoard-<version>.dmg (signed, notarized, stapled)
# → Casks/cliphoard.rb now carries that DMG's sha256: commit it
git commit -am "cask: sha256 of Cliphoard-<version>.dmg"
gh release create v<version> build/Cliphoard-*.dmg --generate-notes
```

**Via CI:** push a tag and `.github/workflows/release.yml` does the rest:
```sh
git tag v1.0.0 && git push origin v1.0.0
```
The first step fails naming any of the 7 secrets that is missing or malformed. The build
step aborts unless the tag equals `v<Info.plist version>` and the cask's `version` matches.
After the GitHub Release is published, the workflow commits the DMG's sha256 into
`Casks/cliphoard.rb` on `main` — `git pull` before publishing the cask.

## Homebrew cask

`Casks/cliphoard.rb` is the cask source; its `sha256` is written by `Scripts/release.sh`
from the notarised DMG (never by hand). Publish it into the tap
(`github.com/AntreasAntoniou/homebrew-tap`) with
```sh
bash Scripts/publish-cask.sh ../homebrew-tap   # refuses the placeholder; verifies the released DMG's sha256
```
then commit + push inside the tap. Users then:
```sh
brew install --cask antreasantoniou/tap/cliphoard
```

## Prerequisite: bundled models

The bundled OpenVision-Tiny towers (`tools/models/openvision-tiny-p8-*.mlpackage` plus the
`openvision-tiny-p8-text/` tokenizer folder) are gitignored. `tools/restore-models.sh`
downloads them as one SHA-256-pinned zip (`openvision-tiny-p8.zip` on the `models-v1`
release) into the exact layout `Scripts/build-app.sh` expects; `Scripts/release.sh` and
`release.yml` run it before building, and `STRICT_BUNDLE=1` makes a missing tower fatal.
To re-publish after a re-conversion: `tools/convert_openvision.py`, `tools/pack-openvision.sh`,
upload the zip to `models-v1`, update `OPENVISION_ZIP_SHA256` in `tools/restore-models.sh`.



## Versioning

Bump `CFBundleShortVersionString` / `CFBundleVersion` in `Resources/Info.plist`
before tagging — `Scripts/build-app.sh` copies that plist into the bundle verbatim,
so the version must be edited at the source. Keep the git tag (`vX.Y.Z`), the
`Info.plist` version, and `Casks/cliphoard.rb`'s `version` in lockstep: the DMG is
named from the plist while the release-download URL directory comes from the tag.
