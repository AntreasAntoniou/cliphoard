/* The browser-side money rules and the DOM reset, tested against the SHIPPED module.
 *
 * This imports `docs/assets/funding.js` directly — the same file the page loads and the
 * same file `Tests/site/preview.html` drives. No bundler, no transpile, no test double
 * for the module under test. That is possible because `fundingView` is pure and the DOM
 * half is separate.
 *
 * The reset suite at the bottom uses a MINIMAL DOM STUB, not a browser. It is built from
 * the real slots and the real static text in `docs/index.html`, so it cannot drift from
 * the shipped markup — but it is a stub, and it is labelled as one. Root owns the live
 * Chrome pass.
 *
 * Run:  node --test Tests/site/test_funding_render.mjs
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const REPO = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const mod = await import(new URL("../../docs/assets/funding.js", import.meta.url));
const { fundingView, applyFundingView, resetFundingView, progress, toCents, formatUSD,
        coverageSentence, hasDuplicateKeys, SCHEMA, STALE_AFTER_DAYS, GOAL_CENTS,
        GOAL_LABEL, MAX_CENTS, CHANNEL_IDS, CHANNEL_LABELS,
        NEUTRAL_FIGURE, NEUTRAL_CHANNEL, NEUTRAL_STATUS, NEUTRAL_ASOF } = mod;

const TODAY = "2026-12-05";
const START = "2026-11-01";
const CUTOFF = "2026-11-30";
const INDEX = readFileSync(join(REPO, "docs/index.html"), "utf8");

/** A payload with BOTH channels reporting, valid by construction. */
function payload(over = {}) {
  return {
    schema: SCHEMA,
    status: "reported",
    currency: "USD",
    goal: "250000.00",
    total_net: "1038.50",
    campaign_start: START,
    as_of: CUTOFF,
    generated: "2026-12-02",
    basis: "test basis",
    coverage: { reports: 2, start: START, end: CUTOFF },
    channels: [
      { id: "app_store", status: "reported", net: "566.00", as_of: CUTOFF },
      { id: "lemon_squeezy", status: "reported", net: "472.50", as_of: CUTOFF },
    ],
    ...over,
  };
}

/** A complete two-channel campaign whose channels net exactly these amounts. */
function both(appAmount, lemonAmount, over = {}) {
  const sum = toCents(appAmount) + toCents(lemonAmount);
  const channel = (id, amount) => ({
    id,
    status: toCents(amount) === 0 ? "certified_zero" : "reported",
    net: amount,
    as_of: CUTOFF,
  });
  return payload({
    status: sum === 0 ? "certified_zero" : "reported",
    total_net: formatUSD(sum).replace(/[$,]/g, ""),
    channels: [channel("app_store", appAmount), channel("lemon_squeezy", lemonAmount)],
    ...over,
  });
}

/** The absent case: no reports anywhere. Built from missing evidence, never from zero. */
function absent(over = {}) {
  return payload({
    status: "unavailable",
    total_net: null,
    campaign_start: null,
    as_of: null,
    coverage: { reports: 0, start: null, end: null },
    channels: CHANNEL_IDS.map((id) => ({ id, status: "no_reports", net: null, as_of: null })),
    ...over,
  });
}

function refuses(bad, reason, note = "") {
  const view = fundingView(bad, TODAY);
  assert.equal(view.ok, false, `accepted: ${note || reason}`);
  assert.equal(view.state, "unavailable");
  if (reason) assert.equal(view.reason, reason, `wrong reason for ${note || reason}`);
  assert.equal(view.totalCents, undefined);
  assert.equal(view.barPercent, undefined);
  assert.equal(view.percentText, undefined);
}

/* ── money primitives ─────────────────────────────────────────────────────── */

test("decimal strings parse to exact integer cents", () => {
  assert.equal(toCents("0.30"), 30);
  assert.equal(toCents("250000.00"), GOAL_CENTS);
  assert.equal(toCents("249999.99"), 24999999);
  assert.equal(toCents("-125.40"), -12540);
  assert.equal(toCents("0.00"), 0);
  assert.equal(toCents("999999999999.99"), MAX_CENTS);
});

