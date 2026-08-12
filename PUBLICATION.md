# Cliphoard — Publication Guide

**Written 2026-08-12, overnight, while you slept.** Everything in here is either a thing
only you can do, or a thing I deliberately did not do without you watching.

Nothing in this guide was executed. No keychain item was created, read-with-a-prompt, or
deleted. The running app was not launched, quit, or touched. All the code changes below are
source-only and compile; **the test suite was not run**, for a reason given in §5.

---

## 0. Read this first — the one-paragraph state of the world

Your store is **not damaged**. The overwhelming majority of clips decrypt fine; the app is
frozen because a single sentinel keychain item (`db-canary-v1`) cannot be opened, and the app
correctly refuses to touch anything it cannot verify.

**Do not use a fixed clip count as your success criterion.** The store held 93 rows when the
banner was screenshotted, 103 by 02:00, and it is **still growing** — the installed binary
predates "stop writes in safe mode" and keeps writing (§1). Judge success by *the banner
clearing*, not by a number.

**The sentinel is unrecoverable, and that much is proven.** Your complete 23-key ring was
built on 2026-08-11 with **every archived key read successfully** — zero `archived key …
unreadable` lines in the whole log — and it opens neither the canary nor the unreadable
clips. There is no key to find, so clearing the sentinel costs nothing.

**What sealed it is *not* fully proven, and the guide previously overstated this.** Two
candidate events:

- **2026-08-08T11:34:55Z**, a dark-wake launch that read all three keychain items as
  unavailable and wrote the canary anyway, under a lone session key `bc5c6b58` — a
  fingerprint appearing in exactly one line of your log and never again.
- **2026-08-08T17:19:26Z**, which is the canary's *actual* keychain modification date. Nothing
  in the app's log covers it (the log is silent from 11:39 until Aug 10), and `CHRONICLE.md`
  records a blocked `swift test` at 17:15Z — three minutes earlier. Two other keychain items
  were written unlogged in the same window.

The second is the likelier author, and if so it is **a test process overwriting the app's
canary** — exactly the defect §3 row 2 fixes. Later launches ran the same migrate-forward code
and did *not* bump that date, so 17:19:26Z was a real content write by a process holding a key
that is not among the 23.

**Either way the conclusion is identical:** the sealing key is gone and clearing is the only
recovery. Some clips are permanently unreadable and no code change recovers them; at least one
is dated 2026-08-08 11:35:46.

---

## 1. THE HARD PRECONDITION

> **Do not delete `db-canary-v1` unless `/Applications/Cliphoard.app` was rebuilt from
> current `HEAD` in the same sitting.**

This is not housekeeping. The app you are running was built on **2026-08-08 12:34** from a
working tree that was **never committed**. Provably, in both directions: `HEAD`'s own strings
`FAILED in both keychains` and `no future launch prompts for it` appear **zero** times in that
binary, while the binary's `future launches need no prompt` appears in **no commit up to and
including `ceac8d6`**. (It now appears in `1c624d4` — inside a doc comment quoting the old log
line — so run that grep against `ceac8d6`, not `HEAD`, or it looks like a match.) Seven crypto
commits land after the build.

That binary predates the guards that make recovery safe. Clearing the canary against it
re-runs pre-guard code: one dark-wake launch or one cancelled dialog mints another ephemeral
key, seals a fresh canary under it, and **reproduces this exact incident**. It also predates
"stop writes in safe mode", so an *unfrozen* stale binary is the one configuration where the
re-seal risk is genuinely live.

Deploy and clear in **one maintenance window, back to back.** There is no reason to separate
them: the guard ships *in* the binary you install, so the precondition is satisfied the
moment it lands.

---

## 2. The recovery, in order

Steps marked **PROMPT-SAFE** cannot raise a keychain dialog. The others can — do them awake,
with the lid open.

### Step 1 — Back up. PROMPT-SAFE.

```bash
B=~/Desktop/cliphoard-backup-$(date +%Y%m%d-%H%M%S); mkdir -p "$B"
cp -a ~/Library/Application\ Support/Ditto "$B/Ditto"
cp -a ~/Library/Keychains/login.keychain-db "$B/"
cp -a ~/Library/Preferences/io.antreas.cliphoard.plist "$B/"
sqlite3 ~/Library/Application\ Support/Ditto/ditto.sqlite ".backup '$B/ditto-consistent.sqlite'"
sqlite3 "$B/ditto-consistent.sqlite" 'PRAGMA integrity_check; SELECT count(*) FROM clips;'
```

**Do not proceed unless that prints `ok` and a row count.** This captures every clip's
ciphertext verbatim plus the image bytes, needs no key and no canary, and is a strict
superset of what the in-app archive tool would produce.

> The obvious alternative — `--archive-unreadable` — **does not work right now.** It refuses
> on `!decryptionHealthy` and prints "cannot reach the keychain", which is false: the
> keychain is reachable, the canary is poisoned. Fixing that is a follow-up, not a blocker.

### Step 2 — Quit Cliphoard.

```bash
osascript -e 'tell application "Cliphoard" to quit'
```

