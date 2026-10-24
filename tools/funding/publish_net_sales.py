#!/usr/bin/env python3.13
"""Publish the public net-sales aggregate for cliphoard.dev from private reconciliation.

    /opt/homebrew/bin/python3.13 tools/funding/publish_net_sales.py \
        --scope  ~/private/cliphoard/scope.json \
        --input  ~/private/cliphoard/reconciliation-2026-12.json \
        --output docs/data/net-sales.json

WHAT THIS IS, AND WHAT IT DELIBERATELY IS NOT

It is a validator with a sum at the end. It reads TWO private files you point it at
explicitly — a scope file and a reconciliation file — refuses them on any of about forty
specific grounds, and only if nothing is wrong writes a small public aggregate carrying
no identifier of any kind.

It is NOT a provider integration. There is no Apple or Stripe Managed Payments API client here and
no invented endpoint. The reconciliation files are produced BY HAND by the operator from
provider settlement records; `README.md` documents how. Nothing in this directory
performs or claims automatic native ingestion, and a passing test suite here says
nothing whatsoever about any external provider.

FIVE RULES THAT SHAPE EVERY LINE BELOW

1. Money never touches a float. Amounts are decimal strings in, `Decimal` inside,
   decimal strings out, bounded to the range the browser renderer can represent
   exactly. A float, an int or a bool where an amount belongs is a rejection.
2. SCOPE IS NOT SELF-DECLARED. The identities a report is checked against come from a
   SEPARATE private file, because trusting scope supplied by the same document being
   scoped is not a check at all. A report outside scope is rejected, never filtered —
   filtering silently drops revenue the operator believed was counted.
3. A COMBINED TOTAL NEEDS COMPLETE EVIDENCE FROM BOTH CHANNELS. Summing whichever
   channels happen to have reported and calling the result cumulative combined proceeds
   is the headline defect this version exists to fix. Missing data is never zero.
4. Nothing from the private files reaches the output except numbers on an explicit
   allowlist, and error messages carry a FIELD PATH and never a key name, a value or an
   input snippet. A traceback is how private data escapes.
5. Rejection is the default. Every identity is recomputed rather than trusted, coverage
   must be complete rather than merely present, and anything the schema does not
   explicitly know about is an error.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sys
import tempfile
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path

if sys.version_info < (3, 13):
    raise SystemExit("python_runtime_below_3_13")

INPUT_SCHEMA = "cliphoard.net-sales.reconciliation/3"
SCOPE_SCHEMA = "cliphoard.net-sales.scope/2"
OUTPUT_SCHEMA = "cliphoard.net-sales/3"

#: The two channels this campaign has, in the order the page lists them. Both are
#: REQUIRED, in the scope file, in the reconciliation file and in the public output.
CANONICAL_CHANNELS = ("app_store", "stripe_managed_payments")

#: Public names come from here and ONLY from here. There is deliberately no `label`
#: field in either private schema, so there is no arbitrary operator-supplied string
#: that could be copied into a public file or an error message.
CHANNEL_LABELS = {
    "app_store": "Apple App Store",
    "stripe_managed_payments": "Stripe Managed Payments",
}

#: THE GOAL IS A CONSTANT. `docs/index.html` hard-codes the ruler's tick labels at
#: $0/$50k/$100k/$150k/$200k/$250k and the renderer re-checks this same number, so a
#: different goal would publish a figure against an axis that does not describe it.
#: 249999.99 is a perfectly good PROCEEDS figure and an invalid GOAL configuration.
GOAL = Decimal("250000.00")

#: The widest value the money grammar admits, and therefore the bound every component,
#: every channel sum, every FX product and the final total is checked against. It sits
#: far inside the browser's exact-integer range (2**53-1 minor units), so a value that
#: validates here is representable in the renderer without loss.
MAX_MONEY = Decimal("999999999999.99")

MONEY_RE = re.compile(r"^-?(0|[1-9][0-9]{0,11})\.[0-9]{2}$")
RATE_RE = re.compile(r"^(0|[1-9][0-9]{0,6})\.[0-9]{1,10}$")
DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
CURRENCY_RE = re.compile(r"^[A-Z]{3}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
STRIPE_ACCOUNT_RE = re.compile(r"acct_[A-Za-z0-9_]{1,180}")
STRIPE_PRODUCT_PRICE_RE = re.compile(r"prod_[A-Za-z0-9_]{1,180}:price_[A-Za-z0-9_]{1,180}")

#: Amounts that cannot be negative in any real settlement report. A negative fee is not
#: a fee going the other way, it is a sign error upstream — and a sign error in `fees`
#: inflates the published total.
NON_NEGATIVE = ("gross", "discounts", "customer_tax", "fees", "refunds", "chargebacks")
#: `adjustments` is signed on purpose: provider corrections go both ways, and this is the
#: field through which a late refund correctly REDUCES the aggregate.
SIGNED = ("adjustments",)

REPORT_KEYS = {
    "report_id", "source_sha256", "period_start", "period_end", "currency",
    "account", "vendor", "store", "products",
    "gross", "discounts", "customer_tax", "fees", "refunds", "chargebacks",
    "adjustments", "provider_reported_net", "fx", "settlement_usd",
}
CHANNEL_KEYS = {"id", "mode", "reports"}
TOP_KEYS = {"schema", "campaign_start", "as_of", "currency", "goal", "channels"}
FX_KEYS = {"from_currency", "rate", "source", "date"}
SCOPE_TOP_KEYS = {"schema", "channels"}
SCOPE_CHANNEL_KEYS = {"id", "account", "vendor", "store", "products"}

CENTS = Decimal("0.01")


class Rejected(Exception):
    """A refusal to publish. Carries a code and a FIELD PATH — never a value, never a
    key name from the input, never a snippet of it.

    The no-content rule is not politeness. These files hold a business's settlement
    figures and its provider account identifiers, and anything raised here can end up in
    a terminal, a CI log or a pasted bug report. `detail` is only ever a fixed string
    chosen from this source file.
    """

    def __init__(self, code: str, where: str, detail: str = "") -> None:
        self.code = code
        self.where = where
        super().__init__(f"{code} at {where}" + (f": {detail}" if detail else ""))


# ── JSON loading ─────────────────────────────────────────────────────────────

def _reject_duplicate_keys(pairs):
    """`json` takes last-wins on a repeated key; this refuses instead.

    Last-wins means a document can carry two `gross` values, or two `report_id`s, and
    the one a human reviewing the file sees need not be the one the tool uses. The
    repeated key's NAME is not reported, because a key name is attacker-chosen text.
    """
    seen = set()
    for key, _ in pairs:
        if key in seen:
            raise Rejected("duplicate-json-key", "$",
                           "an object in this file has a repeated key")
        seen.add(key)
    return dict(pairs)


def load_private_json(path: Path, label: str):
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        # `UnicodeDecodeError` stringifies with the offending BYTES in it, and those
        # bytes are a fragment of a settlement file. Replaced with a fixed code.
        raise Rejected("not-valid-utf8", label) from None
    except OSError:
        raise Rejected("unreadable-file", label) from None
    try:
        return json.loads(text, object_pairs_hook=_reject_duplicate_keys)
    except json.JSONDecodeError:
        # The parser's own message quotes the offending source text, which may be an
        # amount or an account id. It is replaced with a code.
        raise Rejected("not-valid-json", label) from None


# ── primitive validators ─────────────────────────────────────────────────────

def _exact_keys(obj, allowed: set[str], where: str) -> None:
    if not isinstance(obj, dict):
        raise Rejected("not-an-object", where)
    extra = len(set(obj) - allowed)
    missing = len(allowed - set(obj))
    if extra or missing:
        # Counts only. An unknown key's NAME is input, and an operator could put an
        # email address or an order id in one — so it is counted, never quoted.
        raise Rejected("unexpected-object-shape", where,
                       f"{extra} unrecognised and {missing} missing field(s)")


def money(obj: dict, key: str, where: str, *, signed: bool = False) -> Decimal:
    value = obj.get(key, None)
    # `bool` first: `isinstance(True, int)` is True in Python, so a bool slipped into a
    # money field would otherwise pass an int check and arrive as 1.00.
    if isinstance(value, bool):
        raise Rejected("bool-in-money-field", f"{where}.{key}")
    if isinstance(value, (int, float, Decimal)):
        raise Rejected("numeric-money-field", f"{where}.{key}",
                       "amounts must be decimal strings, never JSON numbers")
    if not isinstance(value, str) or not MONEY_RE.match(value):
        raise Rejected("not-a-money-string", f"{where}.{key}")
    amount = Decimal(value)
    if not signed and amount < 0:
        raise Rejected("negative-amount-impossible", f"{where}.{key}")
    return bounded(canonical_zero(amount), f"{where}.{key}")


def canonical_zero(amount: Decimal) -> Decimal:
    """Collapse `-0.00` to `0.00`.

    `Decimal("-0.00")` passes the money grammar, compares equal to zero, and serializes
    as `"-0.00"` — which the page would render as a negative total of nothing. Sign on
    zero carries no information about money, so it is removed at the boundary rather
    than guarded against at every use.
    """
    return Decimal("0.00") if amount == 0 else amount


def bounded(amount: Decimal, where: str) -> Decimal:
    if abs(amount) > MAX_MONEY:
        raise Rejected("amount-out-of-range", where,
                       "outside the range the published format can represent exactly")
    return amount


def parse_date(value, where: str) -> dt.date:
    """A real calendar date, or a fixed refusal.

    The regex is a shape check only: `2026-02-31` matches it and is not a date. Every
    entry point that takes a date string goes through here, so no caller can reach
    `fromisoformat` unguarded and turn a typo into a ValueError traceback.
    """
    if not isinstance(value, str) or not DATE_RE.match(value):
        raise Rejected("not-a-date", where)
    try:
        return dt.date.fromisoformat(value)
    except ValueError:
        raise Rejected("not-a-calendar-date", where) from None


def date(obj: dict, key: str, where: str) -> dt.date:
    return parse_date(obj.get(key, None), f"{where}.{key}")


def identifier(obj: dict, key: str, where: str, *, limit: int = 200) -> str:
    """A private identifier: present, non-empty, bounded, and never reported back."""
    value = obj.get(key, None)
    if not isinstance(value, str) or not value.strip() or len(value) > limit:
        raise Rejected("not-a-nonempty-string", f"{where}.{key}")
    return value


def _fmt(amount: Decimal) -> str:
    return f"{canonical_zero(amount):.2f}"


# ── the scope file ───────────────────────────────────────────────────────────

class ChannelScope:
    """The identities a channel's reports are checked against.

    Supplied in a SEPARATE file from the reports. That separation is the whole point:
    the previous version of this tool read an `allowlist` out of the report file itself,
    which let a report declare its own scope and then satisfy it — a check that could
    never fail. `README.md` documents how the operator reads each of these values out of
    the provider's own records.
    """

    __slots__ = ("id", "account", "vendor", "store", "products")

    def __init__(self, raw, where: str) -> None:
        _exact_keys(raw, SCOPE_CHANNEL_KEYS, where)
        self.id = raw.get("id", None)
        if self.id not in CANONICAL_CHANNELS:
            raise Rejected("unknown-channel-id", f"{where}.id")
        self.account = identifier(raw, "account", where)
        self.vendor = identifier(raw, "vendor", where)
        # Neither canonical channel uses a Lemon Squeezy store. Stripe is scoped by
        # account and exact product:price pairs; legacy store attribution must fail.
        store = raw.get("store", None)
        if self.id == "app_store":
            if store is not None:
                raise Rejected("app-store-scope-must-not-carry-a-store", f"{where}.store",
                               "the App Store has no store identifier")
        else:
            if store is not None:
                raise Rejected("stripe-scope-must-not-carry-a-store", f"{where}.store")
            if not STRIPE_ACCOUNT_RE.fullmatch(self.account):
                raise Rejected("not-a-stripe-account-id", f"{where}.account")
        self.store = store
        products = raw.get("products", None)
        if not isinstance(products, list) or not products:
            raise Rejected("empty-product-scope", f"{where}.products")
        for i, product in enumerate(products):
            if not isinstance(product, str) or not product.strip():
                raise Rejected("not-a-product-id", f"{where}.products[{i}]")
            if self.id == "stripe_managed_payments" and not STRIPE_PRODUCT_PRICE_RE.fullmatch(product):
                raise Rejected("not-a-stripe-product-price-id", f"{where}.products[{i}]")
        self.products = frozenset(products)


def build_scope(payload) -> dict[str, ChannelScope]:
    _exact_keys(payload, SCOPE_TOP_KEYS, "$")
    if payload.get("schema", None) != SCOPE_SCHEMA:
        raise Rejected("wrong-scope-schema", "$.schema")
    raw = payload.get("channels", None)
    if not isinstance(raw, list):
        raise Rejected("scope-channels-not-a-list", "$.channels")
    scopes: dict[str, ChannelScope] = {}
    for i, entry in enumerate(raw):
        scope = ChannelScope(entry, f"$.channels[{i}]")
        if scope.id in scopes:
            raise Rejected("duplicate-channel-in-scope", f"$.channels[{i}].id")
        scopes[scope.id] = scope
    if set(scopes) != set(CANONICAL_CHANNELS):
        raise Rejected("scope-must-cover-both-canonical-channels", "$.channels")
    return scopes


# ── one report ───────────────────────────────────────────────────────────────

class Report:
    """One hand-reconciled provider report, validated and converted to USD."""

    __slots__ = ("report_id", "fingerprint", "start", "end", "usd")

    def __init__(self, raw, where: str, scope: ChannelScope, today: dt.date) -> None:
        _exact_keys(raw, REPORT_KEYS, where)

        self.report_id = identifier(raw, "report_id", where)

        # PROVENANCE. The SHA-256 of the provider file this row was normalized from, so
        # the same source cannot be entered twice under two different report ids — which
        # is the realistic duplicate, and which looks like progress rather than an error.
        fingerprint = raw.get("source_sha256", None)
        if not isinstance(fingerprint, str) or not SHA256_RE.match(fingerprint):
            raise Rejected("not-a-sha256", f"{where}.source_sha256")
        self.fingerprint = fingerprint

        self.start = date(raw, "period_start", where)
        self.end = date(raw, "period_end", where)
        if self.end < self.start:
            raise Rejected("period-ends-before-it-starts", where)
        if self.end > today:
            raise Rejected("report-period-ends-in-the-future", f"{where}.period_end")

        currency = raw.get("currency", None)
        if not isinstance(currency, str) or not CURRENCY_RE.match(currency):
            raise Rejected("not-a-currency-code", f"{where}.currency")

        # SCOPE, checked against the separate scope file. Each of these is a REJECTION
        # rather than a filter: a report from the wrong account or for someone else's
        # product means the operator's normalization is wrong, and quietly dropping it
        # would publish a total the operator believes includes it.
        if identifier(raw, "account", where) != scope.account:
            raise Rejected("account-outside-scope", f"{where}.account")
        if identifier(raw, "vendor", where) != scope.vendor:
            raise Rejected("vendor-outside-scope", f"{where}.vendor")
        store = raw.get("store", None)
        if store is not None and (not isinstance(store, str) or not store.strip()):
            raise Rejected("not-a-nonempty-string", f"{where}.store")
        if store != scope.store:
            raise Rejected("store-outside-scope", f"{where}.store")

        products = raw.get("products", None)
        if not isinstance(products, list) or not products:
            raise Rejected("no-products-listed", f"{where}.products")
        for i, product in enumerate(products):
            if not isinstance(product, str) or not product.strip():
                raise Rejected("not-a-product-id", f"{where}.products[{i}]")
            if product not in scope.products:
                raise Rejected("product-outside-scope", f"{where}.products[{i}]")

        amounts = {k: money(raw, k, where) for k in NON_NEGATIVE}
        amounts.update({k: money(raw, k, where, signed=True) for k in SIGNED})
        reported = money(raw, "provider_reported_net", where, signed=True)

        # THE IDENTITY. Net is recomputed from the components and must EQUAL what the
        # provider reported. This catches a mis-keyed fee, a tax line counted twice, and
        # a refund entered as a positive. Exact Decimal, no tolerance.
        computed = (amounts["gross"]
                    - amounts["discounts"]
                    - amounts["customer_tax"]
                    - amounts["fees"]
                    - amounts["refunds"]
                    - amounts["chargebacks"]
                    + amounts["adjustments"])
        if canonical_zero(computed) != reported:
            raise Rejected("net-does-not-reconcile", where,
                           "gross - discounts - customer_tax - fees - refunds "
                           "- chargebacks + adjustments != provider_reported_net")

        self.usd = self._to_usd(raw, where, currency, reported, today)

    @staticmethod
    def _to_usd(raw, where: str, currency: str, native_net: Decimal,
                today: dt.date) -> Decimal:
        """The USD figure for this report.

        Non-USD needs one of exactly two things, because a rate nobody wrote down is a
        rate nobody can check later: `settlement_usd`, where the provider settled in USD
        and reported that amount, or `fx`, an explicit rate recorded at the time.
        """
        fx = raw.get("fx", None)
        settlement = raw.get("settlement_usd", None)

        if currency == "USD":
            if fx is not None:
                raise Rejected("fx-on-a-usd-report", f"{where}.fx")
            if settlement is not None:
                raise Rejected("settlement-on-a-usd-report", f"{where}.settlement_usd")
            return native_net

        if settlement is not None:
            if fx is not None:
                raise Rejected("both-fx-and-settlement", f"{where}.fx")
            return money(raw, "settlement_usd", where, signed=True)

        if fx is None:
            raise Rejected("non-usd-without-fx-or-settlement", f"{where}.fx",
                           "a non-USD report needs a recorded rate or a USD settlement")

        _exact_keys(fx, FX_KEYS, f"{where}.fx")
        if fx.get("from_currency", None) != currency:
            raise Rejected("fx-currency-mismatch", f"{where}.fx.from_currency")
        rate_value = fx.get("rate", None)
        if isinstance(rate_value, bool) or isinstance(rate_value, (int, float, Decimal)):
            raise Rejected("numeric-fx-rate", f"{where}.fx.rate",
                           "the rate must be a decimal string")
        if not isinstance(rate_value, str) or not RATE_RE.match(rate_value):
            raise Rejected("not-a-rate", f"{where}.fx.rate")
        rate = Decimal(rate_value)
        if rate <= 0:
            raise Rejected("fx-rate-not-positive", f"{where}.fx.rate")
        identifier(fx, "source", f"{where}.fx")
        fx_date = date(fx, "date", f"{where}.fx")
        # The rate must belong to the money it converts, and cannot be from the future.
        if fx_date < date(raw, "period_end", where):
            raise Rejected("fx-date-precedes-period-end", f"{where}.fx.date")
        if fx_date > today:
            raise Rejected("fx-date-in-the-future", f"{where}.fx.date")

        # One rounding step, on the net, rather than converting each component and
        # summing — converting six numbers rounds six times and can land a cent away
        # from the figure the provider actually settled. Bounded, because a large
        # in-range native amount times a large in-range rate is not in range.
        product = (native_net * rate).quantize(CENTS, rounding=ROUND_HALF_UP)
        return bounded(canonical_zero(product), f"{where}.fx")


# ── one channel ──────────────────────────────────────────────────────────────

class Channel:
    __slots__ = ("id", "mode", "reports", "net")

    def __init__(self, raw, where: str, scope: ChannelScope,
                 campaign_start: dt.date, as_of: dt.date, today: dt.date) -> None:
        _exact_keys(raw, CHANNEL_KEYS, where)
        self.id = raw.get("id", None)
        if self.id not in CANONICAL_CHANNELS:
            raise Rejected("unknown-channel-id", f"{where}.id")
        if self.id != scope.id:
            raise Rejected("channel-scope-mismatch", f"{where}.id")

        self.mode = raw.get("mode", None)
        if self.mode not in ("period", "cumulative"):
            raise Rejected("unknown-report-mode", f"{where}.mode")

        raw_reports = raw.get("reports", None)
        if not isinstance(raw_reports, list):
            raise Rejected("reports-not-a-list", f"{where}.reports")
        self.reports = [Report(r, f"{where}.reports[{i}]", scope, today)
                        for i, r in enumerate(raw_reports)]

        if not self.reports:
            # No evidence for this channel. `net` stays None and never becomes zero:
            # "we have no report" and "the report says zero" are different claims, and
            # only one of them is a figure.
            self.net = None
            return

        self.reports.sort(key=lambda r: (r.start, r.end))
        self.net = (self._cumulative_net(where, campaign_start, as_of)
                    if self.mode == "cumulative"
                    else self._period_net(where, campaign_start, as_of))
        bounded(self.net, f"{where}.reports")

    def _cumulative_net(self, where, campaign_start, as_of) -> Decimal:
        """A cumulative channel carries EXACTLY ONE report covering the whole campaign.

        This is where cumulative double-counting is prevented. Two cumulative reports
        are not two periods to add — each already contains the other's money.
        """
        if len(self.reports) != 1:
            raise Rejected("cumulative-channel-needs-exactly-one-report",
                           f"{where}.reports",
                           "summing cumulative reports would double-count them")
        only = self.reports[0]
        if only.start != campaign_start:
            raise Rejected("cumulative-report-does-not-start-at-campaign-start",
                           f"{where}.reports[0].period_start")
        if only.end != as_of:
            raise Rejected("cumulative-report-does-not-end-at-cutoff",
                           f"{where}.reports[0].period_end")
        return canonical_zero(only.usd)

    def _period_net(self, where, campaign_start, as_of) -> Decimal:
        """Consecutive, non-overlapping, gapless periods from campaign start to cutoff.

        Each failure below produces a WRONG total rather than an obviously broken one:
        an overlap counts a month twice, a gap silently omits one, and coverage that
        stops short publishes a stale figure under a current date.
        """
        if self.reports[0].start != campaign_start:
            raise Rejected("coverage-does-not-start-at-campaign-start",
                           f"{where}.reports[0].period_start")
        for i in range(1, len(self.reports)):
            previous, current = self.reports[i - 1], self.reports[i]
            if current.start <= previous.end:
                raise Rejected("overlapping-periods", f"{where}.reports[{i}].period_start")
            if current.start != previous.end + dt.timedelta(days=1):
                raise Rejected("gap-in-coverage", f"{where}.reports[{i}].period_start")
        if self.reports[-1].end != as_of:
            raise Rejected("coverage-does-not-reach-the-cutoff",
                           f"{where}.reports[{len(self.reports) - 1}].period_end")
        total = Decimal("0.00")
        for report in self.reports:
            total = bounded(total + report.usd, f"{where}.reports")
        return canonical_zero(total)


# ── the whole reconciliation ─────────────────────────────────────────────────

BASIS = ("Provider-reported net earnings since the campaign start, after customer "
         "taxes, platform and payment fees, refunds, chargebacks and reported "
         "adjustments, and before income tax and running costs. Reconciled monthly from "
         "provider reports; not a current bank balance.")


def build_aggregate(payload, scopes: dict[str, ChannelScope], *, today: str,
                    expect_campaign_start: str | None = None) -> dict:
    """Validate a reconciliation payload and return the PUBLIC aggregate.

    `today` is a parameter rather than a call to the clock so that the future-date
    refusals are deterministic under test and so that "exactly today" is testable.

    The returned dict is constructed field by field from an explicit allowlist. It is
    never derived from the input by copying or filtering, because a filter is one
    forgotten key away from publishing an account id.
    """
    now = parse_date(today, "today")

    _exact_keys(payload, TOP_KEYS, "$")
    if payload.get("schema", None) != INPUT_SCHEMA:
        raise Rejected("wrong-input-schema", "$.schema")
    if payload.get("currency", None) != "USD":
        raise Rejected("reporting-currency-must-be-usd", "$.currency",
                       "individual reports may be in any currency with a recorded rate")

    # The goal is a constant of this campaign and of the page's fixed axis. It is still
    # required in the input so the operator states it, and it must match exactly.
    if money(payload, "goal", "$") != GOAL:
        raise Rejected("goal-must-match-the-published-goal", "$.goal",
                       "the page's ruler axis is fixed, so the goal is not configurable")

    # CAMPAIGN START IS AN INPUT, never a constant here. It is the date the first channel
    # opened and the lower bound every report is checked against.
    campaign_start = date(payload, "campaign_start", "$")
    if campaign_start > now:
        raise Rejected("campaign-start-in-the-future", "$.campaign_start")
    if expect_campaign_start is not None:
        if parse_date(expect_campaign_start, "--campaign-start") != campaign_start:
            raise Rejected("campaign-start-does-not-match-the-asserted-one",
                           "$.campaign_start")

    # ONE CUTOFF FOR EVERY CHANNEL. Channels reconciled to different dates do not make a
    # total; they make a figure current for one shop and stale for the other.
    as_of = date(payload, "as_of", "$")
    if as_of < campaign_start:
        raise Rejected("cutoff-precedes-campaign-start", "$.as_of")
    if as_of > now:
        raise Rejected("cutoff-in-the-future", "$.as_of")

    raw_channels = payload.get("channels", None)
    if not isinstance(raw_channels, list):
        raise Rejected("channels-not-a-list", "$.channels")

    channels: dict[str, Channel] = {}
    fingerprints: set[str] = set()
    report_ids: set[str] = set()
    for i, raw in enumerate(raw_channels):
        cid = raw.get("id", None) if isinstance(raw, dict) else None
        scope = scopes.get(cid, None)
        if scope is None:
            raise Rejected("unknown-channel-id", f"$.channels[{i}].id")
        channel = Channel(raw, f"$.channels[{i}]", scope, campaign_start, as_of, now)
        if channel.id in channels:
            raise Rejected("duplicate-channel", f"$.channels[{i}].id")
        channels[channel.id] = channel
        for j, report in enumerate(channel.reports):
            if report.report_id in report_ids:
                raise Rejected("duplicate-report-id",
                               f"$.channels[{i}].reports[{j}].report_id")
            report_ids.add(report.report_id)
            # Provenance duplicate: the SAME provider file entered twice under two
            # different ids. Caught by content, not by label.
            if report.fingerprint in fingerprints:
                raise Rejected("duplicate-source-report",
                               f"$.channels[{i}].reports[{j}].source_sha256",
                               "this provider file has already been counted")
            fingerprints.add(report.fingerprint)

    # BOTH canonical channels, exactly once each, no extras and none missing.
    if set(channels) != set(CANONICAL_CHANNELS):
        raise Rejected("both-canonical-channels-are-required", "$.channels")

    ordered = [channels[cid] for cid in CANONICAL_CHANNELS]
    generated = now.isoformat()

    # THE RULE THIS VERSION EXISTS FOR. A combined total is published only when BOTH
    # channels have complete evidence for the same period. If either has none, there is
    # no combined figure to publish — summing the one that reported and labelling it
    # combined cumulative proceeds would be a different and smaller number presented as
    # this one. Partial per-channel figures are withheld too, because a reader seeing
    # one channel's amount next to an unavailable total will add it up themselves.
    if any(channel.net is None for channel in ordered):
        return _unavailable(generated)

    total = Decimal("0.00")
    for channel in ordered:
        total = bounded(total + channel.net, "$.channels")
    total = canonical_zero(total)

    report_count = sum(len(c.reports) for c in ordered)
    starts = [r.start for c in ordered for r in c.reports]
    ends = [r.end for c in ordered for r in c.reports]
    if min(starts) != campaign_start or max(ends) != as_of:
        raise Rejected("coverage-is-partial", "$.channels")

    return {
        "schema": OUTPUT_SCHEMA,
        "status": "certified_zero" if total == 0 else "reported",
        "currency": "USD",
        "goal": _fmt(GOAL),
        "total_net": _fmt(total),
        "campaign_start": campaign_start.isoformat(),
        "as_of": as_of.isoformat(),
        "generated": generated,
        "basis": BASIS,
        "coverage": {
            "reports": report_count,
            "start": campaign_start.isoformat(),
            "end": as_of.isoformat(),
        },
        "channels": [_public_channel(c) for c in ordered],
    }


def _unavailable(generated: str) -> dict:
    """The honest no-figure payload. Carries the goal and nothing else numeric.

    Both channels read `no_reports`, which the page renders as "Awaiting reconciled
    reports". Note what it does NOT say: it makes no claim that a channel is closed, that
    no checkout exists, or that nothing has been sold. This tool reads reconciliation
    files; the absence of one is a fact about this tool's inputs, not about the world.
    """
    return {
        "schema": OUTPUT_SCHEMA,
        "status": "unavailable",
        "currency": "USD",
        "goal": _fmt(GOAL),
        "total_net": None,
        "campaign_start": None,
        "as_of": None,
        "generated": generated,
        "basis": BASIS,
        "coverage": {"reports": 0, "start": None, "end": None},
        "channels": [{"id": cid, "status": "no_reports", "net": None, "as_of": None}
                     for cid in CANONICAL_CHANNELS],
    }


def unavailable_aggregate(today: str) -> dict:
    """The payload to publish before any reconciliation exists. Used by the tests that
    pin the shipped default, so the hand-written file and this tool cannot drift.

    The date is PARSED, not pattern-matched: this is a public artefact, and emitting
    `2026-02-31` as its generation date would be a published impossibility.
    """
    return _unavailable(parse_date(today, "today").isoformat())


def _public_channel(channel: Channel) -> dict:
    """The ONLY per-channel fields published.

    Note what is absent and stays absent: the provider account, the vendor, the store,
    the app SKU and product ids, the per-report ids, the source fingerprints, and every
    raw component of the arithmetic. There is no `label` either — the page's names come
    from a constant in the renderer, so no operator-supplied string is ever copied out.
    """
    return {
        "id": channel.id,
        "status": "certified_zero" if channel.net == 0 else "reported",
        "net": _fmt(channel.net),
        "as_of": max(r.end for r in channel.reports).isoformat(),
    }


# ── file handling ────────────────────────────────────────────────────────────

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
#: The ONE file this tool may write. Not "any path inside the repo": an `--output` typo
#: that landed on README.md or on a Swift source would be a destructive edit made by a
#: tool nobody expects to touch those.
CANONICAL_OUTPUT = REPO_ROOT / "docs" / "data" / "net-sales.json"


def _is_inside(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def resolve_private(raw: str, flag: str) -> Path:
    """A private file, with a guard that it really is outside this repository.

    The failure this prevents is unrecoverable in the way that matters: a settlement or
    scope file committed once is in the history permanently. There is also NO discovery
    anywhere in this tool — it opens the paths it was given and never looks for
    financial files on its own.
    """
    path = Path(raw).expanduser().resolve()
    if _is_inside(path, REPO_ROOT):
        raise Rejected("private-file-inside-the-repository", flag,
                       "keep reconciliation and scope files outside the checkout")
    if not path.is_file():
        raise Rejected("not-a-file", flag)
    return path


def resolve_output(raw: str) -> Path:
    path = Path(raw).expanduser().resolve()
    if path != CANONICAL_OUTPUT:
        raise Rejected("output-is-not-the-canonical-public-file", "--output",
                       "this tool writes docs/data/net-sales.json and nothing else")
    if not path.parent.is_dir():
        raise Rejected("output-directory-does-not-exist", "--output")
    return path


def write_atomically(path: Path, aggregate: dict) -> None:
    """Write the aggregate, or leave the previous file completely untouched.

    `os.replace` on the same filesystem is atomic, so the page only ever sees a whole
    document — a half-written public JSON would parse as malformed and the renderer would
    fall back correctly, but the file on disk would still be wrong.
    """
    body = json.dumps(aggregate, indent=2, ensure_ascii=False, sort_keys=False) + "\n"
    handle = tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=str(path.parent),
        prefix=f".{path.name}.", suffix=".tmp", delete=False)
    try:
        with handle as f:
            f.write(body)
            f.flush()
            os.fsync(f.fileno())
        os.replace(handle.name, path)
    except BaseException:
        try:
            os.unlink(handle.name)
        except FileNotFoundError:
            pass
        raise


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="publish_net_sales.py",
        description="Validate private reconciliation against a private scope file and "
                    "publish the public aggregate.")
    parser.add_argument("--scope", required=True,
                        help="the private scope file: expected account, vendor, store "
                             "and allowed product identifiers. Outside this repository.")
    parser.add_argument("--input", required=True,
                        help="the private reconciliation file. Outside this repository.")
    parser.add_argument("--output", required=True,
                        help="must be docs/data/net-sales.json")
    parser.add_argument("--campaign-start", default=None, metavar="YYYY-MM-DD",
                        help="assert the campaign start in the input, as a typo guard")
    parser.add_argument("--today", default=None, metavar="YYYY-MM-DD",
                        help="DRY RUN ONLY. Override today to reproduce or rehearse a "
                             "publication. A published file always carries the real UTC "
                             "date.")
    parser.add_argument("--dry-run", action="store_true",
                        help="validate and print the aggregate; write nothing")
    args = parser.parse_args(argv)

    try:
        scope_path = resolve_private(args.scope, "--scope")
        source = resolve_private(args.input, "--input")
        destination = resolve_output(args.output)
        if scope_path == source:
            raise Rejected("scope-and-input-are-the-same-file", "--scope",
                           "scope supplied by the file being scoped is not a check")
        # `today` is what bounds every future-date refusal, so an override is a way to
        # publish a file dated in the future or to accept reports that have not happened
        # yet. It is therefore confined to --dry-run, and a real publication always takes
        # the actual UTC date, which cannot be in the future by construction.
        if args.today is not None and not args.dry_run:
            raise Rejected("today-override-requires-dry-run", "--today",
                           "a published file always carries the real UTC date")
        today = args.today or dt.datetime.now(dt.timezone.utc).date().isoformat()
        scopes = build_scope(load_private_json(scope_path, "--scope"))
        aggregate = build_aggregate(load_private_json(source, "--input"), scopes,
                                    today=today,
                                    expect_campaign_start=args.campaign_start)
    except Rejected as rejection:
        print(f"refusing to publish: {rejection}", file=sys.stderr)
        return 2

    if args.dry_run:
        if args.today is not None:
            # Loud, and on stderr so it survives a redirect of stdout into a file: a dry
            # run with an overridden clock must not be mistakable for a publication.
            print("SYNTHETIC DRY RUN — today was overridden on the command line. "
                  "This output is a rehearsal and was NOT published.", file=sys.stderr)
            aggregate = {**aggregate, "synthetic": "dry run with an overridden today; "
                                                   "not a published figure"}
        print(json.dumps(aggregate, indent=2, ensure_ascii=False))
        return 0

    write_atomically(destination, aggregate)
    shown = aggregate["total_net"] or "no reconciled reports"
    print(f"published {destination.relative_to(REPO_ROOT)} — "
          f"status {aggregate['status']}, total {shown}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