test("anything that is not a two-decimal string is not money", () => {
  for (const bad of [0.3, 1038.5, 250000, true, false, null, undefined, {}, [],
                     "0.3", "1038.5", "1,038.50", "$10.00", "1e3", ".50", "+5.00",
                     "05.00", "", " 1.00", "1.00 ", "NaN", "Infinity",
                     "1000000000000.00"]) {
    assert.equal(toCents(bad), null, `${JSON.stringify(bad)} was accepted as money`);
  }
});

test("negative zero canonicalizes to positive zero", () => {
  assert.equal(toCents("-0.00"), 0);
  assert.ok(Object.is(toCents("-0.00"), 0), "produced -0 rather than 0");
  assert.equal(formatUSD(toCents("-0.00")), "$0.00");
});

test("formatting keeps the cents and groups the thousands", () => {
  assert.equal(formatUSD(GOAL_CENTS), "$250,000.00");
  assert.equal(formatUSD(24999999), "$249,999.99");
  assert.equal(formatUSD(25000001), "$250,000.01");
  assert.equal(formatUSD(0), "$0.00");
  assert.equal(formatUSD(5), "$0.05");
  assert.equal(formatUSD(-12540), "-$125.40");
  assert.equal(formatUSD(MAX_CENTS), "$999,999,999,999.99");
});

/* ── the percentage, which the cents decide ───────────────────────────────── */

test("a cent short of the goal is never promoted to 100%", () => {
  // The defect this replaces: 24999999/25000000 is 99.999996%, which rounds to 100.0 and
  // says the goal was met when it was one cent short.
  const p = progress(24999999);
  assert.equal(p.atOrPastGoal, false);
  assert.equal(p.percent, 99.9);
  assert.equal(p.percentText, "99.9%");
});

test("the whole percentage boundary table", () => {
  const cases = [
    [0,          0,      "0%",                   false],
    [1,          0,      "less than 0.1%",       false],
    [24999,      0,      "less than 0.1%",       false],   // $249.99, 0.0999%
    [25000,      0.1,    "0.1%",                 false],   // $250.00, exactly 0.1%
    [12500000,   50,     "50%",                  false],
    [24999999,   99.9,   "99.9%",                false],
    [25000000,   100,    "100%",                 true ],
    [25000001,   100,    "100%",                 true ],
    [37500000,   150,    "150%",                 true ],
    [50000000,   200,    "200%",                 true ],
  ];
  for (const [cents, percent, text, reached] of cases) {
    const p = progress(cents);
    assert.equal(p.percent, percent, `percent for ${cents}`);
    assert.equal(p.percentText, text, `text for ${cents}`);
    assert.equal(p.atOrPastGoal, reached, `atOrPastGoal for ${cents}`);
  }
});

test("flooring below the goal never rounds up across a tenth", () => {
  // 0.1% increments: each value must report the tenth it has actually PASSED.
  for (const [cents, text] of [[25000, "0.1%"], [49999, "0.1%"], [50000, "0.2%"],
                               [24974999, "99.8%"], [24975000, "99.9%"]]) {
    assert.equal(progress(cents).percentText, text, `text for ${cents}`);
  }
});

test("a negative total is described rather than given a percentage", () => {
  const p = progress(-12540);
  assert.equal(p.atOrPastGoal, false);
  assert.equal(p.percentText, "below zero after refunds");
  assert.ok(p.percent < 0, "the numeric percent stays signed for tests");
});

/* ── duplicate JSON keys, compared DECODED ────────────────────────────────── */

test("a repeated key anywhere in the document is detected", () => {
  for (const text of ['{"total_net":"1.00","total_net":"999999.00"}',
                      '{"a":{"b":1,"b":2}}',
                      '{"a":[{"b":1,"b":2}]}',
                      '{"channels":[],"channels":[1]}']) {
    assert.equal(hasDuplicateKeys(text), true, `missed a duplicate in ${text}`);
  }
});

test("escaped spellings of the same key are duplicates", () => {
  // `JSON.parse` resolves "total_net" to `total_net` and then takes last-wins, so a
  // scan that compared RAW spellings would let a second total through unseen.
  for (const text of ['{"total_net":"1.00","total\\u005fnet":"999999.00"}',
                      '{"total\\u005fnet":"999999.00","total_net":"1.00"}',
                      '{"goal":"250000.00","go\\u0061l":"1.00"}',
                      '{"coverage":{"reports":2,"repor\\u0074s":99}}',
                      '{"channels":[{"net":"1.00","n\\u0065t":"999.00"}]}',
                      '{"a":"\\u0062","b":1}'.replace('"a":', '"b":')]) {
    assert.equal(hasDuplicateKeys(text), true, `missed an escaped duplicate in ${text}`);
  }
});

