# `tools/funding` — publishing the net-sales figure

The funding section of [cliphoard.dev](https://cliphoard.dev/#funding) shows one number:
**provider-reported net sales proceeds since the campaign start, in US dollars**, against
a **US$250,000** goal. This directory is how that number gets there, and the short
version is that it gets there by hand, deliberately.

Every amount in this document and in the published file is **US dollars**. The business
is UK-registered, so a bare `$` would not say which dollar.

```
two private files, outside the repo         this tool          the one public file
  scope.json        (who we are)       ─ validates ─▶     docs/data/net-sales.json
  reconciliation.json (what sold)      ─ sums ──────▶     (aggregate only, no ids)
                                       ─ refuses ───▶     previous file untouched
```

```sh
# validate and print, writing nothing
/opt/homebrew/bin/python3.13 tools/funding/publish_net_sales.py \
    --scope  ~/private/cliphoard/scope.json \
    --input  ~/private/cliphoard/reconciliation-2026-12.json \
    --output docs/data/net-sales.json \
    --campaign-start 2026-11-01 \
    --dry-run

# publish
/opt/homebrew/bin/python3.13 tools/funding/publish_net_sales.py \
    --scope  ~/private/cliphoard/scope.json \
    --input  ~/private/cliphoard/reconciliation-2026-12.json \
    --output docs/data/net-sales.json
```

Python 3.13+, standard library only. Commands below use the verified
`/opt/homebrew/bin/python3.13`; select and verify an equivalent 3.13+ interpreter on
another machine. The publisher refuses older runtimes. No packages to install, network
access, credentials or provider API keys are needed.

## This is not a provider integration, and the tests do not say it is

There is no Apple or Stripe Managed Payments client in this directory, no HTTP call of any kind,
and no invented endpoint. The reconciliation files are produced **by hand** by the
operator from provider settlement records, following the steps below. **A passing test
suite here says nothing whatsoever about any external sales provider** — what it tests is
the validator standing between a hand-reconciled private file and a public number.

The combined, product-scoped figure requires manual reconciliation across both providers.

**Apple.** Proceeds are what Apple pays after its commission, and the authoritative
numbers come from the monthly **financial reports**, not from Sales and Trends, which
Apple describes as estimates. See
[View payments and proceeds](https://developer.apple.com/help/app-store-connect/getting-paid/view-payments-and-proceeds/)
and the
[financial report field reference](https://developer.apple.com/help/app-store-connect/reference/reporting/financial-report-fields/).
The monthly cadence is also why a figure more than 45 days past its `as_of` is labelled
as not current rather than presented as live.

**Stripe Managed Payments.** Use the itemized
[Balance Change from Activity](https://docs.stripe.com/reports/balance) report for the
chosen accounting period; reconcile it against
[Payout Reconciliation and Ending Balance Reconciliation](https://docs.stripe.com/reports/payout-reconciliation)
without counting those same transactions again. A payout transfer is not another sale.
Retain the originals, report period/time zone, currency, transaction IDs and the private
product/price crosswalk. Financial report amounts are in major currency units; do not
interpret them as API integer cents. Keep each currency separate until the documented FX
step below. Scope the rows to the verified account and approved product/price pairs.

Request `withheld_tax` and `fee_net_of_withheld_tax`. Stripe documents that `fee` already
includes withheld tax. Normalize tax into `customer_tax` and fees excluding that tax into
`fees`; **never subtract both `fee` and `withheld_tax`**. See
[Managed Payments financial reporting](https://docs.stripe.com/payments/managed-payments/how-it-works#financial-reports).
For example, synthetic gross `120.00`, withheld tax `20.00`, and fee excluding tax `10.00`
reconcile to `90.00`; using the combined fee `30.00` would incorrectly produce `70.00`.

For the manual worksheet, use positive sales gross for `gross`, refund and dispute
principal debits for `refunds` and `chargebacks`, and positive tax/fee debits for their
deduction fields. Put separately evidenced credits, reversals and other signed
corrections in `adjustments` once. Do not deduct discounts already reflected in gross;
use `discounts: "0.00"` only when that treatment is evidenced, or reconstruct pre-discount
gross and its explicit discount together. The resulting identity must equal the scoped
sum of the provider's `net` column exactly. Missing breakdowns require reconciliation,
not guessed fees or zero-filled fields.

Only verified live Managed Payments sales belong to this channel. Retain evidence linking
report charge/payment identifiers to the configured product and price, and to Checkout
Sessions and PaymentIntents with Managed Payments enabled. The validator checks the
normalized file's shape, identities and arithmetic; it does not independently establish
that provider status or perform these joins.

Adapters that read Apple's financial report TSV and a Stripe Managed Payments payout export
directly are **remaining work**, and they are recorded as remaining work rather than
stubbed.

## The two private files

Both live **outside this repository** and the tool refuses either if it resolves inside
the checkout — a settlement or scope file committed once is in the git history
permanently, and `git rm` does not take it back out. There is no discovery anywhere in
this tool: it opens the two paths it was given and never goes looking for financial files
on its own.

### 1. `scope.json` — who we are

```json
{
  "schema": "cliphoard.net-sales.scope/2",
  "channels": [
    { "id": "app_store",
      "account": "<Apple vendor number>",
      "vendor":  "<legal entity name as Apple holds it>",
      "store":   null,
      "products": ["<the app SKU>"] },
    { "id": "stripe_managed_payments",
      "account": "acct_REPLACE",
      "vendor":  "<your legal entity name on the Stripe account>",
      "store":   null,
      "products": ["prod_REPLACE:price_REPLACE"] }
  ]
}
```

**Why this is a separate file.** The previous version of this tool read an `allowlist`
out of the report file itself, which let a report declare its own scope and then satisfy
it — a check that could never fail. Scope now comes from a document the reports cannot
touch. Both canonical channels are required.

**How the operator verifies each identity against provider records.** Do this once, when
the scope file is written, and again whenever an account changes:

| Field | Where it comes from |
| --- | --- |
| `app_store.account` | App Store Connect → *Payments and Financial Reports*. The vendor number on the financial report header must equal this value. |
| `app_store.vendor` | App Store Connect → *Business* → the legal entity name on the paid-apps agreement, and the same name on the financial report. |
| `app_store.products` | App Store Connect → the app's *App Information* → SKU. The financial report's product identifier column must be one of these. |
| `stripe_managed_payments.account` | The verified Stripe account ID, `acct_…`; retain evidence that the financial export belongs to this account. |
| `stripe_managed_payments.vendor` | Your legal entity recorded on that Stripe account, verified alongside the export's account provenance. |
| `stripe_managed_payments.store` | Always `null`. Stripe has no Lemon Squeezy store identifier. |
| `stripe_managed_payments.products` | Exact `prod_…:price_…` pairs from the Stripe product catalog, checked against the related Checkout line items. Retain the private mapping from report transaction IDs to those pairs; a product-only report column does not establish the price. |

**Both `store` fields must be `null`, in the scope and each report.** Any store value is
rejected without echoing it. Stripe account IDs and product/price pairs also require the
provider's identifier shape. The public and reconciliation schemas are now `/3`, the
scope schema is `/2`, and the former `lemon_squeezy` channel is rejected. Do not relabel
old Lemon Squeezy evidence as Stripe evidence; reconcile new provider records separately.

### 2. `reconciliation.json` — what sold

```json
{
  "schema": "cliphoard.net-sales.reconciliation/3",
  "campaign_start": "2026-11-01",
  "as_of": "2026-11-30",
  "currency": "USD",
  "goal": "250000.00",
  "channels": [
    { "id": "app_store", "mode": "period", "reports": [ { "...": "see below" } ] },
    { "id": "stripe_managed_payments", "mode": "period", "reports": [] }
  ]
}
```

One report looks like this:

```json
{
  "report_id": "<the provider's own report identifier>",
  "source_sha256": "<sha256 of the provider file this row was normalized from>",
  "period_start": "2026-11-01",
  "period_end": "2026-11-30",
  "currency": "USD",
  "account":  "<must equal the scope's account>",
  "vendor":   "<must equal the scope's vendor>",
  "store":    null,
  "products": ["<must all be in the scope's products>"],
  "gross": "1000.00",
  "discounts": "0.00",
  "customer_tax": "120.00",
  "fees": "264.00",
  "refunds": "50.00",
  "chargebacks": "0.00",
  "adjustments": "0.00",
  "provider_reported_net": "566.00",
  "fx": null,
  "settlement_usd": null
}
```

Get `source_sha256` with `shasum -a 256 <the provider file>`. It is the defence against
the realistic duplicate: the same provider file entered twice under two different
`report_id`s. That is caught by content, not by label, and it does not look like a
mistake in the output — it looks like twice as much progress.

Every amount is a **decimal string with exactly two places**. A JSON number is refused,
because JSON numbers are IEEE-754 doubles and this total is a public claim about a real
business. A boolean is refused for the same reason it has its own check in the code:
`isinstance(True, int)` is true in Python. Every field must be **present**, `null`
included, so that a missing one is a shape error rather than something silently compared
against `None`.

`campaign_start` is an **input**, never a constant in the code: it is the date the first
channel actually opened and the lower bound every report is checked against.
`--campaign-start` asserts it back as a typo guard. `goal` must be exactly
`"250000.00"` — the page's ruler axis is fixed markup, so the goal is not configurable,
and `"249999.99"` is a perfectly good *proceeds* figure and an invalid *goal*.

### Dates, and why `--today` is dry-run only

`today` is what bounds every future-date refusal, so an override is a way to publish a
file dated in the future or to accept reports for periods that have not happened yet.
`--today` therefore **requires `--dry-run`**: using it without one is a refusal that
writes nothing. A dry run that overrides the clock prints a loud `SYNTHETIC DRY RUN`
line on **stderr** and adds a `synthetic` field to the printed JSON, so a pasted
rehearsal cannot be mistaken for a publication.

A real publication always takes the actual UTC date, which cannot be in the future by
construction. Every date is also **parsed**, not merely pattern-matched: `2026-02-31`
matches the shape and is not a date, and it is refused as `not-a-calendar-date` rather
than raising a traceback.

### What net means here

```
net = gross − discounts − customer_tax − fees − refunds − chargebacks + adjustments
```

**Recomputed** from the components and required to equal `provider_reported_net` exactly,
in `Decimal`, with no tolerance. That one check catches a mis-keyed fee, a tax line
counted twice, and a refund entered with the wrong sign — none of which look like errors
in the output.

`adjustments` is the one signed field, which is how a late refund correctly *reduces* the
aggregate. The others cannot be negative: a negative fee is a sign error upstream, and a
sign error in `fees` inflates the published total.

It is after customer taxes, platform and payment fees, refunds, chargebacks and
provider-reported adjustments, and **before** income tax and the cost of running
anything. It is reconciled from reports, which is not the same as cash already paid out.

### Both channels, or no number

A combined total is published **only when both canonical channels have complete evidence
for the same period** — both with reports, both covering `campaign_start` through
`as_of` with no gap, both ending on the same cutoff. If either has none, the tool
publishes the unavailable payload with a null total.

The withheld channel's figure is withheld too. A reader who sees one channel's amount
beside an unavailable total will add it up themselves, and summing whichever channels
happened to report and labelling it combined cumulative proceeds is precisely the defect
this version exists to remove.

A channel with no sales in a period is **not** a channel with no reports: file the
provider's own zero report for it, and the tool records `certified_zero`. That is also
why `not_live` was removed from the schema — it asserted that a channel was closed, which
this tool has no way to know.

### Report modes

| mode | shape | summed? |
| --- | --- | --- |
| `period` | consecutive, non-overlapping, gapless periods from `campaign_start` to `as_of` | yes |
| `cumulative` | exactly **one** report spanning `campaign_start` to `as_of` | no |

Two cumulative reports for one channel are **refused, not summed** — each already
contains the other's money. Different channels may use different modes; one channel may
not mix them.

### Foreign currency

A report not in USD needs exactly one of:

* **`settlement_usd`** — the provider settled in USD and reported that amount, so that
  amount *is* the proceeds and no conversion is ours to do; or
* **`fx`** — `{from_currency, rate, source, date}`, written down at the time. The rate is
  a decimal string (a float is refused), must be positive, must name its source, and must
  be dated on or after `period_end` and not in the future.

Supplying both is refused as ambiguous; either on a USD report is refused as confused.
The native arithmetic is validated regardless, and conversion happens **once**, on the
net — converting six components rounds six times and can land a cent away from what the
provider actually settled.

## Everything it refuses

Money and range: float money · bool money · amounts without two decimal places · a
negative fee, tax, refund, discount or chargeback · an amount outside the representable
range · a channel sum or final total that overflows it · an FX product that overflows it ·
`net != provider_reported_net`.

Scope and provenance: an account, vendor, store or product outside the scope file · a
store on a channel that has none · a report with no products · a missing or malformed
`source_sha256` · the same `source_sha256` twice, even under different report ids · a
duplicate `report_id` · a scope file missing either canonical channel.

Coverage and dates: overlapping periods · a gap between periods · coverage that does not
start at `campaign_start` · coverage that does not reach `as_of` · partial coverage · a
period ending before it starts · more than one cumulative report per channel · a
cumulative report that does not span the campaign · a cutoff before the campaign start ·
a campaign start, cutoff, report period end or FX date in the future · an invalid or
missing `today`.

Shape and identity: any unexpected object shape, at any level · a repeated JSON key
anywhere in either file (`json` takes last-wins, so the value a reviewer reads need not
be the value the tool uses) · the wrong schema in either file · a goal other than the
published one · a reporting currency other than USD · more or fewer than the two
canonical channels · a duplicate channel · a date that matches the shape but is not a
calendar date.

Files: a private input or scope path inside this repository · a scope path equal to the
input path · an `--output` that is not `docs/data/net-sales.json`  · a private file that
is not valid UTF-8 (the decoder's own error carries the offending bytes, so it is
replaced with a code) · a `--today` without `--dry-run`.

Rejection exits `2`, prints a code and a **field path**, and leaves the previous public
file byte-for-byte untouched. Messages never echo a value, a key name or a snippet of
either file: a terminal, a CI log and a pasted bug report are all ways a settlement
figure or an account id escapes.

## The public output

Built field by field from an explicit allowlist — never by copying or filtering the
input, because a filter is one forgotten key away from publishing an account id.

```json
{
  "schema": "cliphoard.net-sales/3",
  "status": "unavailable | reported | certified_zero",
  "currency": "USD",
  "goal": "250000.00",
  "total_net": null,
  "campaign_start": null,
  "as_of": null,
  "generated": "2026-10-22",
  "basis": "…one sentence describing what the figure is…",
  "coverage": { "reports": 0, "start": null, "end": null },
  "channels": [
    { "id": "app_store", "status": "no_reports", "net": null, "as_of": null },
    { "id": "stripe_managed_payments", "status": "no_reports", "net": null, "as_of": null }
  ]
}
```

Absent, and staying absent: provider accounts, vendor names, stores, app SKUs and product
ids, order ids, customer anything, per-report ids, source fingerprints, and every raw
component of the arithmetic. There is no `label` field either — the page's channel names
come from a constant map in the renderer, so no operator-supplied string is ever copied
out.

`--output` accepts **only** `docs/data/net-sales.json`. Not "any path inside the repo": an
`--output` typo landing on `README.md` or a Swift source would be a destructive edit by a
tool nobody expects to touch them. The write is atomic — a temp file in the same
directory, `fsync`, then `os.replace` — so the page only ever sees a whole document.

## How the page reads it

`docs/assets/funding.js` re-validates the whole payload in the browser, enforcing the
same rules, before displaying anything. The publisher's guarantees end at the file, and
the file is what the browser actually receives. The rule that shapes the rest:

> **A payload that does not validate never renders as zero — and never leaves a
> previous figure on screen.**

`docs/index.html` ships the honest "No reconciled reports available." markup, with the
goal and the ruler's scale visible. The renderer only *replaces* that once a payload has
passed every check, and **resets the page back to it** otherwise. That second half is
not a nicety: declining to write is not neutral when the page is already showing
`$500,000.00`, because the previous write is still the page. So `resetFundingView` runs
for a valid `unavailable` payload, for an invalid one, and on every boot failure — no
fetch, a rejected request, a non-OK status, an unreadable body, a duplicate JSON key,
unparseable JSON and failed validation. It restores the figure and its absent styling,
the goal label, a zero-width fill, both channel rows, the neutral status and as-of
lines, and clears *and* hides the excess, staleness and coverage lines.

Duplicate JSON keys are compared **decoded**, because `"total_net"` and
`"total\u005fnet"` are two spellings of one key: `JSON.parse` resolves both and then
takes last-wins, so a scan over raw spellings would miss the second total entirely.

The rest of the display rules:

* A numeric total requires **both** channels numeric, with matching `as_of` dates,
  coverage running exactly `campaign_start` to `as_of`, and a report count that can
  account for both channels — at least one report per evidenced channel, so at least two
  under this schema.
* `$0.00` appears only for `certified_zero`, which requires positive report coverage. A
  `reported` status with a zero total is a contradiction and is refused. A certified zero
  says the reports total zero; it does not say nothing was sold.
* Monotonicity is never assumed. A negative total after refunds is a real state, shown
  with its minus sign and an empty bar.
* **The cents decide whether the goal is reached — never the rounded display.** Below
  the goal the percentage is **floored** to one decimal, so `$249,999.99` reads `99.9%`
  and cannot be promoted to a `100%` that would announce the goal met when it was one
  cent short. At or past the goal it rounds normally. The table:

  | cents | shown | goal reached? |
  | --- | --- | --- |
  | `0.00` (certified zero) | `0%` | no |
  | `0.01` | `less than 0.1%` | no |
  | `250.00` | `0.1%` | no |
  | `249,999.99` | `99.9%` | **no** |
  | `250,000.00` | `100%` | yes |
  | `250,000.01` | `100%`, excess `$0.01` | yes |
  | `500,000.00` | `200%`, excess `$250,000.00` | yes |
  | negative after refunds | `below zero after refunds` | no |

  A positive total too small to reach `0.1%` would floor to `0%`, which is
  indistinguishable from having sold nothing, so it gets its own wording. A negative
  total has no sensible reading as a percentage of a goal, so it is described instead.
* Past the goal, the visual track caps at 100% while the percentage itself is allowed
  over it, and the exact excess is stated to the cent.
* The goal is `250000.00` in both implementations, checked in both.
* Cents are never dropped. `$249,999` next to a goal of `$250,000` is a different claim
  from `$249,999.99`.
* A figure more than 45 days past its `as_of` is still shown, labelled with its own
  last-verified date and explicitly not current.

## Tests

```sh
/opt/homebrew/bin/python3.13 -m unittest discover -s Tests/site -p 'test_*.py'   # publisher + page
/usr/local/bin/node --test Tests/site/test_funding_render.mjs              # the browser module
```

The Node tests import `docs/assets/funding.js` directly — the same file the page loads,
no bundler and no test double — which is possible because `fundingView` is pure and the
DOM half is separate. One Python test goes the other way: it hands the publisher's real
output to the real JS renderer in an explicit `/usr/local/bin/node` subprocess and requires it to validate, which
is the only thing that keeps two implementations of the same money rules from drifting.
The subprocess verifies Node `v24.11.0`; a missing or different runtime fails the check.

Every fixture is synthetic. Nothing under `Tests/` is written to
`docs/data/net-sales.json`, and there is a test asserting no fixture amount has reached
it.

### Previewing the page, and the Chrome QA harness

Serve the **repository root**:

```sh
/opt/homebrew/bin/python3.13 -m http.server 4347 --bind 127.0.0.1
# the site:        http://127.0.0.1:4347/docs/
# the QA harness:  http://127.0.0.1:4347/Tests/site/preview.html
```

`Tests/site/preview.html` is a local-only harness, outside `docs/` so it cannot reach the
published site. It frames the real page and gives you width buttons for 320/390/768/1440
CSS px with a live overflow readback, plus buttons that drive the **real** funding module
with clearly-labelled synthetic fixtures. There is no production query flag and no demo
amount in `docs/data` — the fixtures exist only in the harness, behind a banner that says
so and cannot be dismissed.

A plain `file://` open of the site will not work: the page loads `assets/site.js` as an ES
module and fetches `data/net-sales.json`, both blocked by the `file://` origin policy. The
page still renders correctly without them — that is the point of the design — but an HTTP
origin is needed to see the rendered path.
