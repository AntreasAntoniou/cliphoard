#!/usr/bin/env python3.13
"""The money matrix for tools/funding/publish_net_sales.py.

Every fixture here is SYNTHETIC. None of it is a real settlement report, none of the
amounts are real proceeds, and nothing in this file is written to
`docs/data/net-sales.json` — the production file carries the honest no-reports state, and
a test that could overwrite it would be the failure the whole design exists to prevent.

A PASSING RUN HERE SAYS NOTHING ABOUT ANY EXTERNAL PROVIDER. There is no Apple or Stripe
Managed Payments client in the tool and none is exercised here. What is tested is the validator
that stands between a hand-reconciled private file and a public number.

Two deliberate properties of the helpers, both of which were defects in the previous
version of this file:
  * NO helper defaults to a single channel. `payload()` always builds both canonical
    channels, because a combined total that silently came from one of them is the
    headline bug under test.
  * NO helper encodes missing data as zero. The absent case is built by giving a channel
    NO REPORTS, never by giving it an amount of 0.00 — those are different claims.

Run:  /opt/homebrew/bin/python3.13 -m unittest discover -s Tests/site -p 'test_*.py'
"""

import datetime as dt
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from decimal import Decimal
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO / "tools" / "funding"))

import publish_net_sales as pub  # noqa: E402

#: Injected everywhere instead of the clock, so the future-date refusals and the
#: exactly-today acceptance are deterministic.
TODAY = "2026-12-05"
START = "2026-11-01"
CUTOFF = "2026-11-30"

APPLE = {"account": "APPLE-VENDOR-0001", "vendor": "Example Vendor Ltd",
         "store": None, "products": ["CLIPHOARD_PRO"]}
STRIPE = {"account": "acct_SYNTHETIC0001", "vendor": "Example Vendor Ltd",
          "store": None, "products": ["prod_CLIPHOARD:price_PRO10"]}
IDENTITIES = {"app_store": APPLE, "stripe_managed_payments": STRIPE}


# ── fixture construction ─────────────────────────────────────────────────────

def scope_payload(**overrides):
    channels = []
    for cid in pub.CANONICAL_CHANNELS:
        entry = {"id": cid, **{k: v for k, v in IDENTITIES[cid].items()}}
        entry["products"] = list(entry["products"])
        channels.append(entry)
    body = {"schema": pub.SCOPE_SCHEMA, "channels": channels}
    body.update(overrides)
    return body


def scopes(**overrides):
    return pub.build_scope(scope_payload(**overrides))


def fingerprint(seed: str) -> str:
    """A stable synthetic SHA-256 standing in for the provider file's digest."""
    return hashlib.sha256(seed.encode()).hexdigest()


def report(report_id, cid="app_store", start=START, end=CUTOFF, *,
           gross="1000.00", discounts="0.00", customer_tax="120.00", fees="264.00",
           refunds="50.00", chargebacks="0.00", adjustments="0.00",
           net=None, currency="USD", products=None, source=None, **extra):
    """A report that reconciles by construction unless a caller breaks it on purpose.

    1000 - 0 - 120 - 264 - 50 - 0 + 0 = 566.00
    """
    if net is None:
        computed = (Decimal(gross) - Decimal(discounts) - Decimal(customer_tax)
                    - Decimal(fees) - Decimal(refunds) - Decimal(chargebacks)
                    + Decimal(adjustments))
        net = f"{computed:.2f}"
    identity = IDENTITIES[cid]
    body = {
        "report_id": report_id,
        "source_sha256": fingerprint(report_id) if source is None else source,
        "period_start": start,
        "period_end": end,
        "currency": currency,
        "account": identity["account"],
        "vendor": identity["vendor"],
        "store": identity["store"],
        "products": list(products if products is not None else identity["products"]),
        "gross": gross,
        "discounts": discounts,
        "customer_tax": customer_tax,
        "fees": fees,
        "refunds": refunds,
        "chargebacks": chargebacks,
        "adjustments": adjustments,
        "provider_reported_net": net,
        # Both present as null in a well-formed USD report. The schema requires every
        # field to be PRESENT, so that a missing one is a shape error rather than
        # something silently compared against `None` further down.
        "fx": None,
        "settlement_usd": None,
    }
    body.update(extra)
    return body


def exact(amount, report_id, cid="app_store", start=START, end=CUTOFF):
    """A report whose net is exactly `amount`, with the components made to add up.

    The whole figure goes through `adjustments`, the one signed field, so the same helper
    produces positive, zero and negative report totals.
    """
    return report(report_id, cid, start, end,
                  gross="0.00", discounts="0.00", customer_tax="0.00", fees="0.00",
                  refunds="0.00", chargebacks="0.00", adjustments=amount)


def payload(app_reports=(), stripe_reports=(), *, campaign_start=START, as_of=CUTOFF,
            goal="250000.00", app_mode="period", stripe_mode="period", **extra):
    """BOTH canonical channels, always. There is no single-channel shortcut on purpose."""
    body = {
        "schema": pub.INPUT_SCHEMA,
        "campaign_start": campaign_start,
        "as_of": as_of,
        "currency": "USD",
        "goal": goal,
        "channels": [
            {"id": "app_store", "mode": app_mode, "reports": list(app_reports)},
            {"id": "stripe_managed_payments", "mode": stripe_mode, "reports": list(stripe_reports)},
        ],
    }
    body.update(extra)
    return body


def both(app_amount, stripe_amount, **kwargs):
    """A complete two-channel campaign netting exactly these two amounts."""
    return payload([exact(app_amount, "apple-1", "app_store")],
                   [exact(stripe_amount, "stripe-1", "stripe_managed_payments")], **kwargs)


class Base(unittest.TestCase):

    def build(self, body, *, scope=None, today=TODAY, **kwargs):
        return pub.build_aggregate(body, scope or scopes(), today=today, **kwargs)

    def rejects(self, body, code=None, *, scope=None, today=TODAY, **kwargs):
        with self.assertRaises(pub.Rejected) as caught:
            pub.build_aggregate(body, scope or scopes(), today=today, **kwargs)
        if code is not None:
            self.assertEqual(caught.exception.code, code)
        return caught.exception

    def channels_of(self, aggregate):
        return {c["id"]: c for c in aggregate["channels"]}


class StripeChannelMigration(Base):

    def test_versions_explicitly_invalidate_legacy_evidence(self):
        self.assertEqual(pub.INPUT_SCHEMA, "cliphoard.net-sales.reconciliation/3")
        self.assertEqual(pub.SCOPE_SCHEMA, "cliphoard.net-sales.scope/2")
        self.assertEqual(pub.OUTPUT_SCHEMA, "cliphoard.net-sales/3")

    def test_legacy_scope_and_reconciliation_versions_are_rejected(self):
        with self.assertRaises(pub.Rejected) as caught:
            pub.build_scope(scope_payload(schema="cliphoard.net-sales.scope/1"))
        self.assertEqual(caught.exception.code, "wrong-scope-schema")
        self.rejects(payload(schema="cliphoard.net-sales.reconciliation/2"),
                     "wrong-input-schema")

    def test_legacy_lemon_channel_cannot_be_relabelled_as_current_evidence(self):
        old_scope = scope_payload()
        old_scope["channels"][1]["id"] = "lemon_squeezy"
        with self.assertRaises(pub.Rejected) as caught:
            pub.build_scope(old_scope)
        self.assertEqual(caught.exception.code, "unknown-channel-id")
        old_input = payload()
        old_input["channels"][1]["id"] = "lemon_squeezy"
        self.rejects(old_input, "unknown-channel-id")

    def test_stripe_scope_requires_account_and_product_price_identifiers(self):
        for field, value, code in (
            ("account", "LS-ACCT-0001", "not-a-stripe-account-id"),
            ("products", ["pro:default"], "not-a-stripe-product-price-id"),
            ("products", ["prod_CLIPHOARD"], "not-a-stripe-product-price-id"),
        ):
            body = scope_payload()
            body["channels"][1][field] = value
            with self.assertRaises(pub.Rejected) as caught:
                pub.build_scope(body)
            self.assertEqual(caught.exception.code, code)

    def test_managed_payments_tax_and_fee_are_deducted_once(self):
        # Synthetic report: fee=30 includes withheld_tax=20; fee_net_of_withheld_tax=10.
        stripe = report("stripe-tax", "stripe_managed_payments", gross="120.00",
                        discounts="0.00", customer_tax="20.00", fees="10.00",
                        refunds="0.00", chargebacks="0.00", adjustments="0.00", net="90.00")
        body = payload([exact("0.00", "apple-1")], [stripe])
        out = self.build(body)
        self.assertEqual(out["total_net"], "90.00")
        self.assertEqual(out["channels"][1]["id"], "stripe_managed_payments")
        stripe["fees"] = "30.00"  # Copying fee here would deduct the same tax twice.
        self.rejects(payload([exact("0.00", "apple-1")], [stripe]), "net-does-not-reconcile")