test("the scanner agrees with JSON.parse about what counts as the same key", () => {
  // The strongest form of the check: if the parsed object has fewer keys than the text
  // has key tokens at that level, something collided and must have been caught.
  const text = '{"total_net":"1.00","total\\u005fnet":"2.00"}';
  assert.equal(Object.keys(JSON.parse(text)).length, 1, "the engine collapsed them");
  assert.equal(hasDuplicateKeys(text), true, "the scanner did not");
});

test("distinct keys, sibling objects and braces inside strings are not duplicates", () => {
  for (const text of ['{"a":1,"b":2}',
                      '[{"a":1},{"a":2}]',
                      '{"a":"{\\"a\\": 1}","b":2}',
                      '{"a":"x{y","b":"}z"}',
                      '{"a":"\\u005f","b":"_"}',            // same VALUES, distinct keys
                      '{"basis":"after taxes, fees, refunds","goal":"250000.00"}',
                      JSON.stringify(payload())]) {
    assert.equal(hasDuplicateKeys(text), false, `false positive on ${text.slice(0, 50)}`);
  }
});

test("the shipped public file has no duplicate keys", () => {
  const raw = readFileSync(join(REPO, "docs/data/net-sales.json"), "utf8");
  assert.equal(hasDuplicateKeys(raw), false);
});

/* ── the three display states ─────────────────────────────────────────────── */

test("the shipped default renders as unavailable with the goal still visible", () => {
  const shipped = JSON.parse(readFileSync(join(REPO, "docs/data/net-sales.json"), "utf8"));
  const view = fundingView(shipped, TODAY);
  assert.equal(view.ok, true);
  assert.equal(view.state, "unavailable");
  assert.equal(view.totalCents, null);
  assert.equal(view.totalText, null);
  assert.equal(view.percentText, null);
  assert.equal(view.barPercent, 0);
  assert.equal(view.goalLabel, GOAL_LABEL);
  assert.deepEqual(view.channels.map((c) => c.statusText),
                   [NEUTRAL_CHANNEL, NEUTRAL_CHANNEL]);
  assert.equal(coverageSentence(view), null);
});

test("the absent state never says anything about a shop being closed", () => {
  const words = JSON.stringify(fundingView(absent(), TODAY)).toLowerCase();
  for (const claim of ["not live", "not open", "closed", "nothing sold", "no sales",
                       "no checkout"]) {
    assert.ok(!words.includes(claim), `the absent state asserts "${claim}"`);
  }
});

test("a reported total is shown with both channel figures", () => {
  const view = fundingView(payload(), TODAY);
  assert.equal(view.state, "reported");
  assert.equal(view.totalText, "$1,038.50");
  assert.deepEqual(view.channels.map((c) => c.amountText), ["$566.00", "$472.50"]);
  assert.equal(coverageSentence(view),
               `Reconciled from 2 provider reports, covering ${START} to ${CUTOFF}.`);
  assert.deepEqual(view.channels.map((c) => c.label),
                   [CHANNEL_LABELS.app_store, CHANNEL_LABELS.lemon_squeezy]);
});

test("display names come from the module's constant, never from the payload", () => {
  refuses(payload({
    channels: [
      { id: "app_store", status: "reported", net: "566.00", as_of: CUTOFF,
        label: "jane.doe+orders@example.com" },
      { id: "lemon_squeezy", status: "reported", net: "472.50", as_of: CUTOFF },
    ],
  }), "channel-field", "a label field");
  assert.equal(JSON.stringify(fundingView(payload(), TODAY)).includes("example.com"), false);
});

/* ── THE RULE: invalid never renders as zero ──────────────────────────────── */

test("a zero total without a certifying status is refused rather than shown", () => {
  refuses(payload({ ...both("0.00", "0.00"), status: "reported" }), "total_net");
});

