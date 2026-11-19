# Windows private beta handoff — 1.2.14.0

Prepared 19 November 2026. Nothing has been published, uploaded or sent to testers.

## Handoff artifacts

The local directory `ports/artifacts/windows-beta-1.2.14` contains separately labelled ARM64 and x64 tester ZIPs. Each kit contains only its MSI, installation instructions, release notes, known issues, a test checklist, a bug-report template, the MIT licence and SHA-256 checksums. MSIX, model weights, test executables, clipboard databases, archives, owner settings and diagnostic logs are excluded.

Use `SHA256SUMS.txt` beside the ZIPs to verify the outer kits. Each ZIP contains its own checksum list covering the installer and documents. Send the relevant checksum through the organiser's trusted channel along with the matching architecture kit. A checksum does not establish publisher identity.

`release-manifest.json`, `source-inventory.json` and `source-snapshot.tar.gz` remain internal. The snapshot retains the uncommitted Windows source, asset generators, beta documents and preparation script without representing the base commit as the final release source. It contains no repository authentication state or VM user profile.

## Current qualification

| Check | Result |
| --- | --- |
| ARM64 core fixture benchmark | 23 suites, 860 checks, zero failures |
| x64 core fixture benchmark under ARM64 emulation | 23 suites, 860 checks, zero failures |
| Distribution parser and synthetic offline-signature fixture | 18 checks passed; no publisher signing established |
| Release test-only flags, both architecture payloads | All four refused with exit 78 |
| ARM64 installed upgrade | 960 files match; four history-file hashes retained |
| MSI ICE / MSIX structural validation | Both architecture packaging runs passed |
| Authenticode, both MSI and app executables | NotSigned |
| Source whitespace checks and Python syntax | Passed |
| Search retrieval quality | 41 expectations failed across 432 queries; disclosed |

Evidence is retained in `ports/tests/results/windows-benchmark-1.2.14-20261119.json`, `windows-install-1.2.14-20261119.json` and `windows-beta-*-20261119.json`. The benchmark is not an exhaustive end-to-end user acceptance test.

## Before wider release

Trusted publisher signing is outstanding. No ad-hoc trust certificates were generated or installed, and no Windows security protections were changed. Signed builds will need new checksums and refreshed package/installation receipts; do not relabel these unsigned artifacts as signed.

Native Intel/AMD testing, fresh-profile installation/uninstall, successful Windows Hello reveal, and the documented search quality gaps remain qualification work. Beta feedback is manual; no tester address, tracker, support channel or external upload destination has been invented.

## Recreate the local kits

Keep the two approved MSI files in their architecture directories. Use Python 3.13 or newer:

```sh
/opt/homebrew/bin/python3.14 ports/beta/prepare-beta.py ports/artifacts/windows-beta-1.2.14
```

The script verifies pinned installer hashes and refuses existing kit outputs. Choose a fresh artifact directory and copy the approved MSI files into it when rebuilding the handoff. Guest package fetches use `ports/tests/fetch-guest-artifact.py` with mandatory hashes and bounded read-only retries; VM shared folders remain disabled.

## GitHub source snapshot

The source publication branch is `codex/windows-beta-1.2.14`. GitHub push protection rejected the original unpublished history because a synthetic vendor-token detector fixture contained a key-shaped literal. The golden fixture now uses a placeholder and constructs harmless test material at runtime; all 70 detector parity checks passed after a clean guest rebuild. Production detector behavior and the prepared installer binaries are unchanged. The publication snapshot retains the current source tree while leaving the original local development history intact. Installer ZIPs remain separate local artifacts; source publication does not create a GitHub Release or publish a download.
