# Releasing Cliphoard

Cliphoard has two distribution builds from the same open-source codebase:

- **Direct download:** Developer ID signing and notarization, optional Accessibility
  permission for automatic paste, and offline Pro licence keys. This document covers
  that release pipeline.
- **Mac App Store:** an `APP_STORE` build with App Sandbox, user-initiated file access,
  bundled models and StoreKit Pro purchases. It copies selected clips to the clipboard;
  the user presses ⌘V. See [MAC_APP_STORE.md](MAC_APP_STORE.md) for its separate signing
  and upload pipeline. A valid local build does not establish a published Store listing.

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
   `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`,
   `MACOS_PROVISION_PROFILE_BASE64` (base64 of the profile described below).
4. Register the explicit App ID **`ai.a2-labs.cliphoard`**, then create a
   **Developer ID distribution provisioning profile** for it, selecting the same
   Developer ID Application certificate used for signing. The app's Keychain
   Sharing entitlement is declared in `Scripts/Cliphoard.entitlements`; there is
   no separate Keychain Sharing checkbox in the current App ID registration form.
   Keep the downloaded `.provisionprofile` outside the source checkout and pass
   its path as `PROVISION_PROFILE`. The downloaded profile must authorize the
   configured Keychain group; the release preflight checks this explicitly.

   `keychain-access-groups` is a restricted entitlement: a certificate alone does
   not authorize it. `release.sh` validates the profile, takes the App ID prefix
   from it (which can differ from the Team ID), embeds it before signing, and checks
   the final signature's entitlements and certificate against the profile.
   See [Apple's distribution-signing guidance](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)
   and [TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles).

The A2 Labs bundle identity replaces `io.antreas.cliphoard` in 1.0.1 (build 2).
In the direct edition, startup copies missing preferences and the stored licence once, preserving new
choices and the old preferences domain. Clipboard files, model storage, the
`ai.axiotic.ditto` Keychain service, the original default Keychain access group,
archive UTI and existing notification names remain stable compatibility identifiers.
macOS Accessibility and launch-at-login approvals are tied to app identity and may
need to be granted again; the app must not copy or bypass those OS permissions.
The Store edition uses its own sandbox and keychain group. It does not read the old
preferences domain or migrate a direct licence; history transfer is an explicit encrypted
archive export/import chosen by the user.

## Cut a release

**Prove the CI path first (no secrets, no tag, nothing published):** Actions → Release →
Run workflow, or `gh workflow run Release --ref main`. It restores the pinned models, builds,
runs the regression suite and `verify-bundle`, and packages an UNSIGNED DMG. A red run
here is a finding, not a release. Packaging restores prebuilt, checksum-pinned CoreML
models; the Python conversion dependencies are used only by the model workflow.

**Locally:**
```sh
DEVID="Developer ID Application: Your Name (ABCDE12345)" \
NOTARY_PROFILE=cliphoard-notary \
PROVISION_PROFILE="/path/to/Cliphoard-DeveloperID.provisionprofile" \
bash Scripts/release.sh
# → build/Cliphoard-<version>.dmg (signed, notarized, stapled)
# → Casks/cliphoard.rb now carries that DMG's sha256
# Complete the isolated customer-install gate below before publishing these exact bytes.
git commit -am "cask: sha256 of Cliphoard-<version>.dmg"
gh release create v<version> build/Cliphoard-*.dmg --generate-notes
```

**Via CI:** a tag builds a candidate; it does not publish a GitHub Release or push a cask:
```sh
git tag v1.0.0 && git push origin v1.0.0
```
The first step names missing release inputs and checks the signing identity and certificate.
The provisioning profile is validated before compilation and again against the signed app. The build
step aborts unless the tag equals `v<Info.plist version>` and the cask's `version` matches.
Tagged local runs also require both `DEVID` and `NOTARY_PROFILE`. Signed releases must
pass ticket validation and Gatekeeper assessment for both the app and the final DMG
before the candidate's cask checksum is written.
Those checks are necessary but do not prove the app can launch. Before publishing,
download the final DMG through a browser in an isolated macOS account, retain its
quarantine, install through Finder, and actually open it. Then complete Free/Pro
activation, quit/relaunch persistence, and licence removal back to Free. A notarized
candidate with an unauthorized restricted entitlement can pass Gatekeeper and still
be rejected by AMFI before `main`.
The workflow saves the DMG, checksum and candidate cask in a workflow artifact.
Download that artifact, verify its checksum, perform the acceptance gate, and
only then publish the exact tested DMG and commit its cask checksum. Do not rebuild
between acceptance and publication. Publication is a separate owner-authorized step.

## First cut without a certificate (what 1.0.0 did)

No Developer ID certificate existed for 1.0.0, so the first cut was unsigned and published
by hand, with the automation kept out of the way:

1. `bash Scripts/release.sh` with no `DEVID` / `NOTARY_PROFILE` → an unsigned
   `build/Cliphoard-<version>.dmg` and the printed DMG sha256. `Casks/cliphoard.rb` is
   untouched by design: only a notarised DMG's checksum ever enters the cask.
2. `gh release edit models-v1 --prerelease` — the models release must never be what
   `releases/latest` resolves to. Done **after** the app release exists, so that endpoint
   is never momentarily a 404.
3. `gh workflow disable Release` before the tag and release, `gh workflow enable Release`
   after — a tag push must not trigger the signed CI path with no secrets behind it.
4. Publish as `gh release create v<version> build/Cliphoard-<version>.dmg --latest`.
   1.0.0 shipped as a **full** release, not a pre-release: the site's own download buttons
   reached `releases/latest` at the time, and with both releases marked pre-release that
   endpoint returns 404. `prerelease` means *unfinished software*; this build is finished
   and merely unsigned, and every surface says so in words.
5. The site and README link to the DMG asset URL
   (`releases/download/v<version>/Cliphoard-<version>.dmg`), never `releases/latest`.
6. The Homebrew tap is deferred to the first notarized release; the cask keeps its
   placeholder sha256 until then.

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

## Public website

`docs/` is served as static assets by the `cliphoard-site` Cloudflare Worker at
`https://cliphoard.dev` and `https://www.cliphoard.dev`. Static requests use
Cloudflare's free asset hosting; there is no server code, licence secret or checkout
service in this deployment. `docs/.assetsignore` excludes the GitHub CNAME and design
notes. GitHub Pages retains the older project URL's custom-domain handoff.

After reviewing and testing site changes, use the scoped Cloudflare credential from
the approved secret store in the process environment, then run
`bash Scripts/deploy-site.sh`. The script pins Wrangler, disables its metrics and
local logs, and uses `wrangler.site.json`. Never put the token in a command argument,
repository file or release log. Verify the public pages, assets, HTTPS and appearance
after deployment; a Git push alone does not deploy the Cloudflare site.

Keep installer links and trust claims tied to the exact public, customer-tested
artifact. Keep purchase links disabled until their checkout and licence delivery pass
an end-to-end test. Publish only reconciled net-sales reports to `docs/data/net-sales.json`;
missing reports remain unavailable rather than zero.