test("a certified zero requires positive report coverage", () => {
  refuses(both("0.00", "0.00", { coverage: { reports: 0, start: null, end: null } }),
          "coverage-reports", "certified zero with no coverage");
  const good = fundingView(both("0.00", "0.00"), TODAY);
  assert.equal(good.state, "zero");
  assert.equal(good.totalText, "$0.00");
  assert.equal(good.percentText, "0%");
});

test("the report count must be able to account for both evidenced channels", () => {
  // Each evidenced channel contributes at least one report under this schema, so one
  // report cannot be the evidence behind two channel figures.
  refuses(payload({ coverage: { reports: 1, start: START, end: CUTOFF } }),
          "coverage-reports", "two channels on one report");
  for (const reports of [2, 3, 12]) {
    const view = fundingView(payload({ coverage: { reports, start: START, end: CUTOFF } }),
                             TODAY);
    assert.equal(view.ok, true, `${reports} reports was refused`);
  }
});

test("every malformed payload yields unavailable, never a zero and never a percent", () => {
  const cases = {
    payload: [null, undefined, 42, "x", []],
    schema: [payload({ schema: "cliphoard.net-sales/1" })],
    currency: [payload({ currency: "GBP" })],
    status: [payload({ status: "projected" }), payload({ status: null })],
    basis: [payload({ basis: 42 }), payload({ basis: "x".repeat(601) })],
    goal: [payload({ goal: "249999.99" }), payload({ goal: "250000.01" }),
           payload({ goal: "500000.00" }), payload({ goal: 250000 }),
           payload({ goal: "250000" }), payload({ goal: "0.00" })],
    total_net: [payload({ total_net: 1038.5 }), payload({ total_net: "1038.5" }),
                payload({ total_net: null }), payload({ total_net: true }),
                payload({ total_net: "2000.00" })],
    as_of: [payload({ as_of: null }), payload({ as_of: "2026-13-01" }),
            payload({ as_of: "2026-02-30" }), payload({ as_of: "2026-10-31" }),
            payload({ as_of: "2026-12-06" })],
    generated: [payload({ generated: null }), payload({ generated: "2026-11-01" }),
                payload({ generated: "2026-12-06" })],
    campaign_start: [payload({ campaign_start: "not-a-date" }),
                     payload({ campaign_start: null })],
    "unknown-field": [payload({ projected_total: "999999.00" })],
    coverage: [payload({ coverage: null }), payload({ coverage: { reports: 2 } }),
               payload({ coverage: { reports: 2, start: START } })],
    "coverage-start": [payload({ coverage: { reports: 2, start: "2026-11-02", end: CUTOFF } })],
    "coverage-end": [payload({ coverage: { reports: 2, start: START, end: "2026-11-29" } })],
  };
  for (const [reason, payloads] of Object.entries(cases)) {
    for (const bad of payloads) {
      refuses(bad, reason, `${reason}: ${String(JSON.stringify(bad)).slice(0, 60)}`);
    }
  }
});

test("an invalid or missing today refuses rather than guessing", () => {
  for (const bad of [undefined, null, "", "not-a-date", "2026-13-01", 20261205]) {
    const view = fundingView(payload(), bad);
    assert.equal(view.ok, false);
    assert.equal(view.reason, "today");
  }
});

/* ── both channels, complete evidence ─────────────────────────────────────── */

test("exactly the two canonical channels are required", () => {
  refuses(payload({ channels: [] }), "channels", "no channels");
  refuses(payload({ channels: [payload().channels[0]] }), "channels", "one channel");
  refuses(payload({ channels: [...payload().channels, payload().channels[0]] }),
          "channels", "three channels");
  refuses(payload({ channels: [payload().channels[0], payload().channels[0]] }),
          "channel-id", "a duplicated channel");
  refuses(payload({
    channels: [{ id: "some_other_store", status: "reported", net: "1.00", as_of: CUTOFF },
               payload().channels[1]],
  }), "channel-id", "an unknown channel");
});

test("a numeric total is refused when either channel has no evidence", () => {
  refuses(payload({
    total_net: "566.00",
    coverage: { reports: 2, start: START, end: CUTOFF },
    channels: [payload().channels[0],
               { id: "lemon_squeezy", status: "no_reports", net: null, as_of: null }],
  }), "incomplete-channel-evidence");
});