class Arithmetic(Base):

    def test_both_channels_positive_sums_exactly(self):
        out = self.build(payload(
            [report("apple-1", "app_store")],
            [report("stripe-1", "stripe_managed_payments", gross="500.00", customer_tax="0.00",
                    fees="27.50", refunds="0.00")],
        ))
        self.assertEqual(out["status"], "reported")
        self.assertEqual(out["total_net"], "1038.50")
        self.assertEqual(out["coverage"]["reports"], 2)
        by_id = self.channels_of(out)
        self.assertEqual(by_id["app_store"]["net"], "566.00")
        self.assertEqual(by_id["stripe_managed_payments"]["net"], "472.50")
        self.assertEqual(by_id["app_store"]["as_of"], CUTOFF)

    def test_every_deduction_field_reduces_the_net(self):
        bare = {"gross": "100.00", "discounts": "0.00", "customer_tax": "0.00",
                "fees": "0.00", "refunds": "0.00", "chargebacks": "0.00"}
        plain = self.build(payload([report("apple-1", "app_store", **bare)],
                                   [exact("0.00", "stripe-1", "stripe_managed_payments")]))
        self.assertEqual(plain["total_net"], "100.00")
        for field in ("discounts", "customer_tax", "fees", "refunds", "chargebacks"):
            out = self.build(payload(
                [report("apple-1", "app_store", **{**bare, field: "10.00"})],
                [exact("0.00", "stripe-1", "stripe_managed_payments")]))
            self.assertEqual(out["total_net"], "90.00", f"{field} did not reduce the net")

    def test_a_negative_adjustment_legitimately_reduces_the_aggregate(self):
        out = self.build(payload([report("apple-1", "app_store", adjustments="-66.00")],
                                 [exact("0.00", "stripe-1", "stripe_managed_payments")]))
        self.assertEqual(out["total_net"], "500.00")

    def test_refunds_can_take_the_total_below_zero(self):
        out = self.build(both("-625.40", "500.00"))
        self.assertEqual(out["status"], "reported")
        self.assertEqual(out["total_net"], "-125.40")

    def test_the_net_identity_is_recomputed_rather_than_trusted(self):
        self.rejects(payload([report("apple-1", "app_store", net="5660.00")],
                             [exact("0.00", "stripe-1", "stripe_managed_payments")]),
                     "net-does-not-reconcile")

    def test_contiguous_periods_are_summed(self):
        out = self.build(payload(
            [report("apple-1", "app_store", START, CUTOFF),
             report("apple-2", "app_store", "2026-12-01", "2026-12-04")],
            [exact("0.00", "stripe-1", "stripe_managed_payments", START, "2026-12-04")],
            as_of="2026-12-04"))
        self.assertEqual(out["total_net"], "1132.00")
        self.assertEqual(out["coverage"],
                         {"reports": 3, "start": START, "end": "2026-12-04"})


class GoalIsFixed(Base):

    def test_the_only_valid_goal_is_the_published_one(self):
        self.assertEqual(self.build(both("1.00", "0.00"))["goal"], "250000.00")

    def test_a_goal_that_is_not_the_published_one_is_refused(self):
        # These are perfectly good PROCEEDS figures and invalid GOAL configuration: the
        # page's ruler axis is fixed markup, so the goal is not a parameter.
        for wrong in ("249999.99", "250000.01", "500000.00", "0.00", "1.00",
                      "250000.10", "25000.00", "2500000.00"):
            self.rejects(both("1.00", "0.00", goal=wrong),
                         "goal-must-match-the-published-goal")

    def test_the_boundary_amounts_are_valid_proceeds(self):
        for amount in ("249999.99", "250000.00", "250000.01", "500000.00"):
            out = self.build(both(amount, "0.00"))
            self.assertEqual(out["total_net"], amount)
            self.assertEqual(out["goal"], "250000.00")

    def test_split_across_both_channels_still_hits_the_boundary_exactly(self):
        out = self.build(both("124999.99", "125000.00"))
        self.assertEqual(out["total_net"], "249999.99")


class EvidenceMustBeComplete(Base):
    """The headline defect: a combined total built from one channel."""

    def test_one_channel_reporting_does_not_produce_a_combined_total(self):
        out = self.build(payload([report("apple-1", "app_store")], []))
        self.assertEqual(out["status"], "unavailable")
        self.assertIsNone(out["total_net"])
        self.assertIsNone(out["as_of"])
        self.assertIsNone(out["campaign_start"])
        self.assertEqual(out["coverage"]["reports"], 0)
        # And the reporting channel's figure is withheld too: a reader who sees one
        # amount beside an unavailable total will add it up themselves.
        self.assertTrue(all(c["net"] is None for c in out["channels"]))
        self.assertEqual({c["status"] for c in out["channels"]}, {"no_reports"})

    def test_the_withheld_total_is_not_the_single_channel_amount(self):
        single = self.build(payload([exact("4321.00", "apple-1", "app_store")], []))
        self.assertIsNone(single["total_net"])
        serialized = json.dumps(single)
        self.assertNotIn("4321.00", serialized,
                         "a one-channel figure leaked into a payload with no total")

    def test_no_reports_at_all_is_unavailable_and_not_zero(self):
        out = self.build(payload([], []))
        self.assertEqual(out["status"], "unavailable")
        self.assertIsNone(out["total_net"])
        self.assertEqual({c["status"] for c in out["channels"]}, {"no_reports"})

    def test_both_canonical_channels_are_required(self):
        body = payload([report("apple-1", "app_store")], [])
        body["channels"] = body["channels"][:1]
        self.rejects(body, "both-canonical-channels-are-required")

    def test_a_duplicated_channel_is_refused(self):
        body = payload([], [])
        body["channels"].append({"id": "app_store", "mode": "period", "reports": []})
        self.rejects(body, "duplicate-channel")

    def test_an_unknown_channel_id_is_refused(self):
        body = payload([], [])
        body["channels"][0]["id"] = "some_other_store"
        self.rejects(body, "unknown-channel-id")

    def test_the_scope_file_must_cover_both_channels(self):
        partial = scope_payload()
        partial["channels"] = partial["channels"][:1]
        with self.assertRaises(pub.Rejected) as caught:
            pub.build_scope(partial)
        self.assertEqual(caught.exception.code,
                         "scope-must-cover-both-canonical-channels")


class ZeroIsAClaim(Base):

    def test_a_certified_zero_needs_positive_report_coverage(self):
        out = self.build(both("0.00", "0.00"))
        self.assertEqual(out["status"], "certified_zero")
        self.assertEqual(out["total_net"], "0.00")
        self.assertEqual(out["coverage"]["reports"], 2)
        self.assertEqual({c["status"] for c in out["channels"]}, {"certified_zero"})

    def test_channels_that_cancel_out_are_a_certified_zero(self):
        out = self.build(both("100.00", "-100.00"))
        self.assertEqual(out["status"], "certified_zero")
        self.assertEqual(out["total_net"], "0.00")

    def test_a_zero_total_never_arises_without_reports(self):
        # The only route to "0.00" is reports that say so. Absence routes to unavailable.
        absent = self.build(payload([], []))
        self.assertIsNone(absent["total_net"])
        self.assertNotEqual(absent["status"], "certified_zero")


class NegativeZero(Base):

    def test_negative_zero_is_canonicalized_on_the_way_in(self):
        out = self.build(both("-0.00", "0.00"))
        self.assertEqual(out["total_net"], "0.00")
        self.assertEqual(out["status"], "certified_zero")
        self.assertNotIn("-0.00", json.dumps(out))

    def test_a_negative_zero_component_does_not_leak_a_sign(self):
        out = self.build(payload(
            [report("apple-1", "app_store", gross="10.00", discounts="-0.00",
                    customer_tax="0.00", fees="0.00", refunds="0.00",
                    chargebacks="0.00", adjustments="-0.00")],
            [exact("0.00", "stripe-1", "stripe_managed_payments")]))
        self.assertEqual(out["total_net"], "10.00")

    def test_the_canonicaliser_itself(self):
        self.assertEqual(str(pub.canonical_zero(Decimal("-0.00"))), "0.00")
        self.assertEqual(str(pub.canonical_zero(Decimal("-1.00"))), "-1.00")


