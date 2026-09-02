# Cliphoard — Release Readiness Status

**Last updated:** 2026-08-12 · **Branch:** `rename/cliphoard`
**Verdict: NOT-READY for wide distribution — gated only by human-only steps.**
**Local install currently FROZEN — see [`PUBLICATION.md`](PUBLICATION.md) before doing anything.**

The codebase is release-quality. What stands between here and a public v1.0 is **not
code**: it is an Apple Developer ID certificate, a published Homebrew tap, and a
signed+notarized DMG — none of which an automated agent can produce. See the
[Dimensional readiness re-audit](#dimensional-readiness-re-audit-2026-07-02) below and
[`AUDIT.md`](AUDIT.md) for the confirmed engineering findings.

> This supersedes the original pre-hardening assessment. The P0/P1 backlog that used to
> live here has been resolved across the harden, optional-backlog, staircase, and
> ship-safe-hardening passes; the historical findings are in `AUDIT.md`.

## Signing note added 2026-08-08 — read before cutting a release

`Scripts/Cliphoard.entitlements` now requests `keychain-access-groups`, which moves the
encryption keys into the **data-protection keychain**. That keychain has no ACLs and
therefore never needs to prompt, which matters more than it sounds:

The legacy keychain prompts whenever a binary not on an item's ACL reads it. When no
prompt can be shown — the app relaunched by a script, the Mac in dark wake, a laptop lid
closed — the read fails. On 6 and 8 August that failure was mistaken for "no key exists"
and answered by minting a replacement **over the live key**, orphaning 202 clips and then
8 more. The mint path is now reachable only from a genuine `errSecItemNotFound`, and the
recovery ring (which had silently been carrying one key) works. But the entitlement is
what stops the situation arising at all.

**It only takes effect when signed with a real team identity.** A self-signed local build
gets `errSecMissingEntitlement` (-34018) and falls back to the legacy keychain, which is
why that fallback is load-bearing rather than a nicety. So:

- Cut releases with `Scripts/release.sh` (it passes `--entitlements`), **not**
  `Scripts/build-app.sh`, which does not.
- After the first signed build, confirm the debug log shows keys resolving with no
  `DARK WAKE` or `-34018` lines. `defaults write io.antreas.cliphoard debugLog -bool YES`.


## Local-install incident, 2026-08-08 → 2026-08-12 — read before running anything

The maintainer's own install is in safe mode and the test suite is temporarily unrunnable
without a dialog storm. Neither is a defect in the shipping product; both are worth reading
because the fixes are in this branch.

- **The store is frozen, and the store is fine.** 84 of 93 clips decrypt. `db-canary-v1` — a
  single sentinel item — was sealed on 2026-08-08T11:34:55Z during a dark-wake launch under
  an ephemeral session key (fingerprint `bc5c6b58`, present in exactly one line of the debug
  log and never seen again). The freeze is the app correctly refusing to touch data it cannot
  verify. **Nine clips are permanently unreadable**; their key does not exist.
- **The test target was writing to the real keychain.** `Crypto.service` was one constant
  shared by the app and `swift test`, and keychain items are keyed by service *across
  processes* — so the suite inherited write access to production secrets. 20 junk
  `db-archived-key-unit-test-key*` items accumulated in a live login keychain, each carrying
  an ACL for a test binary whose code identity is gone, hence one confirmation dialog per item
  per launch. Fixed in `1c624d4` (per-process namespace, conjunction-guarded, plus a
  start-of-run sweep).
- **Recovery has an ordering constraint**, documented in `PUBLICATION.md`: the app must be
  rebuilt from HEAD *before* the canary is cleared. The installed binary was built
  2026-08-08 12:34 from an uncommitted tree and predates the ephemeral-key guards.

## Test + build state

- `swift build` clean. `swift test` → **442 tests, 0 failures, 28 skips** as of `ceac8d6`
  (2026-08-08, lid closed). **Not re-run since `1c624d4`** — on a machine with the junk keys
  still present it raises a keychain dialog per archived key. Run it after the cleanup in
  `PUBLICATION.md` §2, and expect three tests marked VERIFY-WHEN-AWAKE to need a supervised
  pass.
- A run with the lid OPEN is the one that matters: 26 of the 28 skips are keychain-gated, so
  a green lid-closed suite is necessary and not sufficient.
- On-device model path (ogma CoreML) proven cert-free in CI (`.github/workflows/models.yml`),
  conversion stack pinned (`torch==2.7.1`, `coremltools==9.0`, `numpy<2`).

## ✅ Done (release-quality)

- **At-rest encryption.** Clip text/RTF/paths/color and image payloads+thumbnails are
  AES-GCM sealed (`enc1:` marker); key derived from a Secure-Enclave-bound P-256 key with
  a random-Keychain fallback. The key is now bound `…ThisDeviceOnly` (non-migratable).
  Embedding vectors **and** tags are now sealed at rest too (legacy plaintext rows still
  load). The Yank→Cliphoard upgrade path no longer leaves a plaintext `history.migrated.json`
  / `history.corrupt.json` — both archives are sealed.
- **Secret-capture filtering.** Honors `excludedBundleIDs` + `org.nspasteboard`
  Transient/Concealed/AutoGenerated; logs record only kind + UTI, never content; no
  network egress anywhere.
- **Signing/notarization/DMG pipeline — correct as code.** `Scripts/release.sh` +
  `.github/workflows/release.yml` do Developer ID + Hardened Runtime + `--timestamp` +
  entitlements + `notarytool submit --wait` + `stapler` on app and DMG. Produces a
  Gatekeeper-trusted artifact the moment a real cert exists.
- **Accessibility baseline.** VoiceOver labels/traits on interactive surfaces, focus-on-
  summon, full keyboard model, visible focus ring.
- **Correctness/perf.** Degenerate-embedding rejection, results memoization, incremental
  tag index, Float16 `loadUnaligned`, vDSP cosine; **tokenizer Viterbi now bounded**
  (O(n·maxPieceChars), input capped) so a large/whitespace-free clip no longer hangs the
  main thread; **DB transactions roll back** on a failed step.
- **Hybrid tagging + clip supercard.** Automatic classification now combines four
  confidence-gated semantic axes with topical labels instead of forcing a fixed top-5.
  Per-clip user tags are normalized, indexed, searchable, filterable, and sealed at
  rest. The detail supercard exposes content, metadata, automatic facets, and user-tag
  editing without sending clip data off-device.
- **Rebrand + legal.** Product surface fully Cliphoard; attribution consistent
  across `LICENSE`, `LICENSE-Apache-2.0.txt` and `THIRD-PARTY-NOTICES.md`. Every
  component is permissive; OpenVision (Apache-2.0) is the only bundled model. There is
  no in-app About licence screen — the texts ship as files in `Resources`. Bundle id
  `ai.axiotic.ditto` and the `yank.db.v2` KDF salt are deliberately unchanged (Keychain
  scoping + decryption of existing at-rest data).

## 🔴 Human-only blockers (the actual critical path)

1. **Apple Developer ID Application certificate** + the 7 CI secrets (`MACOS_CERT_P12`,
   `MACOS_CERT_PASSWORD`, `KEYCHAIN_PASSWORD`, `MACOS_DEVID`, `APPLE_ID`, `APPLE_TEAM_ID`,
   `APPLE_APP_PASSWORD`). Everything downstream depends on this.
2. **Publish the Homebrew tap** — create/push `github.com/AntreasAntoniou/homebrew-tap`;
   the cask lives only in-repo (`Casks/cliphoard.rb`) until then.
3. **Cask sha256** — written by the first tagged release (`release.sh` rewrites `Casks/cliphoard.rb` from the notarised DMG; `release.yml` commits it), then `Scripts/publish-cask.sh` copies it into the tap. Not hand-filled.
4. **VoiceOver hardware pass** + final rendered **WCAG AA** contrast sign-off across the 16
   themes — cannot be verified from source.

## 🟡 Deferred agent-fixable (not blocking; larger-risk, left for a dedicated pass)

- Move CoreML inference off `@MainActor` (batch reindex/reclassify + per-keystroke
  re-embed) — an architectural refactor deliberately not done right before release.
- Full a11y: honor Reduce Motion / Reduce Transparency, tune per-theme contrast tokens,
  make the VoiceOver cursor follow keyboard selection, adopt Dynamic Type.
- Minor: batch the one-time re-key insert loop, cosmetic `design/icons/manifest.json`
  rebrand.

## ✅ Resolved in the 2026-07-24 launch-QA pass

- **Encrypt-at-rest is now fail-CLOSED.** Added `Crypto.sealStrict` (sealed-or-nil,
  never plaintext). All content-write paths use it: `Database.insert` refuses the whole
  row if any content column can't be sealed; `upsertEmbedding` skips rather than store an
  unsealed vector/tags; the legacy-history archive (`history.migrated.json` /
  `history.corrupt.json`) only writes — and only deletes the plaintext original — once a
  sealed copy exists. Regression tests: `CryptoTests.testSealStrictIsAlwaysSealedNeverPlaintext`,
  `DatabaseTests.testClipContentColumnsAreSealedAtRest`.
- **Model downloads are now checksum-pinned.** `ModelAssets` verifies each downloaded
  `<name>.zip` against a pinned SHA-256 (GitHub's server-computed asset digests) before
  unpacking/compiling; a mismatch deletes the temp and refuses to install. Defense-in-depth
  over GitHub-TLS. Update `ModelAssets.expectedSHA256` when adding a model to the release.