test("a channel with no reports cannot carry a figure or a date", () => {
  refuses(absent({
    channels: [{ id: "app_store", status: "no_reports", net: "566.00", as_of: null },
               { id: "lemon_squeezy", status: "no_reports", net: null, as_of: null }],
  }), "channel-net", "no_reports with a net");
  refuses(absent({
    channels: [{ id: "app_store", status: "no_reports", net: null, as_of: CUTOFF },
               { id: "lemon_squeezy", status: "no_reports", net: null, as_of: null }],
  }), "channel-net", "no_reports with a date");
});

test("numeric channels must share the same as_of", () => {
  refuses(payload({
    channels: [payload().channels[0],
               { id: "lemon_squeezy", status: "reported", net: "472.50", as_of: "2026-11-29" }],
  }), "channel-as-of");
});

test("channel figures that do not add up to the total are refused", () => {
  refuses(payload({ total_net: "1038.51" }), "total_net");
});

test("a reported channel may not carry a zero", () => {
  refuses(payload({
    total_net: "566.00",
    channels: [payload().channels[0],
               { id: "lemon_squeezy", status: "reported", net: "0.00", as_of: CUTOFF }],
  }), "channel-net");
});

test("an unavailable payload may not smuggle a figure in beside the nulls", () => {
  for (const over of [{ total_net: "500.00" }, { as_of: CUTOFF },
                      { campaign_start: START },
                      { coverage: { reports: 2, start: START, end: CUTOFF } }]) {
    assert.equal(fundingView(absent(over), TODAY).ok, false,
                 `accepted ${JSON.stringify(over)}`);
  }
});

/* ── the goal boundary ────────────────────────────────────────────────────── */

test("the goal is a constant, not a payload field", () => {
  assert.equal(GOAL_CENTS, 25000000);
  assert.equal(GOAL_LABEL, "US$250,000");
  const view = fundingView(both("249999.99", "0.00"), TODAY);
  assert.equal(view.goalLabel, "US$250,000");
  assert.equal(view.totalText, "$249,999.99");
});

test("a cent below the target reads as below the target", () => {
  const view = fundingView(both("249999.99", "0.00"), TODAY);
  assert.equal(view.atOrPastGoal, false);
  assert.equal(view.percentText, "99.9%");
  assert.equal(view.beyondText, null);
  assert.ok(view.barPercent < 100, `bar was ${view.barPercent}`);
});

test("exactly the target fills the bar and is not past it", () => {
  const view = fundingView(both("125000.00", "125000.00"), TODAY);
  assert.equal(view.totalText, "$250,000.00");
  assert.equal(view.atOrPastGoal, true);
  assert.equal(view.percentText, "100%");
  assert.equal(view.barPercent, 100);
  assert.equal(view.beyondCents, null);
});

test("a cent above the target is past it, by exactly a cent", () => {
  const view = fundingView(both("250000.01", "0.00"), TODAY);
  assert.equal(view.atOrPastGoal, true);
  assert.equal(view.percentText, "100%");
  assert.equal(view.beyondText, "$0.01");
  assert.equal(view.barPercent, 100);
});

test("double the target caps the track at 100% and states the exact excess", () => {
  const view = fundingView(both("250000.00", "250000.00"), TODAY);
  assert.equal(view.totalText, "$500,000.00");
  assert.equal(view.percentText, "200%");
  assert.equal(view.barPercent, 100, "the bar must never overflow its trough");
  assert.equal(view.beyondText, "$250,000.00");
});

test("a negative total is shown honestly with an empty bar", () => {
  const view = fundingView(both("-625.40", "500.00"), TODAY);
  assert.equal(view.state, "reported");
  assert.equal(view.totalText, "-$125.40");
  assert.equal(view.barPercent, 0);
  assert.equal(view.percentText, "below zero after refunds");
  assert.equal(view.beyondCents, null);
});

test("a tiny positive total is distinguishable from zero", () => {
  const tiny = fundingView(both("0.01", "0.00"), TODAY);
  assert.equal(tiny.totalText, "$0.01");
  assert.equal(tiny.percentText, "less than 0.1%");
  const zero = fundingView(both("0.00", "0.00"), TODAY);
  assert.equal(zero.percentText, "0%");
  assert.notEqual(tiny.percentText, zero.percentText);
});