class Range(Base):

    MAX = "999999999999.99"

    def test_the_maximum_representable_amount_is_accepted(self):
        out = self.build(both(self.MAX, "0.00"))
        self.assertEqual(out["total_net"], self.MAX)

    def test_one_cent_beyond_the_grammar_is_refused(self):
        self.rejects(both("1000000000000.00", "0.00"), "not-a-money-string")

    def test_overflow_by_addition_of_two_in_range_channels_is_refused(self):
        # Each channel is individually fine; their sum is not representable.
        self.rejects(both(self.MAX, self.MAX), "amount-out-of-range")

    def test_overflow_by_addition_within_one_channel_is_refused(self):
        self.rejects(payload(
            [exact(self.MAX, "apple-1", "app_store", START, CUTOFF),
             exact(self.MAX, "apple-2", "app_store", "2026-12-01", "2026-12-04")],
            [exact("0.00", "stripe-1", "stripe_managed_payments", START, "2026-12-04")],
            as_of="2026-12-04"), "amount-out-of-range")

    def test_fx_overflow_is_refused(self):
        self.rejects(payload([report(
            "apple-1", "app_store", currency="GBP", gross=self.MAX, discounts="0.00",
            customer_tax="0.00", fees="0.00", refunds="0.00", chargebacks="0.00",
            fx={"from_currency": "GBP", "rate": "2.0",
                "source": "provider settlement statement", "date": CUTOFF})],
            [exact("0.00", "stripe-1", "stripe_managed_payments")]), "amount-out-of-range")


class Dates(Base):

    def test_a_cutoff_of_exactly_today_is_accepted(self):
        out = self.build(payload(
            [exact("10.00", "apple-1", "app_store", TODAY, TODAY)],
            [exact("0.00", "stripe-1", "stripe_managed_payments", TODAY, TODAY)],
            campaign_start=TODAY, as_of=TODAY), today=TODAY)
        self.assertEqual(out["as_of"], TODAY)
        self.assertEqual(out["generated"], TODAY)
        self.assertEqual(out["total_net"], "10.00")

    def test_a_future_cutoff_is_refused(self):
        self.rejects(both("10.00", "0.00", as_of="2026-12-06"), "cutoff-in-the-future")

    def test_a_future_campaign_start_is_refused(self):
        self.rejects(both("10.00", "0.00", campaign_start="2026-12-31",
                          as_of="2026-12-31"), "campaign-start-in-the-future")

    def test_a_report_period_ending_in_the_future_is_refused(self):
        # `as_of` stays valid: a future cutoff is caught earlier, and this must pin the
        # per-report check rather than ride on that one.
        self.rejects(payload(
            [exact("10.00", "apple-1", "app_store", START, "2026-12-31")],
            [exact("0.00", "stripe-1", "stripe_managed_payments", START, TODAY)],
            as_of=TODAY), "report-period-ends-in-the-future")

    def test_a_future_fx_date_is_refused(self):
        self.rejects(payload([report(
            "apple-1", "app_store", currency="GBP",
            fx={"from_currency": "GBP", "rate": "1.27", "source": "s",
                "date": "2026-12-31"})],
            [exact("0.00", "stripe-1", "stripe_managed_payments")]), "fx-date-in-the-future")

    def test_generated_is_always_the_injected_today(self):
        self.assertEqual(self.build(payload([], []), today="2026-12-05")["generated"],
                         "2026-12-05")

    def test_an_invalid_today_is_refused(self):
        for bad, code in (("", "not-a-date"), ("not-a-date", "not-a-date"),
                          ("2026-13-01", "not-a-calendar-date"), (None, "not-a-date"),
                          (20261205, "not-a-date"),
                          # Shape-valid and not a date. This is the case a regex-only
                          # check waves through.
                          ("2026-02-31", "not-a-calendar-date"),
                          ("2027-02-29", "not-a-calendar-date")):
            with self.assertRaises(pub.Rejected) as caught:
                pub.build_aggregate(payload([], []), scopes(), today=bad)
            self.assertEqual(caught.exception.code, code, f"for {bad!r}")

    def test_a_cutoff_before_the_campaign_start_is_refused(self):
        self.rejects(both("1.00", "0.00", campaign_start=CUTOFF, as_of=START),
                     "cutoff-precedes-campaign-start")

    def test_an_asserted_campaign_start_that_disagrees_is_refused(self):
        self.rejects(both("1.00", "0.00"),
                     "campaign-start-does-not-match-the-asserted-one",
                     expect_campaign_start="2026-10-01")
        self.build(both("1.00", "0.00"), expect_campaign_start=START)


class Coverage(Base):

    def test_coverage_must_start_at_the_campaign_start(self):
        self.rejects(payload(
            [exact("1.00", "apple-1", "app_store", "2026-11-05", CUTOFF)],
            [exact("0.00", "stripe-1", "stripe_managed_payments")]),
            "coverage-does-not-start-at-campaign-start")

    def test_coverage_must_reach_the_cutoff(self):
        self.rejects(payload(
            [exact("1.00", "apple-1", "app_store", START, "2026-11-15")],
            [exact("0.00", "stripe-1", "stripe_managed_payments")]),
            "coverage-does-not-reach-the-cutoff")

    def test_overlapping_periods_are_refused(self):
        self.rejects(payload(
            [exact("1.00", "apple-1", "app_store", START, CUTOFF),
             exact("1.00", "apple-2", "app_store", "2026-11-15", "2026-12-04")],
            [exact("0.00", "stripe-1", "stripe_managed_payments", START, "2026-12-04")],
            as_of="2026-12-04"), "overlapping-periods")

    def test_a_gap_between_periods_is_refused(self):
        self.rejects(payload(
            [exact("1.00", "apple-1", "app_store", START, CUTOFF),
             exact("1.00", "apple-2", "app_store", "2026-12-03", "2026-12-04")],
            [exact("0.00", "stripe-1", "stripe_managed_payments", START, "2026-12-04")],
            as_of="2026-12-04"), "gap-in-coverage")

    def test_a_period_ending_before_it_starts_is_refused(self):
        self.rejects(payload(
            [exact("1.00", "apple-1", "app_store", CUTOFF, START)],
            [exact("0.00", "stripe-1", "stripe_managed_payments")]),
            "period-ends-before-it-starts")

    def test_both_channels_must_reach_the_same_cutoff(self):
        self.rejects(payload(
            [exact("1.00", "apple-1", "app_store", START, CUTOFF)],
            [exact("0.00", "stripe-1", "stripe_managed_payments", START, "2026-11-15")]),
            "coverage-does-not-reach-the-cutoff")


class CumulativeReports(Base):

    def test_one_cumulative_report_is_the_channel_total(self):
        out = self.build(payload(
            [report("apple-1", "app_store", START, CUTOFF)],
            [exact("0.00", "stripe-1", "stripe_managed_payments")],
            app_mode="cumulative"))
        self.assertEqual(out["total_net"], "566.00")

    def test_two_cumulative_reports_are_refused_rather_than_summed(self):
        self.rejects(payload(
            [report("apple-1", "app_store", START, "2026-11-15"),
             report("apple-2", "app_store", START, CUTOFF)],
            [exact("0.00", "stripe-1", "stripe_managed_payments")],
            app_mode="cumulative"),
            "cumulative-channel-needs-exactly-one-report")

    def test_a_cumulative_report_must_span_the_whole_campaign(self):
        self.rejects(payload(
            [report("apple-1", "app_store", "2026-11-15", CUTOFF)],
            [exact("0.00", "stripe-1", "stripe_managed_payments")], app_mode="cumulative"),
            "cumulative-report-does-not-start-at-campaign-start")

    def test_the_modes_can_differ_between_channels(self):
        out = self.build(payload(
            [exact("10.00", "apple-1", "app_store", START, CUTOFF),
             exact("10.00", "apple-2", "app_store", "2026-12-01", "2026-12-04")],
            [report("stripe-1", "stripe_managed_payments", START, "2026-12-04")],
            as_of="2026-12-04", stripe_mode="cumulative"))
        self.assertEqual(out["total_net"], "586.00")


