# Cliphoard activity counters

The Mac app has no usage telemetry. The website and purchase service have optional,
first-party aggregate counters. Source is public; reports and provider credentials
stay private. `Scripts/telemetry-report.py` reads counts; it never changes provider state.

## What is measured

| Signal | Source | Meaning and limit |
|---|---|---|
| Installer downloads per release | GitHub Releases asset `download_count` | DMG requests, including repeats, bots, Homebrew and QA; not unique people or installs |
| Page views, Free clicks, Pro interest | Website events | One event per placement per page load; opt-outs/ad blockers excluded; intent is not purchase |
| Feature disclosures, source/support/privacy/research/sponsor links | Website events | Fixed event and placement names only |
| Referral group, country | Coarse classification | No raw referring URL or search terms; small country groups combined in report |
| Checkout created, licence issued | Saved order transitions | Repeated calls do not ordinarily repeat transition events; analytics is best effort, not an accounting ledger |
| Claim ready | Purchase service | Successful recovery requests, not distinct customers |
| Email attempts, failures, acceptance, exhaustion, manual retry | Purchase service | Acceptance is not inbox arrival; retry may send the same key again |
| Payment blocked | Purchase service | First tombstone from refund/dispute handling; not a completed-refund count |
| Route success, rejection and server error | Purchase service | Only fixed route categories, no URL/query/error text; paused checkout requests can produce expected errors |

No app launches, clipboard operations, search queries, application names, filenames,
licence values, email addresses, payment data, raw IPs, user agents, cookies, visitor
IDs or fingerprints are written to the analytics dataset. This does not replace
the separate transaction records required to fulfil and support purchases.

## Storage and collection

Cloudflare Analytics Engine dataset: `cliphoard_metrics_v1`; binding: `METRICS`.
`blobs` are schema, surface, mode, event, placement, referral group, country.
`double1` is 1. `index1` is surface:mode. Modes `live`, `test` and `qa` are always
reported separately. Query totals with `SUM(_sample_interval * double1)`.
Cloudflare may sample; do not use these counts to reconcile money or licence rights.

`/__events` accepts same-origin JSON at the two Cliphoard hostnames, an exact schema,
at most 512 bytes, and a one-second body deadline. A dedicated transient edge rate
limiter admits at most 30 events per minute per hashed source IP. Hashes never go
into analytics. Verified bots and DNT/GPC are ignored. Browser events contain no
URL or persistent storage. No external JS or pixel is loaded. The site remains
usable when metrics fail. Server payment outcomes also survive analytics failures.

The client intentionally does not run on local previews or the separate
`antreas.io/cliphoard/` mirror. That mirror is not counted until it receives an
explicitly reviewed deployment and endpoint design. Website private specs are
excluded from Cloudflare static assets by `.assetsignore`.

## Reading the dashboard

Use verified Python 3.14+ and pipe the existing Cloudflare token from the approved
secret broker directly into this command. Never paste a token into a shell command,
file, chat, or an interactive stdin prompt.

```
/absolute/python3.14 Scripts/telemetry-report.py --cloudflare-token-stdin --days 30 --output /private/report-folder
```

The caller owns the secret pipe; the report has no vault-discovery or unlock logic.
It produces timestamped private JSON/HTML snapshots, including GitHub baseline
counts, and atomically updates private `latest.json` and `latest.html` entry points.
Keep the latest HTML bookmarked; reload after a refresh. Subtract successive
per-asset snapshots for download growth. A decrease or
an asset replacement requires reconciliation, not a negative-download claim.
Analytics records expire after three months; retain daily aggregate snapshots for
longer history. No historical website click counts can be reconstructed.

The existing launch heartbeat can refresh once per UTC day using a valid normal
lease, and stay quiet when unchanged. Notify new live delivery exhaustion, live
webhook server errors, or a newly unavailable source. Compare previous alerts to
avoid repeating the same failure. Do not wake the owner for an analytics-only unlock.
Apple App Store downloads/sales still require Apple reporting and are not in this
dashboard. Local app adoption, retention and feature use remain unknown; any future
app diagnostics need a separate opt-in design and an updated app release.

## Verification

- Node: `node --test Tests/site/test_telemetry.mjs commerce/test/stripe-metrics.test.mjs`
- Python 3.14+: `python -m unittest discover -s Tests/site -p 'test_telemetry_report.py'`
- Preserve existing Stripe, rendered-page and workerd suites when changing commerce.
- Browser QA uses `?metrics=qa`. API QA posts only mode `qa`; do not fake live sales.
- Confirm events with Analytics Engine SQL, not only an HTTP 204 from ingestion.
- Private dashboard snapshots are never uploaded to the website.

References: [Analytics Engine SQL](https://developers.cloudflare.com/analytics/analytics-engine/sql-api/),
[sampling](https://developers.cloudflare.com/analytics/analytics-engine/sampling/),
[retention and limits](https://developers.cloudflare.com/analytics/analytics-engine/limits/),
[GitHub release assets](https://docs.github.com/en/rest/releases/releases).