/* ── range ────────────────────────────────────────────────────────────────── */

test("the maximum representable total is accepted", () => {
  const view = fundingView(both("999999999999.99", "0.00"), TODAY);
  assert.equal(view.ok, true);
  assert.equal(view.totalText, "$999,999,999,999.99");
});

test("one cent beyond the grammar is refused", () => {
  refuses(both("999999999999.99", "0.00", { total_net: "1000000000000.00" }), "total_net");
});

test("a total that overflows by addition of two in-range channels is refused", () => {
  refuses(payload({
    total_net: "999999999999.99",
    channels: [
      { id: "app_store", status: "reported", net: "999999999999.99", as_of: CUTOFF },
      { id: "lemon_squeezy", status: "reported", net: "999999999999.99", as_of: CUTOFF },
    ],
  }), "total_net");
});

/* ── staleness ────────────────────────────────────────────────────────────── */

test("a recent figure is not marked stale", () => {
  const view = fundingView(payload(), "2026-12-05");
  assert.equal(view.stale, false);
  assert.equal(view.asOf, CUTOFF);
});

test("a figure older than the window is marked, with its own date, and still shown", () => {
  const view = fundingView(payload(), "2027-03-01");
  assert.equal(view.stale, true);
  assert.equal(view.asOf, CUTOFF);
  assert.equal(view.totalText, "$1,038.50", "a stale figure is labelled, not hidden");
});

test("the staleness boundary is exactly the documented window", () => {
  const day = (n) => new Date(Date.parse(CUTOFF + "T00:00:00Z") + n * 86400000)
    .toISOString().slice(0, 10);
  assert.equal(fundingView(payload(), day(STALE_AFTER_DAYS)).stale, false);
  assert.equal(fundingView(payload(), day(STALE_AFTER_DAYS + 1)).stale, true);
});

/* ══ THE RESET, at the DOM level ═══════════════════════════════════════════
 *
 * A minimal DOM stub, built from the REAL slots and the REAL static text in
 * docs/index.html, so what is asserted is "the page went back to exactly what ships"
 * rather than "the page went back to what this test happens to expect".
 * This is a stub, not a browser. Root owns the live Chrome pass.
 */

/** Every slot the renderer writes into, with its shipped static text and hidden state. */
function shippedSlots() {
  const section = /<section id="funding"[\s\S]*?<\/section>/.exec(INDEX)[0];
  const slots = new Map();
  const pattern = /<(\w+)([^>]*\bdata-(?:funding-[a-z]+|channel="[a-z_]+")[^>]*)>([\s\S]*?)<\/\1>/g;
  for (const [, , attrs, inner] of section.matchAll(pattern)) {
    const name = /\bdata-(funding-[a-z]+)\b/.exec(attrs);
    const channel = /\bdata-channel="([a-z_]+)"/.exec(attrs);
    const selector = name ? `[data-${name[1]}]` : `[data-channel="${channel[1]}"]`;
    slots.set(selector, {
      text: inner.replace(/<[^>]+>/g, "").replace(/\s+/g, " ").trim(),
      hidden: /\bhidden\b/.test(attrs),
      classes: (/\bclass="([^"]*)"/.exec(attrs)?.[1] ?? "").split(/\s+/).filter(Boolean),
    });
  }
  return slots;
}

function makeDocument() {
  const doc = {
    createTextNode: (text) => ({ textContent: String(text) }),
    createElement: () => makeNode(doc, { text: "", hidden: false, classes: [] }),
  };
  return doc;
}

function makeNode(doc, shipped) {
  const classes = new Set(shipped.classes);
  const node = {
    _children: shipped.text ? [{ textContent: shipped.text }] : [],
    hidden: shipped.hidden,
    style: { width: "" },
    classList: {
      add: (c) => classes.add(c),
      remove: (c) => classes.delete(c),
      contains: (c) => classes.has(c),
      toggle: (c, on) => (on ? classes.add(c) : classes.delete(c)),
    },
    get classes() { return [...classes].sort(); },
    get ownerDocument() { return doc; },
    get textContent() { return node._children.map((c) => c.textContent).join(""); },
    set textContent(value) {
      node._children = String(value) === "" ? [] : [{ textContent: String(value) }];
    },
    appendChild(child) { node._children.push(child); return child; },
  };
  return node;
}