class ScopeAndProvenance(Base):
    """Item 10: the identity checks the old header claimed and the schema did not have."""

    def test_a_wrong_account_is_rejected_not_filtered(self):
        body = payload([report("apple-1", "app_store")],
                       [exact("0.00", "stripe-1", "stripe_managed_payments")])
        body["channels"][0]["reports"][0]["account"] = "APPLE-VENDOR-9999"
        self.rejects(body, "account-outside-scope")

    def test_a_wrong_vendor_is_rejected(self):
        body = payload([report("apple-1", "app_store")],
                       [exact("0.00", "stripe-1", "stripe_managed_payments")])
        body["channels"][0]["reports"][0]["vendor"] = "Someone Else Ltd"
        self.rejects(body, "vendor-outside-scope")

    def test_a_wrong_store_is_rejected(self):
        body = payload([exact("1.00", "apple-1", "app_store")],
                       [report("stripe-1", "stripe_managed_payments")])
        body["channels"][1]["reports"][0]["store"] = "LS-STORE-9999"
        self.rejects(body, "store-outside-scope")

    def test_a_store_on_a_channel_that_has_none_is_rejected(self):
        body = payload([report("apple-1", "app_store")],
                       [exact("0.00", "stripe-1", "stripe_managed_payments")])
        body["channels"][0]["reports"][0]["store"] = "LS-STORE-0001"
        self.rejects(body, "store-outside-scope")

    def test_a_product_outside_scope_is_rejected_not_filtered(self):
        # Rejecting rather than filtering is deliberate: filtering silently drops revenue
        # the operator believed was counted.
        body = payload([report("apple-1", "app_store", products=["SOME_OTHER_APP"])],
                       [exact("0.00", "stripe-1", "stripe_managed_payments")])
        self.rejects(body, "product-outside-scope")

    def test_scope_is_not_taken_from_inside_the_report_file(self):
        # The reconciliation schema has no allowlist field at all. Re-adding one would be
        # scope supplied by the document being scoped, which can never fail.
        self.assertNotIn("allowlist", pub.REPORT_KEYS)
        self.assertNotIn("allowlist", pub.CHANNEL_KEYS)
        self.assertNotIn("allowlist", pub.TOP_KEYS)

    def test_a_report_with_no_products_is_refused(self):
        body = payload([report("apple-1", "app_store", products=[])],
                       [exact("0.00", "stripe-1", "stripe_managed_payments")])
        self.rejects(body, "no-products-listed")

    def test_a_missing_source_fingerprint_is_refused(self):
        body = payload([report("apple-1", "app_store")],
                       [exact("0.00", "stripe-1", "stripe_managed_payments")])
        del body["channels"][0]["reports"][0]["source_sha256"]
        self.rejects(body, "unexpected-object-shape")

    def test_a_malformed_source_fingerprint_is_refused(self):
        for bad in ("", "abc", "A" * 64, "g" * 64, fingerprint("x") + "0"):
            body = payload([report("apple-1", "app_store", source=bad)],
                           [exact("0.00", "stripe-1", "stripe_managed_payments")])
            self.rejects(body, "not-a-sha256")

    def test_the_same_source_file_under_two_report_ids_is_refused(self):
        shared = fingerprint("the-same-provider-file")
        self.rejects(payload(
            [report("apple-1", "app_store", START, CUTOFF, source=shared),
             report("apple-2", "app_store", "2026-12-01", "2026-12-04", source=shared)],
            [exact("0.00", "stripe-1", "stripe_managed_payments", START, "2026-12-04")],
            as_of="2026-12-04"), "duplicate-source-report")

    def test_the_same_source_file_across_channels_is_refused(self):
        shared = fingerprint("the-same-provider-file")
        self.rejects(payload([report("apple-1", "app_store", source=shared)],
                             [report("stripe-1", "stripe_managed_payments", source=shared)]),
                     "duplicate-source-report")

    def test_a_duplicated_report_id_is_refused(self):
        self.rejects(payload(
            [report("same", "app_store", START, CUTOFF),
             report("same", "app_store", "2026-12-01", "2026-12-04",
                    source=fingerprint("other"))],
            [exact("0.00", "stripe-1", "stripe_managed_payments", START, "2026-12-04")],
            as_of="2026-12-04"), "duplicate-report-id")


class ForeignCurrency(Base):

    def gbp(self, **fx_over):
        fx = {"from_currency": "GBP", "rate": "1.2735",
              "source": "provider settlement statement", "date": CUTOFF}
        fx.update(fx_over)
        return payload([report(
            "apple-1", "app_store", currency="GBP", gross="100.00", discounts="0.00",
            customer_tax="0.00", fees="0.00", refunds="0.00", chargebacks="0.00",
            fx=fx)], [exact("0.00", "stripe-1", "stripe_managed_payments")])

    def test_a_recorded_rate_converts_once(self):
        self.assertEqual(self.build(self.gbp())["total_net"], "127.35")

    def test_rounding_the_converted_net_keeps_the_cents(self):
        out = self.build(payload([report(
            "apple-1", "app_store", currency="EUR", gross="33.33", discounts="0.00",
            customer_tax="0.00", fees="0.00", refunds="0.00", chargebacks="0.00",
            fx={"from_currency": "EUR", "rate": "1.085", "source": "s", "date": CUTOFF})],
            [exact("0.00", "stripe-1", "stripe_managed_payments")]))
        self.assertEqual(out["total_net"], "36.16")   # 36.16305 -> 36.16

    def test_a_non_usd_report_with_no_rate_and_no_settlement_is_refused(self):
        self.rejects(payload([report("apple-1", "app_store", currency="GBP")],
                             [exact("0.00", "stripe-1", "stripe_managed_payments")]),
                     "non-usd-without-fx-or-settlement")

    def test_a_provider_usd_settlement_is_accepted_instead_of_a_rate(self):
        out = self.build(payload(
            [report("apple-1", "app_store", currency="GBP", settlement_usd="700.00")],
            [exact("0.00", "stripe-1", "stripe_managed_payments")]))
        self.assertEqual(out["total_net"], "700.00")

    def test_both_a_rate_and_a_settlement_is_refused_as_ambiguous(self):
        body = self.gbp()
        body["channels"][0]["reports"][0]["settlement_usd"] = "700.00"
        self.rejects(body, "both-fx-and-settlement")

    def test_a_rate_on_a_usd_report_is_refused(self):
        body = payload([report("apple-1", "app_store",
                               fx={"from_currency": "USD", "rate": "1.0",
                                   "source": "s", "date": CUTOFF})],
                       [exact("0.00", "stripe-1", "stripe_managed_payments")])
        self.rejects(body, "fx-on-a-usd-report")

    def test_a_float_rate_is_refused(self):
        self.rejects(self.gbp(rate=1.2735), "numeric-fx-rate")

    def test_a_rate_for_the_wrong_currency_is_refused(self):
        self.rejects(self.gbp(from_currency="EUR"), "fx-currency-mismatch")

    def test_a_rate_with_no_source_is_refused(self):
        self.rejects(self.gbp(source=""), "not-a-nonempty-string")

    def test_a_rate_dated_before_the_period_ended_is_refused(self):
        self.rejects(self.gbp(date=START), "fx-date-precedes-period-end")

    def test_a_zero_rate_is_refused(self):
        self.rejects(self.gbp(rate="0.0"), "fx-rate-not-positive")