### Step 3 — Build and install from HEAD. NOT PROMPT-SAFE (the build is; the first launch isn't).

```bash
cd ~/Projects/ditto
git status --porcelain          # confirm you know what is in the tree — see §1
bash Scripts/build-app.sh
bash Scripts/deploy-local.sh
```

**This is the step that must not be reordered.**

### Step 4 — Delete the 20 test-written keys. Keychain Access, NOT the CLI.

Open **Keychain Access.app** → *login* → *All Items* → search `db-archived-key-unit-test-key`.

- Confirm the result list shows **exactly 20 rows**.
- Confirm **no row's name contains `se-v2`**.
- Select all → Delete → one authorization.

A multi-select delete costs one authorization; a shell loop costs twenty separate prompts.

> **Delete by exact NAME, never by fingerprint.** Two keys on your ring have fingerprints
> `a36acd73` and `b092b7a8` — one is the bare `db-archived-key-se-v2`, the other the bare
> `db-archived-key-unit-test-key`, and **the log does not say which is which.** Telling them
> apart needs a data read, which needs a dialog. One of them is plausibly the key that took
> your store from 0/80 to 79/80 readable.
>
> Also: the bare `db-archived-key-unit-test-key` (no fingerprint suffix) **is one of the 20**
> and is easy to miss in a suffix-oriented scan. The existing test teardown could never
> remove it — it builds its account name as prefix + fingerprint.

**NEVER DELETE:** `db-se-key-v2` · `db-key-v1` · `db-archived-key-se-v2` ·
`db-archived-key-se-v2-dfad2631616b9165`

### Step 5 — Delete `db-canary-v1`. NOT PROMPT-SAFE. **Your call — see §4.**

Keychain Access → search `db-canary-v1` → confirm **exactly one row** → Delete.

### Step 6 — Relaunch and confirm.

Expect **at most 5 prompts**. Click **Always Allow** on each — your app is signed with the
stable `Ditto Local Signing` identity, so this is once, not per launch.

```bash
grep -E "SAFE MODE|keyring built|recovery ring|canary" \
  ~/Library/Application\ Support/Cliphoard/debug.log | tail -8
```

**Success looks like:** no new `SAFE MODE` line and the banner gone. Do **not** check for a
particular clip count — the store is still growing, and a stale number is exactly what would
make a correct recovery look like a failure at the moment you are deciding whether to trust it.
The still-sealed rows should keep their original kinds (that is what the `repairKinds` guard is
for).

**If `SAFE MODE — the startup canary did not open` reappears:** stop. The replacement canary
was written under a key that did not survive. Nothing has been re-sealed, your backup is
intact, and the machine was degraded at that moment — retry awake, lid open.

**If it says `canary absent AND the key is ephemeral`:** the guard did its job. Stop, change
nothing, and we diagnose. That message existing at all is one of tonight's fixes.

---

## 3. What changed in the code tonight

All source-only. Undo everything with `git checkout -- Sources/ Tests/`.

| # | Change | Why |
|---|---|---|
| 1 | `ClipStore.repairKinds` skips sealed rows | **Highest value.** It re-derives a clip's kind from `item.text` — which for an unreadable row *is* the `enc1:` string — and writes the answer to disk. It runs *after* the safe-mode return, so it fires on the **first healthy launch**: the instant you clear the canary. It would silently rewrite a link or a colour to `.text`, permanently, on exactly the rows already hurt. |
| 2 | `Crypto.service` resolves per-process | The root cause. One constant shared by the app and `swift test`, and keychain items are keyed by service *across processes* — so the suite inherited write access to your real secrets. Now requires a **conjunction** (XCTest loaded **and** bundle id not ours), so a shipping build reaching the test namespace needs two independent failures. `#if DEBUG` was rejected concretely: `build-app.sh` accepts `debug` and produces an installable app. |
| 3 | Per-run test namespace + start-of-run sweep | A *fixed* test service still accumulates items from successive test binaries with dead code identities — the trap relocated. The sweep hangs off the one-time service resolution, because SwiftPM offers no bundle-start hook and an opt-in `setUp` is the same discipline that already failed. |
| 4 | `archiveKey` refuses to write to production from a test | Orthogonal to (2): that catches a *resolution* anomaly, this catches a *caller* anomaly. Logs and returns rather than trapping — a crash would convert a contained inconsistency into a lost session. |
| 5 | `keychainAccessDenied` set for **every** unavailable read | It was a hand-maintained list of three OS status codes. `errSecUserCanceled` (-128) wasn't on it — a user pressing Cancel, which appears twice in your log. The banner said the wrong thing and the test helper failed instead of skipping. |
| 6 | `storeBlob` returns *where* it landed; one derived log | A `Bool` cannot distinguish "stored in the prompt-free keychain" from "stored in the legacy one" — both are success, and telling them apart is the entire purpose of the migrate-forward path. Your stale binary logged "future launches need no prompt" immediately after that write **failed**. |
| 7 | New `migrateForward` — data-protection only, no fallback | The source is already in the legacy keychain, so a fallback there rewrites the item **onto itself**, per account, per launch, forever. |
| 8 | `dataProtectionUnavailable` latches on **any** DP refusal | It only latched on one status, so any *other* failure left it false and re-armed (7). |
| 9 | Keyring split into `primaryRing` + lazy `archivedRing` | Archived keys are read only after the current and legacy keys have both failed on real ciphertext. Your log shows 3–5 second gaps between consecutive archived reads — you, clicking dialogs — to open a canary the current key would have opened first. |