function makeRoot() {
  const doc = makeDocument();
  const shipped = shippedSlots();
  const nodes = new Map();
  for (const [selector, spec] of shipped) nodes.set(selector, makeNode(doc, spec));
  return {
    shipped,
    nodes,
    root: {
      ownerDocument: doc,
      querySelector: (selector) => nodes.get(selector) ?? null,
    },
    /** Normalised text of every slot, the way a reader would see it. */
    snapshot() {
      const out = {};
      for (const [selector, node] of nodes) {
        out[selector] = { text: node.textContent.replace(/\s+/g, " ").trim(),
                          hidden: node.hidden };
      }
      return out;
    },
  };
}

function neutralSnapshot(harness) {
  const out = {};
  for (const [selector, spec] of harness.shipped) {
    out[selector] = { text: spec.text, hidden: spec.hidden };
  }
  return out;
}

test("the harness finds every slot the renderer writes into", () => {
  const harness = makeRoot();
  const expected = new Set([...readFileSync(join(REPO, "docs/assets/funding.js"), "utf8")
    .matchAll(/\[data-(funding-[a-z]+)\]/g)].map((m) => `[data-${m[1]}]`));
  for (const selector of expected) {
    assert.ok(harness.nodes.has(selector), `docs/index.html has no ${selector}`);
  }
  for (const id of CHANNEL_IDS) {
    assert.ok(harness.nodes.has(`[data-channel="${id}"]`), `no row for ${id}`);
  }
});

test("the shipped static markup uses the module's own neutral strings", () => {
  // If these drift, a reset would restore text the page never actually ships.
  const harness = makeRoot();
  assert.equal(harness.shipped.get("[data-funding-figure]").text, NEUTRAL_FIGURE);
  assert.equal(harness.shipped.get("[data-funding-status]").text, NEUTRAL_STATUS);
  assert.equal(harness.shipped.get("[data-funding-asof]").text, NEUTRAL_ASOF);
  for (const id of CHANNEL_IDS) {
    assert.equal(harness.shipped.get(`[data-channel="${id}"]`).text, NEUTRAL_CHANNEL);
  }
  assert.equal(harness.shipped.get("[data-funding-percent]").text,
               `The goal is ${GOAL_LABEL}.`);
});

test("rendering a figure writes it, and the DOM then shows it", () => {
  const harness = makeRoot();
  const result = applyFundingView(fundingView(both("250000.00", "250000.00"), TODAY),
                                  harness.root);
  assert.deepEqual(result, { rendered: true, reset: false });
  const after = harness.snapshot();
  assert.equal(after["[data-funding-figure]"].text, "$500,000.00");
  assert.match(after["[data-funding-percent]"].text, /^200% of the US\$250,000 goal$/);
  assert.equal(after["[data-funding-beyond]"].hidden, false);
  assert.match(after["[data-funding-beyond]"].text, /Past the goal by \$250,000\.00/);
  assert.equal(after['[data-channel="app_store"]'].text, "$250,000.00");
  assert.equal(harness.nodes.get("[data-funding-fill]").style.width, "100%");
  assert.ok(!harness.nodes.get("[data-funding-figure]").classes.includes("absent"));
});

/** The observed bug: $500,000.00 / 200% stayed on screen after an unavailable payload. */
for (const [label, build] of [
  ["a valid unavailable payload", () => fundingView(absent(), TODAY)],
  ["an invalid payload (float money)", () => fundingView(payload({ total_net: 1038.5 }), TODAY)],
  ["a payload of the wrong schema", () => fundingView(payload({ schema: "x" }), TODAY)],
  ["a payload with one channel missing", () => fundingView(payload({ channels: [] }), TODAY)],
  ["a null payload", () => fundingView(null, TODAY)],
  ["an undefined view", () => undefined],
]) {
  test(`success then ${label} resets the DOM to the shipped neutral state`, () => {
    const harness = makeRoot();
    applyFundingView(fundingView(both("250000.00", "250000.00"), TODAY), harness.root);
    assert.equal(harness.snapshot()["[data-funding-figure]"].text, "$500,000.00");

    const result = applyFundingView(build(), harness.root);
    assert.deepEqual(result, { rendered: false, reset: true },
                     "the renderer declined to write instead of resetting");

    assert.deepEqual(harness.snapshot(), neutralSnapshot(harness),
                     "the DOM did not return to the shipped neutral state");
    assert.equal(harness.nodes.get("[data-funding-fill]").style.width, "0%");
    assert.ok(harness.nodes.get("[data-funding-figure]").classes.includes("absent"));
    for (const id of CHANNEL_IDS) {
      assert.ok(!harness.nodes.get(`[data-channel="${id}"]`).classes.includes("amount"));
    }
    // And nothing from the previous figure is anywhere in the DOM at all.
    const everything = JSON.stringify(harness.snapshot());
    for (const stale of ["500,000", "250,000.00", "200%", "Past the goal"]) {
      assert.ok(!everything.includes(stale), `"${stale}" survived the reset`);
    }
  });
}