class TypeStrictness(Base):

    def test_a_json_number_in_a_money_field_is_refused(self):
        for value in (566, 566.0, 0.1):
            body = payload([report("apple-1", "app_store")],
                           [exact("0.00", "stripe-1", "stripe_managed_payments")])
            body["channels"][0]["reports"][0]["gross"] = value
            self.rejects(body, "numeric-money-field")

    def test_a_boolean_in_a_money_field_is_refused(self):
        body = payload([report("apple-1", "app_store")],
                       [exact("0.00", "stripe-1", "stripe_managed_payments")])
        body["channels"][0]["reports"][0]["fees"] = True
        self.rejects(body, "bool-in-money-field")

    def test_money_without_two_decimal_places_is_refused(self):
        for value in ("566", "566.0", "566.000", "1e3", ".50", "+5.00", "05.00", ""):
            body = payload([report("apple-1", "app_store")],
                           [exact("0.00", "stripe-1", "stripe_managed_payments")])
            body["channels"][0]["reports"][0]["gross"] = value
            self.rejects(body, "not-a-money-string")

    def test_an_impossible_negative_amount_is_refused(self):
        for field in pub.NON_NEGATIVE:
            body = payload([report("apple-1", "app_store")],
                           [exact("0.00", "stripe-1", "stripe_managed_payments")])
            body["channels"][0]["reports"][0][field] = "-1.00"
            self.rejects(body, "negative-amount-impossible")

    def test_an_unexpected_object_shape_is_refused_at_every_level(self):
        self.rejects(payload([], [], projected_total="999999.00"),
                     "unexpected-object-shape")
        body = payload([report("apple-1", "app_store", customer_note="x")],
                       [exact("0.00", "stripe-1", "stripe_managed_payments")])
        self.rejects(body, "unexpected-object-shape")
        body = payload([], [])
        body["channels"][0]["notes"] = "x"
        self.rejects(body, "unexpected-object-shape")

    def test_the_wrong_schema_is_refused(self):
        body = payload([], [])
        body["schema"] = "cliphoard.net-sales/2"
        self.rejects(body, "wrong-input-schema")
        bad_scope = scope_payload(schema="something-else")
        with self.assertRaises(pub.Rejected) as caught:
            pub.build_scope(bad_scope)
        self.assertEqual(caught.exception.code, "wrong-scope-schema")

    def test_a_reporting_currency_other_than_usd_is_refused(self):
        body = payload([], [])
        body["currency"] = "GBP"
        self.rejects(body, "reporting-currency-must-be-usd")

    def test_an_unknown_report_mode_is_refused(self):
        self.rejects(payload([], [], app_mode="estimate"), "unknown-report-mode")


class DuplicateJSONKeys(unittest.TestCase):
    """Item 11: last-wins parsing means the value a reviewer reads need not be the value
    the tool uses."""

    def load(self, text):
        with tempfile.TemporaryDirectory() as outside:
            path = Path(outside) / "in.json"
            path.write_text(text, encoding="utf-8")
            return pub.load_private_json(path, "--input")

    def test_a_repeated_key_is_refused_rather_than_taking_the_last(self):
        for text in ('{"gross": "1.00", "gross": "9999.00"}',
                     '{"report_id": "a", "report_id": "b"}',
                     '{"channels": [], "channels": [1]}',
                     '{"a": {"b": 1, "b": 2}}',
                     '{"a": [{"b": 1, "b": 2}]}'):
            with self.assertRaises(pub.Rejected) as caught:
                self.load(text)
            self.assertEqual(caught.exception.code, "duplicate-json-key")

    def test_distinct_keys_and_repeated_keys_in_sibling_objects_are_fine(self):
        self.assertEqual(self.load('{"a": 1, "b": 2}'), {"a": 1, "b": 2})
        self.assertEqual(self.load('[{"a": 1}, {"a": 2}]'), [{"a": 1}, {"a": 2}])

    def test_the_repeated_key_name_is_never_reported(self):
        secret = "order-id-99887766@example.com"
        with self.assertRaises(pub.Rejected) as caught:
            self.load('{"%s": 1, "%s": 2}' % (secret, secret))
        self.assertNotIn(secret, str(caught.exception))


class Privacy(Base):
    """Item 11: what must NOT come out, in the output or in an error."""

    SECRETS = {
        "account": "APPLE-VENDOR-0001",
        "ls_account": "LS-ACCT-0001",
        "store": "LS-STORE-0001",
        "vendor": "Example Vendor Ltd",
        "sku": "CLIPHOARD_PRO",
        "product": "pro:default",
        "report": "apple-financial-2026-11-abc123",
    }

    def aggregate(self):
        return self.build(payload(
            [report(self.SECRETS["report"], "app_store")],
            [report("stripe-1", "stripe_managed_payments")]))

    def test_no_identifier_survives_into_the_published_json(self):
        serialized = json.dumps(self.aggregate())
        for name, value in self.SECRETS.items():
            self.assertNotIn(value, serialized, f"{name} leaked into the public file")

    def test_no_source_fingerprint_survives(self):
        serialized = json.dumps(self.aggregate())
        self.assertNotIn(fingerprint(self.SECRETS["report"]), serialized)
        self.assertNotIn("source_sha256", serialized)

    def test_no_raw_component_of_the_arithmetic_survives(self):
        serialized = json.dumps(self.aggregate())
        for field in pub.NON_NEGATIVE + pub.SIGNED + (
                "provider_reported_net", "fx", "account", "vendor", "store", "products"):
            self.assertNotIn(f'"{field}"', serialized)

    def test_the_published_shape_is_exactly_the_allowlist(self):
        out = self.aggregate()
        self.assertEqual(set(out), {
            "schema", "status", "currency", "goal", "total_net", "campaign_start",
            "as_of", "generated", "basis", "coverage", "channels"})
        for ch in out["channels"]:
            self.assertEqual(set(ch), {"id", "status", "net", "as_of"})
        self.assertEqual(set(out["coverage"]), {"reports", "start", "end"})

    def test_there_is_no_label_field_to_copy_an_arbitrary_string_through(self):
        # Public names come from a constant map in the renderer. The private schemas have
        # no `label`, so there is nothing operator-supplied to carry out.
        self.assertNotIn("label", pub.CHANNEL_KEYS)
        self.assertNotIn("label", pub.SCOPE_CHANNEL_KEYS)
        for ch in self.aggregate()["channels"]:
            self.assertNotIn("label", ch)
        self.assertEqual(set(pub.CHANNEL_LABELS), set(pub.CANONICAL_CHANNELS))

    def test_a_secret_in_an_unknown_key_never_reaches_an_error(self):
        secret_key = "customer_email_jane.doe+orders@example.com"
        secret_value = "ORDER-4455-6677"
        body = payload([report("apple-1", "app_store")],
                       [exact("0.00", "stripe-1", "stripe_managed_payments")])
        body["channels"][0]["reports"][0][secret_key] = secret_value
        with self.assertRaises(pub.Rejected) as caught:
            pub.build_aggregate(body, scopes(), today=TODAY)
        message = str(caught.exception)
        self.assertEqual(caught.exception.code, "unexpected-object-shape")
        self.assertNotIn(secret_key, message)
        self.assertNotIn(secret_value, message)
        self.assertNotIn("jane.doe", message)

    def test_a_secret_in_a_rejected_value_never_reaches_an_error(self):
        secret = "4111111111111111.00"
        body = payload([report("apple-1", "app_store", gross=secret)],
                       [exact("0.00", "stripe-1", "stripe_managed_payments")])
        with self.assertRaises(pub.Rejected) as caught:
            pub.build_aggregate(body, scopes(), today=TODAY)
        self.assertNotIn(secret, str(caught.exception))
        self.assertIn("gross", str(caught.exception))

    def test_a_secret_in_a_scope_label_position_never_reaches_an_error(self):
        secret = "jane.doe+apple@example.com"
        body = scope_payload()
        body["channels"][0]["account"] = secret
        reconciliation = payload([report("apple-1", "app_store")],
                                 [exact("0.00", "stripe-1", "stripe_managed_payments")])
        with self.assertRaises(pub.Rejected) as caught:
            pub.build_aggregate(reconciliation, pub.build_scope(body), today=TODAY)
        self.assertEqual(caught.exception.code, "account-outside-scope")
        self.assertNotIn(secret, str(caught.exception))

    def test_an_unparseable_private_file_does_not_echo_its_contents(self):
        with tempfile.TemporaryDirectory() as outside:
            bad = Path(outside) / "recon.json"
            bad.write_text('{"gross": 4111111111111111.00, ', encoding="utf-8")
            with self.assertRaises(pub.Rejected) as caught:
                pub.load_private_json(bad, "--input")
        self.assertEqual(caught.exception.code, "not-valid-json")
        self.assertNotIn("4111111111111111", str(caught.exception))


# ── the CLI ──────────────────────────────────────────────────────────────────

def run_cli(argv):
    """Run `main` and capture stderr, so the CLI's own refusals are tested too."""
    import io
    import contextlib
    err, out = io.StringIO(), io.StringIO()
    with contextlib.redirect_stderr(err), contextlib.redirect_stdout(out):
        code = pub.main(argv)
    return code, err.getvalue(), out.getvalue()


