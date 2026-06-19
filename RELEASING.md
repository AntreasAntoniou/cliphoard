# Releasing Yank

Yank is distributed directly (Developer ID + notarization), not via the Mac App
Store — a clipboard manager that synthesizes ⌘V and registers a global hotkey
can't run under the App Sandbox.

## One-time setup

1. **Apple Developer Program** ($99/yr) → create a **Developer ID Application**
   certificate (Xcode → Settings → Accounts, or developer.apple.com).
2. **Notary credentials** stored in your keychain (used by `Scripts/release.sh`):
   ```sh
   xcrun notarytool store-credentials yank-notary \
     --apple-id "you@example.com" --team-id "ABCDE12345"
   # password = an app-specific password from appleid.apple.com
   ```
3. **(For CI)** add these repository secrets:
   `MACOS_CERT_P12` (base64 of the .p12), `MACOS_CERT_PASSWORD`,
   `KEYCHAIN_PASSWORD`, `MACOS_DEVID` (`Developer ID Application: Name (TEAMID)`),
   `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`.

## Cut a release

**Locally:**
```sh
DEVID="Developer ID Application: Your Name (ABCDE12345)" \
NOTARY_PROFILE=yank-notary \
bash Scripts/release.sh
# → build/Yank-<version>.dmg  (signed, notarized, stapled)
gh release create v1.0.0 build/Yank-*.dmg --generate-notes
```

**Via CI:** push a tag and `.github/workflows/release.yml` does the rest:
```sh
git tag v1.0.0 && git push origin v1.0.0
```

## Homebrew cask

`Casks/yank.rb` is the cask source. Publish it from a tap repo
(`github.com/AntreasAntoniou/homebrew-tap`) and bump `version` + `sha256` per
release (the release step prints the DMG SHA-256). Users then:
```sh
brew install --cask antreasantoniou/tap/yank
```

## Prerequisite: bundled models

The ogma CoreML models (`tools/models/*.mlpackage`) are gitignored. For a
reproducible CI build, commit them via **Git LFS** or restore them in a step
before `Scripts/release.sh`. A local release uses whatever is in `tools/models/`.

## Versioning

Bump `CFBundleShortVersionString` / `CFBundleVersion` in the bundle's `Info.plist`
(set by `Scripts/build-app.sh`) before tagging.