test("the reset is idempotent and safe on an untouched page", () => {
  const harness = makeRoot();
  assert.equal(resetFundingView(harness.root), true);
  assert.equal(resetFundingView(harness.root), true);
  assert.deepEqual(harness.snapshot(), neutralSnapshot(harness));
});

test("a stale figure's label is cleared by the reset, not just hidden", () => {
  const harness = makeRoot();
  applyFundingView(fundingView(payload(), "2027-06-01"), harness.root);
  assert.equal(harness.snapshot()["[data-funding-stale]"].hidden, false);
  applyFundingView(fundingView(absent(), TODAY), harness.root);
  assert.equal(harness.nodes.get("[data-funding-stale]").textContent, "");
  assert.equal(harness.nodes.get("[data-funding-stale]").hidden, true);
});

test("every boot failure path resets rather than leaving a figure", async () => {
  // fetch rejection, non-OK status, unreadable body, duplicate keys, unparseable JSON,
  // and a payload that fails validation. Each must end at the neutral state.
  const good = JSON.stringify(absent());
  const paths = {
    "fetch rejects": () => Promise.reject(new Error("offline")),
    "non-OK status": async () => ({ ok: false, text: async () => good }),
    "body throws": async () => ({ ok: true, text: async () => { throw new Error("x"); } }),
    "duplicate keys": async () => ({ ok: true,
      text: async () => '{"total_net":"1.00","total\\u005fnet":"2.00"}' }),
    "unparseable JSON": async () => ({ ok: true, text: async () => "{not json" }),
    "invalid schema": async () => ({ ok: true,
      text: async () => JSON.stringify(payload({ schema: "nope" })) }),
    "valid unavailable": async () => ({ ok: true, text: async () => good }),
  };
  const original = globalThis.fetch;
  try {
    for (const [label, impl] of Object.entries(paths)) {
      const harness = makeRoot();
      applyFundingView(fundingView(both("250000.00", "250000.00"), TODAY), harness.root);
      globalThis.fetch = impl;
      const result = await mod.bootFunding(harness.root, "data/net-sales.json", TODAY);
      assert.deepEqual(result, { rendered: false, reset: true }, label);
      assert.deepEqual(harness.snapshot(), neutralSnapshot(harness),
                       `${label} left the DOM dirty`);
    }
  } finally {
    if (original === undefined) delete globalThis.fetch;
    else globalThis.fetch = original;
  }
});

test("the DOM half stays out of the way without a root", async () => {
  assert.deepEqual(applyFundingView(fundingView(payload(), TODAY), null),
                   { rendered: false, reset: false });
  assert.deepEqual(applyFundingView(fundingView(payload(), TODAY), {}),
                   { rendered: false, reset: false });
  assert.equal(resetFundingView(null), false);
  assert.deepEqual(await mod.bootFunding(null), { rendered: false, reset: false });
});

test("the renderer creates nodes from the root's own document", () => {
  // This is what lets Tests/site/preview.html drive the real funding section inside an
  // iframe with the real code.
  const source = readFileSync(join(REPO, "docs/assets/funding.js"), "utf8");
  const body = source.slice(source.indexOf("export function resetFundingView"));
  assert.ok(body.includes("root.ownerDocument"), "the DOM half ignores ownerDocument");
  assert.ok(!/[^.\w]document\.create/.test(body),
            "the DOM half still reaches for an ambient document");
});