class PrivateFiles(unittest.TestCase):

    def setUp(self):
        self.outside = tempfile.TemporaryDirectory()
        base = Path(self.outside.name)
        self.scope = base / "scope.json"
        self.scope.write_text(json.dumps(scope_payload()), encoding="utf-8")
        self.input = base / "recon.json"
        self.input.write_text(json.dumps(payload([], [])), encoding="utf-8")

    def tearDown(self):
        self.outside.cleanup()

    def args(self, **over):
        argv = {"--scope": str(self.scope), "--input": str(self.input),
                "--output": str(pub.CANONICAL_OUTPUT), "--today": TODAY}
        argv.update(over)
        return [x for pair in argv.items() for x in pair] + ["--dry-run"]

    def test_the_happy_dry_run_validates_and_writes_nothing(self):
        before = pub.CANONICAL_OUTPUT.read_bytes()
        code, err, out = run_cli(self.args())
        self.assertEqual(code, 0, err)
        self.assertEqual(json.loads(out)["status"], "unavailable")
        self.assertEqual(pub.CANONICAL_OUTPUT.read_bytes(), before)

    def test_a_private_input_inside_the_repository_is_refused(self):
        # A reconciliation file committed once is in the history forever.
        inside = REPO / "docs" / "data" / "_test_recon.json"
        inside.write_text(json.dumps(payload([], [])), encoding="utf-8")
        try:
            code, err, _ = run_cli(self.args(**{"--input": str(inside)}))
            self.assertEqual(code, 2)
            self.assertIn("private-file-inside-the-repository", err)
        finally:
            inside.unlink()

    def test_a_scope_file_inside_the_repository_is_refused(self):
        inside = REPO / "docs" / "data" / "_test_scope.json"
        inside.write_text(json.dumps(scope_payload()), encoding="utf-8")
        try:
            code, err, _ = run_cli(self.args(**{"--scope": str(inside)}))
            self.assertEqual(code, 2)
            self.assertIn("private-file-inside-the-repository", err)
        finally:
            inside.unlink()

    def test_scope_and_input_may_not_be_the_same_file(self):
        code, err, _ = run_cli(self.args(**{"--scope": str(self.input)}))
        self.assertEqual(code, 2)
        self.assertIn("scope-and-input-are-the-same-file", err)

    def test_the_output_must_be_the_canonical_public_file(self):
        # Not "any path inside the repo": an --output typo landing on README.md or on a
        # Swift source would be a destructive edit by a tool nobody expects there.
        for target in ("README.md", "PRIVACY.md", "docs/index.html",
                       "docs/assets/funding.js",
                       "Sources/Cliphoard/Support/Licence.swift",
                       "docs/data/other.json", "docs/CNAME"):
            path = REPO / target
            before = path.read_bytes() if path.exists() else None
            code, err, _ = run_cli(self.args(**{"--output": str(path)}))
            self.assertEqual(code, 2, f"{target} was accepted as an output")
            self.assertIn("output-is-not-the-canonical-public-file", err)
            if before is not None:
                self.assertEqual(path.read_bytes(), before, f"{target} was modified")

    def test_an_output_outside_the_repository_is_refused(self):
        code, err, _ = run_cli(
            self.args(**{"--output": str(Path(self.outside.name) / "public.json")}))
        self.assertEqual(code, 2)
        self.assertIn("output-is-not-the-canonical-public-file", err)

    def test_a_missing_private_file_is_refused_without_a_traceback(self):
        code, err, _ = run_cli(
            self.args(**{"--input": str(Path(self.outside.name) / "nope.json")}))
        self.assertEqual(code, 2)
        self.assertIn("not-a-file", err)

    def test_a_rejection_exits_two_and_names_no_value(self):
        body = payload([report("apple-1", "app_store", gross="4111111111111111.00")],
                       [exact("0.00", "stripe-1", "stripe_managed_payments")])
        self.input.write_text(json.dumps(body), encoding="utf-8")
        code, err, _ = run_cli(self.args())
        self.assertEqual(code, 2)
        self.assertNotIn("4111111111111111", err)


class AtomicWriter(unittest.TestCase):
    """The writer is exercised against temp files directly, because the CLI is restricted
    to the one canonical output and this test must not touch it."""

    def test_the_write_replaces_the_previous_file_and_leaves_no_temp(self):
        with tempfile.TemporaryDirectory() as box:
            target = Path(box) / "net-sales.json"
            target.write_text("PREVIOUS", encoding="utf-8")
            pub.write_atomically(target, pub.unavailable_aggregate(TODAY))
            self.assertEqual(json.loads(target.read_text())["status"], "unavailable")
            leftovers = [p.name for p in Path(box).iterdir() if p.name != "net-sales.json"]
            self.assertEqual(leftovers, [], f"temp files left behind: {leftovers}")

    def test_a_failed_serialization_leaves_the_previous_file_untouched(self):
        with tempfile.TemporaryDirectory() as box:
            target = Path(box) / "net-sales.json"
            target.write_text("PREVIOUS", encoding="utf-8")
            with self.assertRaises(TypeError):
                pub.write_atomically(target, {"bad": {1, 2}})   # a set is not JSON
            self.assertEqual(target.read_text(encoding="utf-8"), "PREVIOUS")
            leftovers = [p.name for p in Path(box).iterdir() if p.name != "net-sales.json"]
            self.assertEqual(leftovers, [], f"temp files left behind: {leftovers}")


class ShippedDefault(Base):
    """The file that is actually on the website right now."""

    def shipped(self):
        return json.loads(pub.CANONICAL_OUTPUT.read_text(encoding="utf-8"))

    def test_the_shipped_default_claims_nothing(self):
        d = self.shipped()
        self.assertEqual(d["status"], "unavailable")
        self.assertIsNone(d["total_net"])
        self.assertIsNone(d["as_of"])
        self.assertIsNone(d["campaign_start"])
        self.assertEqual(d["coverage"]["reports"], 0)
        self.assertEqual(d["goal"], "250000.00")
        self.assertEqual({c["status"] for c in d["channels"]}, {"no_reports"})
        self.assertTrue(all(c["net"] is None for c in d["channels"]))

    def test_the_shipped_default_makes_no_claim_about_any_shop(self):
        # `not_live` was removed from the schema because it asserted something this tool
        # cannot know: that a channel is closed.
        raw = pub.CANONICAL_OUTPUT.read_text(encoding="utf-8")
        for claim in ("not_live", "closed", "no_sales", "nothing sold", "not open"):
            self.assertNotIn(claim, raw)

    def test_the_shipped_default_carries_no_fixture_amount(self):
        raw = pub.CANONICAL_OUTPUT.read_text(encoding="utf-8")
        for amount in ("1038.50", "566.00", "472.50", "249999.99", "250000.01",
                       "500000.00", "127.35", "36.16", "999999999999.99"):
            self.assertNotIn(amount, raw, f"fixture amount {amount} reached production")
        self.assertNotIn('"total_net": "0.00"', raw)

    def test_the_shipped_default_is_exactly_what_the_publisher_emits(self):
        produced = pub.unavailable_aggregate(self.shipped()["generated"])
        self.assertEqual(self.shipped(), produced)

    def test_the_shipped_default_is_not_dated_in_the_future(self):
        generated = dt.date.fromisoformat(self.shipped()["generated"])
        self.assertLessEqual(generated, dt.datetime.now(dt.timezone.utc).date())