**Deliberately NOT changed:** prompt suppression was not added at all — it stays exactly as it
is today, because the API it would rely on is unverified on this OS version (§5); the ring is
never capped or pruned (a cap silently drops the one key an old row needs); `ModelAssets` still
writes to your real store dir under a test — logged, not fixed.

**Known latent gap, not live on your machine.** Three other init-time passes —
`backfillDetectorFlagsIfNeeded`, `encryptExistingRowsIfNeeded`, `reKeyToSecureEnclaveIfNeeded`
— also derive from `item.text` and rewrite rows, and did **not** get the guard from row 1. On
your Mac all three are one-shot and already spent (`detectorBackfillV1`, `dbEncryptedV1`,
`reKeySEv2` are all set), so your recovery is unaffected. It matters for a fresh install or if
those defaults are ever reset.

---

## 4. Two decisions that are yours

**D1 — Clear `db-canary-v1`?** *Recommended, strictly after Step 3.* The evidence for
*unrecoverability* is as strong as it gets, and it does not depend on knowing which event
sealed it: your complete 23-key ring was assembled with every archived key read
**successfully**, and it opens neither the canary nor the sealed rows. It is ciphertext under a
key that no longer exists. Clearing it loses nothing except the forensic artifact that caught
the incident — which is the only reason this is a question at all.

**D2 — Accept the 9 clips as permanently unreadable?** Their key does not exist. No code
change recovers them. The Step 1 backup preserves their ciphertext indefinitely against a key
that will not arrive. This is a data decision, not an engineering one.

---

## 5. Before you run the test suite

**Do not run `swift test` until the fixed binary is deployed and the junk keys are gone** —
on the current state it will prompt you again.

**There is a second, larger prompt hazard nobody has resolved.** Your login keychain holds
**133 stale test services (266 items)** under `io.antreas.cliphoard.tests.`, left by
`KeyringRecoveryTests` across runs on 2026-08-08. The new start-of-run sweep will issue **133
`SecItemDelete` calls** on the first `swift test`. Whether a legacy-keychain delete raises an
authorization dialog is **untested** — it could not be tested without risking exactly the
dialog storm this work exists to stop. Settle that before you type `swift test`: delete those
services via Keychain Access first (search `io.antreas.cliphoard.tests`, multi-select, one
authorization), or accept that the first run may prompt.

Nine tests were added tonight, all pure — they assert decisions, never the keychain, so none
can raise a dialog. What is **not** covered, stated plainly rather than left to be discovered:
nothing asserts the lazy-ring split (`archivedReadCount` exists and has no consumer), and
nothing exercises the sweep. Both need a supervised run.

One unverified assumption: nobody has confirmed that
`SecKeychainSetUserInteractionAllowed(false)` still suppresses legacy ACL prompts on Darwin
25.6. Nothing here depends on it.

---

## 6. Publication blockers — unchanged, human-only

These are the actual critical path to v1.0, and none of them is code:

1. **Apple Developer ID Application certificate**, plus the 7 CI secrets (`MACOS_CERT_P12`,
   `MACOS_CERT_PASSWORD`, `KEYCHAIN_PASSWORD`, `MACOS_DEVID`, `APPLE_ID`, `APPLE_TEAM_ID`,
   `APPLE_APP_PASSWORD`). Everything downstream waits on this.
2. **Publish the Homebrew tap** — `github.com/AntreasAntoniou/homebrew-tap`. The cask exists
   in-repo at `Casks/cliphoard.rb`.
3. **Fill the real DMG `sha256`** into that cask — currently an all-zero placeholder, and
   `Scripts/release.sh` correctly refuses to cut a release while it is.
4. **VoiceOver hardware pass** + rendered WCAG AA contrast sign-off across the 16 themes.

**A signing note that matters more after this week:** `Scripts/Cliphoard.entitlements`
requests `keychain-access-groups`, which moves the keys into the data-protection keychain —
the one with no ACLs, which therefore never prompts. **It only takes effect when signed with
a real team identity.** Every `storeBlob` in your log returns `-34018` because a self-signed
build cannot carry it. A notarised release makes this entire class of incident structurally
impossible. Cut releases with `Scripts/release.sh` (it passes `--entitlements`), never
`build-app.sh`.

---

## 7. Follow-ups, logged not started

- `TagAudit`'s keychain guard refuses the non-destructive dry run — same defect shape as the
  completeness guard fixed earlier, through a different disjunct.
- `ModelAssets.storeDir` writes to the real Application Support under a test.
- The xctest `UserDefaults` domain persists between runs, so one run's migration markers
  decide the next run's behaviour. (It does **not** reach the app — verified.)
- Move CoreML inference off `@MainActor`; the deferred a11y work in `STATUS.md`.
