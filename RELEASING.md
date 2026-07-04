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

**Locally:**
```sh
DEVID="Developer ID Application: Your Name (ABCDE12345)" \
NOTARY_PROFILE=cliphoard-notary \
bash Scripts/release.sh
# → build/Cliphoard-<version>.dmg  (signed, notarized, stapled)
gh release create v1.0.0 build/Cliphoard-*.dmg --generate-notes
```

**Via CI:** push a tag and `.github/workflows/release.yml` does the rest:
```sh
git tag v1.0.0 && git push origin v1.0.0
```

## Homebrew cask

`Casks/cliphoard.rb` is the cask source. Publish it from a tap repo
(`github.com/AntreasAntoniou/homebrew-tap`) and bump `version` + `sha256` per
release (the release step prints the DMG SHA-256). Users then:
```sh
brew install --cask antreasantoniou/tap/cliphoard
```

## Prerequisite: bundled models

The ogma CoreML models (`tools/models/*.mlpackage`) are gitignored. For a
reproducible CI build, commit them via **Git LFS** or restore them in a step
before `Scripts/release.sh`. A local release uses whatever is in `tools/models/`.

## Versioning

Bump `CFBundleShortVersionString` / `CFBundleVersion` in `Resources/Info.plist`
before tagging — `Scripts/build-app.sh` copies that plist into the bundle verbatim,
so the version must be edited at the source. Keep the git tag (`vX.Y.Z`), the
`Info.plist` version, and `Casks/cliphoard.rb`'s `version` in lockstep: the DMG is
named from the plist while the release-download URL directory comes from the tag.