class CrossLanguage(Base):
    """Item 13: the publisher's REAL output must satisfy the REAL JS renderer.

    Two independent implementations of the same money rules drift unless something
    actually runs both. This hands Python's output to Node's `fundingView` and asserts a
    great deal more than `ok`: that the exact cents agree, that every date the renderer
    reports back matches the aggregate, that coverage really reaches the campaign start,
    that the report count can account for both channels, and that the below / exactly /
    past-goal semantics are the same on both sides.
    """

    NODE = "/usr/local/bin/node"

    @classmethod
    def setUpClass(cls):
        version = subprocess.run([cls.NODE, "--version"], check=True, capture_output=True,
                                 text=True, timeout=10, env={**os.environ, "NODE_OPTIONS": ""})
        if version.stdout.strip() != "v24.11.0":
            raise RuntimeError("cross-language checks require verified Node v24.11.0")

    def render(self, aggregate, today=TODAY):
        script = REPO / "Tests" / "site" / "_render_check.mjs"
        result = subprocess.run(
            [self.NODE, str(script), today],
            input=json.dumps(aggregate), capture_output=True, text=True,
            cwd=str(REPO), timeout=60, env={**os.environ, "NODE_OPTIONS": ""})
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def cents(self, amount: str) -> int:
        """Exact integer cents from a decimal string, without going through a float."""
        sign = -1 if amount.startswith("-") else 1
        whole, frac = amount.lstrip("-").split(".")
        return sign * (int(whole) * 100 + int(frac))

    def assertAgrees(self, aggregate, view, today=TODAY):
        """Everything the two implementations must say identically about one aggregate."""
        self.assertTrue(view["ok"], f"the renderer refused real output: {view}")

        if aggregate["status"] == "unavailable":
            # NULL ONLY FOR THE UNAVAILABLE STATE, on both sides.
            self.assertIsNone(aggregate["total_net"])
            self.assertIsNone(view["totalCents"])
            self.assertIsNone(view["totalText"])
            self.assertIsNone(view["percentText"])
            self.assertEqual(view["state"], "unavailable")
            self.assertEqual(view["barPercent"], 0)
            self.assertEqual(view["coverage"]["reports"], 0)
            self.assertTrue(all(c["amountText"] is None for c in view["channels"]))
            return

        # EXACT CENTS, and the total really is the channel sum.
        total = self.cents(aggregate["total_net"])
        channel_sum = sum(self.cents(c["net"]) for c in aggregate["channels"])
        self.assertEqual(total, channel_sum, "the publisher's own channels do not sum")
        self.assertEqual(view["totalCents"], total, "the renderer read a different total")
        self.assertEqual(sum(self.cents(c["net"]) for c in aggregate["channels"]),
                         view["totalCents"])

        # NEGATIVE ZERO IS CANONICAL on both sides.
        self.assertNotIn("-0.00", json.dumps(aggregate))
        if total == 0:
            self.assertEqual(aggregate["total_net"], "0.00")
            self.assertEqual(view["totalText"], "$0.00")
            self.assertEqual(view["state"], "zero")

        # DATES AGREE, globally, per channel and in the coverage window.
        self.assertEqual(view["asOf"], aggregate["as_of"])
        self.assertEqual(view["generated"], aggregate["generated"])
        self.assertEqual(view["campaignStart"], aggregate["campaign_start"])
        self.assertEqual(view["coverage"]["start"], aggregate["coverage"]["start"])
        self.assertEqual(view["coverage"]["end"], aggregate["coverage"]["end"])
        for channel in aggregate["channels"]:
            self.assertEqual(channel["as_of"], aggregate["as_of"],
                             "a channel is reconciled to a different date")

        # FULL COVERAGE: it starts where the campaign starts and ends at the cutoff.
        self.assertEqual(aggregate["coverage"]["start"], aggregate["campaign_start"])
        self.assertEqual(aggregate["coverage"]["end"], aggregate["as_of"])

        # A COMPATIBLE REPORT COUNT: every evidenced channel contributes at least one.
        self.assertGreaterEqual(aggregate["coverage"]["reports"],
                                len(pub.CANONICAL_CHANNELS))
        self.assertEqual(view["coverage"]["reports"], aggregate["coverage"]["reports"])

        # GOAL SEMANTICS, decided by the cents on both sides.
        goal = self.cents(aggregate["goal"])
        self.assertEqual(goal, 25000000)
        self.assertEqual(view["atOrPastGoal"], total >= goal)
        if total > goal:
            self.assertEqual(view["beyondCents"], total - goal)
        else:
            self.assertIsNone(view["beyondCents"])
        if total < goal:
            self.assertNotEqual(view["percentText"], "100%",
                                "a total below the goal was presented as 100%")
        self.assertLessEqual(view["barPercent"], 100)
        self.assertGreaterEqual(view["barPercent"], 0)

    def test_the_unavailable_payload_agrees_across_both_implementations(self):
        aggregate = pub.unavailable_aggregate(TODAY)
        self.assertAgrees(aggregate, self.render(aggregate))

    def test_the_shipped_production_file_agrees_across_both_implementations(self):
        aggregate = json.loads(pub.CANONICAL_OUTPUT.read_text(encoding="utf-8"))
        view = self.render(aggregate, today=TODAY)
        self.assertAgrees(aggregate, view)

    def test_every_boundary_aggregate_agrees_across_both_implementations(self):
        for app, stripe, expected_total, expected_text, expected_percent in (
                ("566.00", "472.50", "1038.50", "$1,038.50", "0.4%"),
                ("0.00", "0.00", "0.00", "$0.00", "0%"),
                ("0.01", "0.00", "0.01", "$0.01", "less than 0.1%"),
                ("124999.99", "125000.00", "249999.99", "$249,999.99", "99.9%"),
                ("125000.00", "125000.00", "250000.00", "$250,000.00", "100%"),
                ("250000.01", "0.00", "250000.01", "$250,000.01", "100%"),
                ("250000.00", "250000.00", "500000.00", "$500,000.00", "200%"),
                ("-625.40", "500.00", "-125.40", "-$125.40", "below zero after refunds"),
                ("999999999999.99", "0.00", "999999999999.99",
                 "$999,999,999,999.99", "400000000%"),
        ):
            aggregate = self.build(both(app, stripe))
            self.assertEqual(aggregate["total_net"], expected_total)
            view = self.render(aggregate)
            self.assertAgrees(aggregate, view)
            self.assertEqual(view["totalText"], expected_text)
            self.assertEqual(view["percentText"], expected_percent,
                             f"percent text for {expected_total}")

    def test_a_cent_short_of_the_goal_is_not_presented_as_reached(self):
        # The defect this pins: 249999.99 of 250000.00 rounds to 100.0% and would say the
        # goal was met. The cents are the authority on both sides.
        aggregate = self.build(both("249999.99", "0.00"))
        view = self.render(aggregate)
        self.assertEqual(view["atOrPastGoal"], False)
        self.assertEqual(view["percentText"], "99.9%")
        self.assertIsNone(view["beyondCents"])
        self.assertLess(view["barPercent"], 100)

    def test_the_exact_excess_survives_the_round_trip_to_the_cent(self):
        for app, excess in (("250000.01", 1), ("250123.45", 12345), ("500000.00", 25000000)):
            view = self.render(self.build(both(app, "0.00")))
            self.assertEqual(view["beyondCents"], excess, f"excess for {app}")

    def test_a_negative_zero_round_trips_as_positive_zero(self):
        aggregate = self.build(both("-0.00", "0.00"))
        self.assertEqual(aggregate["total_net"], "0.00")
        view = self.render(aggregate)
        self.assertAgrees(aggregate, view)
        self.assertEqual(view["totalText"], "$0.00")

    def test_multi_period_coverage_agrees_on_the_report_count_and_the_window(self):
        aggregate = self.build(payload(
            [exact("10.00", "apple-1", "app_store", START, CUTOFF),
             exact("10.00", "apple-2", "app_store", "2026-12-01", "2026-12-04")],
            [exact("5.00", "stripe-1", "stripe_managed_payments", START, "2026-12-04")],
            as_of="2026-12-04"))
        self.assertEqual(aggregate["coverage"], {"reports": 3, "start": START,
                                                 "end": "2026-12-04"})
        self.assertAgrees(aggregate, self.render(aggregate))

    def test_the_renderer_refuses_a_tampered_version_of_real_output(self):
        # The round trip proving acceptance is only meaningful if the same path REFUSES a
        # payload that should be refused.
        aggregate = self.build(both("1000.00", "0.00"))
        for mutate, reason in (
                (lambda a: a.update(total_net="2000.00"), "total_net"),
                (lambda a: a.update(goal="250000.01"), "goal"),
                (lambda a: a["coverage"].update(reports=1), "coverage-reports"),
                (lambda a: a.update(as_of="2027-01-01"), "as_of"),
                (lambda a: a["channels"][1].update(status="no_reports", net=None,
                                                   as_of=None),
                 "incomplete-channel-evidence"),
        ):
            tampered = json.loads(json.dumps(aggregate))
            mutate(tampered)
            view = self.render(tampered)
            self.assertFalse(view["ok"], f"a tampered payload was accepted: {reason}")
            self.assertEqual(view["reason"], reason)


class CalendarDates(Base):
    """A date must PARSE, not merely match a shape. `2026-02-31` matches the regex."""

    def test_an_impossible_date_anywhere_in_the_input_is_refused(self):
        for field in ("campaign_start", "as_of"):
            body = both("1.00", "0.00")
            body[field] = "2026-02-31"
            self.rejects(body, "not-a-calendar-date")
        body = both("1.00", "0.00")
        body["channels"][0]["reports"][0]["period_end"] = "2026-02-31"
        self.rejects(body, "not-a-calendar-date")

    def test_an_impossible_asserted_campaign_start_refuses_without_a_traceback(self):
        # This used to reach `fromisoformat` unguarded and raise ValueError, which is a
        # traceback rather than a refusal — and a traceback carries a stack with paths.
        with self.assertRaises(pub.Rejected) as caught:
            pub.build_aggregate(both("1.00", "0.00"), scopes(), today=TODAY,
                                expect_campaign_start="2026-02-31")
        self.assertEqual(caught.exception.code, "not-a-calendar-date")
        self.assertEqual(caught.exception.where, "--campaign-start")

    def test_the_unavailable_payload_will_not_carry_an_impossible_generation_date(self):
        # It is a PUBLIC artefact; emitting 2026-02-31 as its date would publish an
        # impossibility.
        for bad in ("2026-02-31", "2027-02-29", "2026-13-01", "nope", ""):
            with self.assertRaises(pub.Rejected) as caught:
                pub.unavailable_aggregate(bad)
            self.assertIn(caught.exception.code, ("not-a-date", "not-a-calendar-date"))
        self.assertEqual(pub.unavailable_aggregate("2026-02-28")["generated"],
                         "2026-02-28")


class ChannelScopeIdentity(Base):
    """Each channel's identity has a different shape, and the scope must match it."""

    def test_the_app_store_scope_may_not_carry_a_store(self):
        # Apple has no store concept, so a value there means the operator normalized the
        # wrong field — and a wrong field in scope makes every later check meaningless.
        body = scope_payload()
        body["channels"][0]["store"] = "LS-STORE-0001"
        with self.assertRaises(pub.Rejected) as caught:
            pub.build_scope(body)
        self.assertEqual(caught.exception.code,
                         "app-store-scope-must-not-carry-a-store")

    def test_the_stripe_managed_payments_scope_must_not_carry_a_store(self):
        for invalid in ("LS-STORE-0001", "", "   ", 1, False):
            body = scope_payload()
            body["channels"][1]["store"] = invalid
            with self.assertRaises(pub.Rejected) as caught:
                pub.build_scope(body)
            self.assertEqual(caught.exception.code,
                             "stripe-scope-must-not-carry-a-store", f"for {invalid!r}")

    def test_the_correct_shapes_are_accepted(self):
        built = scopes()
        self.assertIsNone(built["app_store"].store)
        self.assertIsNone(built["stripe_managed_payments"].store)

    def test_a_store_rejection_never_echoes_the_identifier(self):
        secret = "store-99887766-acme-ltd"
        body = scope_payload()
        body["channels"][0]["store"] = secret
        with self.assertRaises(pub.Rejected) as caught:
            pub.build_scope(body)
        self.assertNotIn(secret, str(caught.exception))


class TodayIsNotOverridableInProduction(unittest.TestCase):
    """`today` bounds every future-date refusal, so an override is a way to publish a
    file dated in the future. It is confined to --dry-run."""

    def setUp(self):
        self.outside = tempfile.TemporaryDirectory()
        base = Path(self.outside.name)
        self.scope = base / "scope.json"
        self.scope.write_text(json.dumps(scope_payload()), encoding="utf-8")
        self.input = base / "recon.json"
        # A campaign start in the past, because two of these cases run against the ACTUAL
        # UTC clock rather than an injected date.
        self.input.write_text(json.dumps(payload([], [], campaign_start="2026-01-01",
                                                 as_of="2026-01-01")), encoding="utf-8")
        self.before = pub.CANONICAL_OUTPUT.read_bytes()

    def tearDown(self):
        self.assertEqual(pub.CANONICAL_OUTPUT.read_bytes(), self.before,
                         "the production file was modified by a CLI test")
        self.outside.cleanup()

    def argv(self, *extra):
        return ["--scope", str(self.scope), "--input", str(self.input),
                "--output", str(pub.CANONICAL_OUTPUT), *extra]

    def test_a_future_today_without_dry_run_refuses_and_writes_nothing(self):
        future = (dt.datetime.now(dt.timezone.utc).date()
                  + dt.timedelta(days=365)).isoformat()
        code, err, _ = run_cli(self.argv("--today", future))
        self.assertEqual(code, 2)
        self.assertIn("today-override-requires-dry-run", err)

    def test_any_today_without_dry_run_refuses(self):
        for value in ("2026-01-02", dt.datetime.now(dt.timezone.utc).date().isoformat()):
            code, err, _ = run_cli(self.argv("--today", value))
            self.assertEqual(code, 2, f"--today {value} was accepted for a real write")
            self.assertIn("today-override-requires-dry-run", err)

    def test_a_dry_run_may_override_today_and_is_marked_synthetic(self):
        code, err, out = run_cli(self.argv("--today", "2026-01-02", "--dry-run"))
        self.assertEqual(code, 0, err)
        self.assertIn("SYNTHETIC DRY RUN", err)
        self.assertIn("synthetic", json.loads(out))
        self.assertEqual(json.loads(out)["generated"], "2026-01-02")

    def test_a_dry_run_without_an_override_is_not_marked_synthetic(self):
        code, err, out = run_cli(self.argv("--dry-run"))
        self.assertEqual(code, 0, err)
        self.assertNotIn("SYNTHETIC", err)
        self.assertNotIn("synthetic", json.loads(out))

    def test_a_real_publication_would_carry_the_actual_utc_date(self):
        # Asserted on the SOURCE rather than by writing the production file: the only
        # `today` a non-dry run can reach is `datetime.now(timezone.utc)`.
        source = (REPO / "tools/funding/publish_net_sales.py").read_text(encoding="utf-8")
        self.assertIn("args.today or dt.datetime.now(dt.timezone.utc).date().isoformat()",
                      source)
        self.assertIn("today-override-requires-dry-run", source)


class UnreadableInput(unittest.TestCase):
    """`UnicodeDecodeError` stringifies with the offending BYTES in it."""

    def test_invalid_utf8_refuses_with_no_content_in_the_message(self):
        with tempfile.TemporaryDirectory() as outside:
            path = Path(outside) / "recon.json"
            # A valid JSON skeleton with a latin-1 encoded secret inside it, so the
            # decoder fails partway through real-looking private content.
            path.write_bytes(b'{"account": "ACME-\xff\xfe-9911", "gross": "1.00"}')
            with self.assertRaises(pub.Rejected) as caught:
                pub.load_private_json(path, "--input")
        message = str(caught.exception)
        self.assertEqual(caught.exception.code, "not-valid-utf8")
        self.assertNotIn("ACME", message)
        self.assertNotIn("9911", message)
        self.assertNotIn("0xff", message)
        self.assertNotIn("byte", message.lower())

    def test_a_directory_in_place_of_a_file_refuses_without_a_traceback(self):
        with tempfile.TemporaryDirectory() as outside:
            with self.assertRaises(pub.Rejected) as caught:
                pub.load_private_json(Path(outside), "--input")
        self.assertEqual(caught.exception.code, "unreadable-file")


class NoProviderIntegrationIsClaimed(unittest.TestCase):
    """A passing suite here must not be mistaken for evidence about a real store."""

    def test_the_tool_contains_no_http_client_and_no_provider_endpoint(self):
        source = (REPO / "tools" / "funding" / "publish_net_sales.py").read_text(encoding="utf-8")
        code = "\n".join(line for line in source.split("\n")
                         if not line.lstrip().startswith("#"))
        for forbidden in ("urllib", "requests", "http.client", "socket",
                          "api.appstoreconnect", "api.stripe.com", "api.lemonsqueezy", "Bearer "):
            self.assertNotIn(forbidden, code,
                             f"{forbidden} would make this an integration, which it is not")

    def test_the_readme_says_so_explicitly(self):
        readme = (REPO / "tools" / "funding" / "README.md").read_text(encoding="utf-8").lower()
        self.assertIn("by hand", readme)
        self.assertIn("remaining work", readme)
        self.assertIn("says nothing", readme)


if __name__ == "__main__":
    unittest.main(verbosity=2)
