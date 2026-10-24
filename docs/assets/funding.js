/* Cliphoard — the net sales proceeds figure.
 *
 * WHY THIS FILE IS SPLIT THE WAY IT IS
 *
 * `fundingView(payload, today)` is PURE: data in, a view model out, no DOM, no fetch,
 * no clock. `applyFundingView` and `resetFundingView` are the only parts that touch a
 * page. That split is what lets the browser, the Node tests and the local QA harness all
 * import this exact file — no build step, no test double, no second implementation of
 * the money rules that could drift away from the shipped one.
 *
 * MONEY IS CARRIED AS DECIMAL STRINGS AND PARSED TO INTEGER CENTS. JSON numbers are
 * IEEE-754 doubles, and 0.1 + 0.2 is not 0.3 in one. A number where a money string is
 * expected is a VALIDATION FAILURE, not something to coerce.
 *
 * THESE RULES ARE THE SAME ONES `tools/funding/publish_net_sales.py` ENFORCES. They are
 * restated here rather than trusted, because the publisher's guarantees end at the file
 * and the file is the thing the browser actually receives.
 *
 * TWO RULES THAT MATTER MORE THAN THE REST:
 *
 *   1. A PAYLOAD THAT DOES NOT VALIDATE NEVER RENDERS AS ZERO, AND NEVER AS 0%.
 *   2. IT ALSO NEVER LEAVES A PREVIOUS FIGURE ON SCREEN. Anything other than a valid
 *      numeric view RESETS the page to the neutral state — an earlier amount still
 *      sitting there is read as current, which is the worst failure this page has.
 */

export const SCHEMA = "cliphoard.net-sales/3";

/** The two channels this campaign has. BOTH are required, exactly once each. */
export const CHANNEL_IDS = ["app_store", "stripe_managed_payments"];

/** Display names come from here and ONLY from here.
 *
 *  The payload deliberately carries no `label` field. A name copied out of a private
 *  operator file is a string this page would render without ever having seen it. */
export const CHANNEL_LABELS = {
  app_store: "Apple App Store",
  stripe_managed_payments: "Stripe Managed Payments",
};

/** THE GOAL IS A CONSTANT, here and in the publisher. `index.html` hard-codes the
 *  ruler's tick labels, so a payload with a different goal would be drawn against an
 *  axis that does not describe it. */
export const GOAL_CENTS = 25000000;

/** Written with the country, not a bare dollar sign: the business is UK-registered and
 *  "$" alone does not say which dollar. */
export const GOAL_LABEL = "US$250,000";

/** The widest value the money grammar admits, in minor units. Well inside
 *  `Number.MAX_SAFE_INTEGER`, so every total, sum and comparison below is exact. */
export const MAX_CENTS = 99999999999999;

/** The neutral copy, exported so `index.html` and `resetFundingView` cannot drift. A
 *  test asserts the shipped markup contains each of these strings. */
export const NEUTRAL_FIGURE = "No reconciled reports available.";
export const NEUTRAL_CHANNEL = "Awaiting reconciled reports";
export const NEUTRAL_STATUS = "A combined total appears here once reconciled reports "
  + "covering the same period exist for both channels.";
export const NEUTRAL_ASOF = "Published from reconciled provider reports. "
  + "All figures in US dollars.";

const TOP_KEYS = ["schema", "status", "currency", "goal", "total_net", "campaign_start",
                  "as_of", "generated", "coverage", "channels", "basis"];
const CHANNEL_KEYS = ["id", "status", "net", "as_of"];
const COVERAGE_KEYS = ["reports", "start", "end"];

const TOTAL_STATUS = ["unavailable", "reported", "certified_zero"];
/** `no_reports` means this page has no reconciled report for the channel. It is NOT a
 *  claim that the channel is shut, that no checkout exists, or that nothing was sold. */
const CHANNEL_STATUS = ["no_reports", "reported", "certified_zero"];

/** Provider reconciliation is monthly, so a figure older than this is behind the
 *  business rather than merely recent. Past it the figure is still shown — hiding it
 *  would be its own dishonesty — but it is labelled with its own date. */
export const STALE_AFTER_DAYS = 45;

/* ── money ───────────────────────────────────────────────────────────────── */

/** Exactly two decimal places, no exponent, no leading zeros, optional minus. */
const MONEY = /^-?(0|[1-9][0-9]{0,11})\.[0-9]{2}$/;

/** A money string to integer cents, or null if it is not one or is out of range.
 *
 *  `-0.00` canonicalizes to `0`: it satisfies the grammar and compares equal to zero,
 *  but a sign on zero carries no information about money. */
export function toCents(value) {
  if (typeof value !== "string" || !MONEY.test(value)) return null;
  const negative = value.startsWith("-");
  const [whole, frac] = (negative ? value.slice(1) : value).split(".");
  const magnitude = Number(whole) * 100 + Number(frac);
  if (!Number.isSafeInteger(magnitude) || magnitude > MAX_CENTS) return null;
  return negative && magnitude !== 0 ? -magnitude : magnitude;
}

/** Integer cents to `$1,234.56`. Cents are never dropped and never rounded away. */
export function formatUSD(cents) {
  const negative = cents < 0;
  const abs = Math.abs(cents);
  const whole = String(Math.trunc(abs / 100));
  const frac = String(abs % 100).padStart(2, "0");
  let grouped = "";
  for (let i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 === 0) grouped += ",";
    grouped += whole[i];
  }
  return (negative ? "-$" : "$") + grouped + "." + frac;
}

/** How far along, as a number and as the string the page shows.
 *
 *  THE CENTS DECIDE WHETHER THE GOAL IS REACHED — never the rounded display. Below the
 *  goal the percentage is FLOORED, so $249,999.99 reads 99.9% and cannot be promoted to
 *  a 100% that would say the goal was met when it was one cent short. At or past the
 *  goal it rounds normally, so $250,000.00 is 100% and $500,000.00 is 200%.
 *
 *  The three edges that need their own wording rather than a number:
 *    - a positive total too small to reach 0.1% would floor to "0%", which is
 *      indistinguishable from having sold nothing;
 *    - a certified zero really is 0%;
 *    - a negative total after refunds has no sensible reading as a percentage of a
 *      goal, so it is described instead.
 */
export function progress(totalCents, goalCents = GOAL_CENTS) {
  const atOrPastGoal = totalCents >= goalCents;
  const exact = (totalCents / goalCents) * 100;

  if (totalCents < 0) {
    return { atOrPastGoal: false, percent: exact,
             percentText: "below zero after refunds" };
  }
  if (totalCents === 0) {
    return { atOrPastGoal: false, percent: 0, percentText: "0%" };
  }
  if (atOrPastGoal) {
    const percent = Math.round((totalCents * 1000) / goalCents) / 10;
    return { atOrPastGoal: true, percent, percentText: `${trimPercent(percent)}%` };
  }
  const percent = Math.min(Math.floor(exact * 10) / 10, 99.9);
  return {
    atOrPastGoal: false,
    percent,
    percentText: percent === 0 ? "less than 0.1%" : `${trimPercent(percent)}%`,
  };
}

function trimPercent(percent) {
  return Number.isInteger(percent) ? String(percent) : percent.toFixed(1);
}

/* ── small validators ────────────────────────────────────────────────────── */

const DATE = /^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$/;

function isDate(value) {
  if (typeof value !== "string" || !DATE.test(value)) return false;
  const d = new Date(value + "T00:00:00Z");
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === value;
}

function dayNumber(iso) { return Math.floor(Date.parse(iso + "T00:00:00Z") / 86400000); }

/** The key set must match EXACTLY — no extras, and none missing. */
function sameKeys(object, allowed) {
  const keys = Object.keys(object);
  return keys.length === allowed.length && allowed.every((k) => keys.includes(k));
}

function isPlainObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/* ── duplicate JSON keys ─────────────────────────────────────────────────── */

const ESCAPES = { '"': '"', "\\": "\\", "/": "/", b: "\b", f: "\f", n: "\n", r: "\r", t: "\t" };

/** Read one JSON string starting at its opening quote, DECODED.
 *
 *  Decoding is the point. `"total_net"` and `"total_net"` are different spellings
 *  of the same key, and `JSON.parse` resolves both to `total_net` and then takes
 *  last-wins. Comparing raw spellings would miss that entirely, which is how a second
 *  `total_net` hides in plain sight. A `\uXXXX` pair that forms a surrogate pair
 *  reassembles correctly, because appending both halves to a JS string is exactly how
 *  UTF-16 represents the astral character.
 */
function readJSONString(text, start) {
  let value = "";
  let i = start + 1;
  while (i < text.length) {
    const ch = text[i];
    if (ch === "\\") {
      const code = text[i + 1];
      i += 2;
      if (code === "u") {
        value += String.fromCharCode(parseInt(text.slice(i, i + 4), 16) || 0);
        i += 4;
      } else {
        value += ESCAPES[code] !== undefined ? ESCAPES[code] : (code ?? "");
      }
      continue;
    }
    if (ch === '"') return { value, end: i + 1 };
    value += ch;
    i += 1;
  }
  return { value, end: text.length };
}

/** True if any object in this JSON text repeats a key, comparing DECODED key names.
 *
 *  There is no parser option for this, so the raw text is scanned before parsing.
 *  Strings are read properly rather than skipped over, because a `{` inside a string
 *  value is not a nesting level and a naive scan would lose track of depth. */
export function hasDuplicateKeys(text) {
  if (typeof text !== "string") return false;
  const stack = [];
  let i = 0;
  let expectKey = false;
  while (i < text.length) {
    const ch = text[i];
    if (ch === '"') {
      const { value, end } = readJSONString(text, i);
      if (expectKey && stack.length > 0) {
        const seen = stack[stack.length - 1];
        if (seen !== null) {
          if (seen.has(value)) return true;
          seen.add(value);
        }
        expectKey = false;
      }
      i = end;
      continue;
    }
    if (ch === "{") { stack.push(new Set()); expectKey = true; }
    else if (ch === "[") { stack.push(null); expectKey = false; }
    else if (ch === "}" || ch === "]") { stack.pop(); expectKey = false; }
    else if (ch === ",") { expectKey = stack.length > 0 && stack[stack.length - 1] !== null; }
    i += 1;
  }
  return false;
}

/* ── the view model ──────────────────────────────────────────────────────── */

function unavailable(reason) {
  return { ok: false, state: "unavailable", reason, channels: [] };
}

/**
 * @param payload parsed JSON, of unknown shape
 * @param today   `YYYY-MM-DD`, injected rather than read from the clock so that
 *                staleness and future-date refusals are testable and this stays pure
 * @returns a view model. `ok:false` means nothing numeric may be displayed, and the page
 *          must be reset to its neutral state rather than left as it was.
 */
export function fundingView(payload, today) {
  if (!isDate(today)) return unavailable("today");
  if (!isPlainObject(payload)) return unavailable("payload");
  if (!sameKeys(payload, TOP_KEYS)) return unavailable("unknown-field");
  if (payload.schema !== SCHEMA) return unavailable("schema");
  if (payload.currency !== "USD") return unavailable("currency");
  if (!TOTAL_STATUS.includes(payload.status)) return unavailable("status");
  if (typeof payload.basis !== "string" || payload.basis.length > 600) {
    return unavailable("basis");
  }

  if (toCents(payload.goal) !== GOAL_CENTS) return unavailable("goal");
  const goal = {
    goalCents: GOAL_CENTS,
    goalText: formatUSD(GOAL_CENTS),
    goalLabel: GOAL_LABEL,
    campaignStart: payload.campaign_start,
  };

  if (payload.campaign_start !== null && !isDate(payload.campaign_start)) {
    return unavailable("campaign_start");
  }

  // BOTH canonical channels, exactly once each. A missing channel is missing evidence,
  // and missing evidence must never be rendered as a figure of zero.
  if (!Array.isArray(payload.channels)
      || payload.channels.length !== CHANNEL_IDS.length) return unavailable("channels");

  const seen = new Set();
  const channels = [];
  for (const raw of payload.channels) {
    if (!isPlainObject(raw) || !sameKeys(raw, CHANNEL_KEYS)) return unavailable("channel-field");
    if (!CHANNEL_IDS.includes(raw.id) || seen.has(raw.id)) return unavailable("channel-id");
    seen.add(raw.id);
    if (!CHANNEL_STATUS.includes(raw.status)) return unavailable("channel-status");
    if (raw.as_of !== null && !isDate(raw.as_of)) return unavailable("channel-as-of");

    let cents = null;
    if (raw.status === "reported") {
      cents = toCents(raw.net);
      if (cents === null || cents === 0) return unavailable("channel-net");
    } else if (raw.status === "certified_zero") {
      if (raw.net !== "0.00") return unavailable("channel-net");
      cents = 0;
    } else if (raw.net !== null || raw.as_of !== null) {
      return unavailable("channel-net");
    }
    channels.push({ id: raw.id, label: CHANNEL_LABELS[raw.id], status: raw.status,
                    cents, asOf: raw.as_of });
  }
  if (seen.size !== CHANNEL_IDS.length) return unavailable("channels");

  const cov = payload.coverage;
  if (!isPlainObject(cov) || !sameKeys(cov, COVERAGE_KEYS)) return unavailable("coverage");
  if (!Number.isSafeInteger(cov.reports) || cov.reports < 0) return unavailable("coverage-reports");
  if (cov.start !== null && !isDate(cov.start)) return unavailable("coverage-start");
  if (cov.end !== null && !isDate(cov.end)) return unavailable("coverage-end");
  if ((cov.reports === 0) !== (cov.start === null)) return unavailable("coverage-reports");
  if ((cov.start === null) !== (cov.end === null)) return unavailable("coverage-end");
  if (cov.start !== null && dayNumber(cov.end) < dayNumber(cov.start)) return unavailable("coverage-end");

  if (!isDate(payload.generated)) return unavailable("generated");
  if (dayNumber(payload.generated) > dayNumber(today)) return unavailable("generated");

  if (payload.status === "unavailable") {
    if (payload.total_net !== null) return unavailable("total_net");
    if (payload.as_of !== null) return unavailable("as_of");
    if (payload.campaign_start !== null) return unavailable("campaign_start");
    if (cov.reports !== 0) return unavailable("coverage-reports");
    if (channels.some((c) => c.status !== "no_reports")) return unavailable("channel-status");
    return {
      ok: true, state: "unavailable", reason: null, ...goal,
      totalCents: null, totalText: null, percent: null, percentText: null,
      atOrPastGoal: false, barPercent: 0,
      beyondCents: null, beyondText: null,
      stale: false, asOf: null, generated: payload.generated,
      basis: payload.basis,
      coverage: { reports: 0, start: null, end: null },
      channels: channels.map(describeChannel),
    };
  }

  /* From here a figure IS being claimed, so every date behind it must exist, must not be
     in the future, and the evidence must be complete for BOTH channels. */
  if (!isDate(payload.campaign_start)) return unavailable("campaign_start");
  if (!isDate(payload.as_of)) return unavailable("as_of");
  if (dayNumber(payload.campaign_start) > dayNumber(today)) return unavailable("campaign_start");
  if (dayNumber(payload.as_of) > dayNumber(today)) return unavailable("as_of");
  if (dayNumber(payload.as_of) < dayNumber(payload.campaign_start)) return unavailable("as_of");
  if (dayNumber(payload.generated) < dayNumber(payload.as_of)) return unavailable("generated");

  // A numeric total needs complete, same-period evidence from every channel, and a
  // report count that can actually account for them: under this schema each evidenced
  // channel contributes at least one report, so fewer reports than channels means the
  // coverage figure and the channel figures describe different things.
  if (cov.reports < CHANNEL_IDS.length) return unavailable("coverage-reports");
  if (dayNumber(cov.start) !== dayNumber(payload.campaign_start)) return unavailable("coverage-start");
  if (dayNumber(cov.end) !== dayNumber(payload.as_of)) return unavailable("coverage-end");
  if (channels.some((c) => c.cents === null)) return unavailable("incomplete-channel-evidence");
  if (channels.some((c) => c.asOf !== payload.as_of)) return unavailable("channel-as-of");

  const totalCents = toCents(payload.total_net);
  if (totalCents === null) return unavailable("total_net");

  // ZERO IS A CLAIM, NOT A DEFAULT. A certified zero says the reports total zero; it
  // does not say nothing was sold.
  if (payload.status === "certified_zero" && totalCents !== 0) return unavailable("total_net");
  if (payload.status === "reported" && totalCents === 0) return unavailable("total_net");

  let summed = 0;
  for (const c of channels) {
    summed += c.cents;
    if (!Number.isSafeInteger(summed) || Math.abs(summed) > MAX_CENTS) {
      return unavailable("total_net");
    }
  }
  if (summed !== totalCents) return unavailable("total_net");

  // Monotonicity is never assumed: refunds, chargebacks and negative corrections
  // legitimately reduce this, so a negative total is a real state shown as one.
  const { atOrPastGoal, percent, percentText } = progress(totalCents);
  const beyondCents = totalCents > GOAL_CENTS ? totalCents - GOAL_CENTS : null;
  const barPercent = totalCents <= 0 ? 0 : Math.min(100, (totalCents / GOAL_CENTS) * 100);
  const stale = dayNumber(today) - dayNumber(payload.as_of) > STALE_AFTER_DAYS;

  return {
    ok: true,
    state: payload.status === "certified_zero" ? "zero" : "reported",
    reason: null, ...goal,
    totalCents, totalText: formatUSD(totalCents),
    percent, percentText, atOrPastGoal, barPercent,
    beyondCents, beyondText: beyondCents === null ? null : formatUSD(beyondCents),
    stale, asOf: payload.as_of, generated: payload.generated,
    basis: payload.basis,
    coverage: { reports: cov.reports, start: cov.start, end: cov.end },
    channels: channels.map(describeChannel),
  };
}

const CHANNEL_WORDS = {
  no_reports: NEUTRAL_CHANNEL,
  reported: "Reconciled",
  certified_zero: "Reconciled",
};

function describeChannel(c) {
  return {
    id: c.id,
    label: c.label,
    statusText: CHANNEL_WORDS[c.status],
    amountText: c.cents === null ? null : formatUSD(c.cents),
    asOf: c.asOf,
  };
}

export function coverageSentence(view) {
  if (!view.ok || view.coverage.reports === 0) return null;
  const n = view.coverage.reports;
  return `Reconciled from ${n} provider ${n === 1 ? "report" : "reports"}, `
       + `covering ${view.coverage.start} to ${view.coverage.end}.`;
}

/* ── the DOM half ────────────────────────────────────────────────────────── */

function slot(root, name) { return root.querySelector(`[data-funding-${name}]`); }

/** Put the page back to its neutral, shipped state.
 *
 *  THIS IS THE FUNCTION THAT STOPS A STALE FIGURE BEING READ AS CURRENT. Observed in QA:
 *  render $500,000.00 / 200%, then feed an unavailable payload, and a renderer that
 *  merely declines to write leaves the $500,000.00 sitting there looking live. Declining
 *  to write is not neutral — the previous write is still the page.
 *
 *  Every slot the success path touches is restored here, from the exported NEUTRAL_*
 *  constants that `index.html` also uses, so the two cannot drift.
 */
export function resetFundingView(root) {
  if (!root || !root.ownerDocument) return false;
  const doc = root.ownerDocument;

  const figure = slot(root, "figure");
  if (figure) {
    figure.textContent = NEUTRAL_FIGURE;
    if (figure.classList) figure.classList.add("absent");
  }

  // Rebuilt rather than flattened, so the bold on the amount comes back too and the
  // reset state is visually identical to the shipped markup, not merely textually.
  const percent = slot(root, "percent");
  if (percent) {
    percent.textContent = "";
    percent.appendChild(doc.createTextNode("The goal is "));
    const strong = doc.createElement("b");
    strong.textContent = GOAL_LABEL;
    percent.appendChild(strong);
    percent.appendChild(doc.createTextNode("."));
  }

  const fill = slot(root, "fill");
  if (fill && fill.style) fill.style.width = "0%";

  const status = slot(root, "status");
  if (status) status.textContent = NEUTRAL_STATUS;

  const asOf = slot(root, "asof");
  if (asOf) asOf.textContent = NEUTRAL_ASOF;

  // Cleared AND hidden. Hiding alone would leave the old excess in the DOM, where a
  // stylesheet change or a screen reader could still surface it.
  for (const name of ["beyond", "stale", "coverage"]) {
    const el = slot(root, name);
    if (!el) continue;
    el.textContent = "";
    el.hidden = true;
  }

  for (const id of CHANNEL_IDS) {
    const dd = root.querySelector(`[data-channel="${id}"]`);
    if (!dd) continue;
    dd.textContent = NEUTRAL_CHANNEL;
    if (dd.classList) dd.classList.remove("amount");
  }
  return true;
}

/**
 * Writes a validated numeric view into a page, or resets the page if there is not one.
 *
 * Nodes are created from `root.ownerDocument` rather than an ambient `document`, so this
 * works against a document other than the caller's — which is what lets
 * `Tests/site/preview.html` drive the REAL funding section inside an iframe with the REAL
 * code instead of reimplementing the rendering it is meant to check.
 *
 * @returns `{rendered, reset}` rather than a bare boolean, so a caller can report which
 *          of the two actually happened. A no-op is no longer one of the outcomes.
 */
export function applyFundingView(view, root) {
  if (!root || !root.ownerDocument) return { rendered: false, reset: false };
  if (!view || !view.ok || view.state === "unavailable") {
    resetFundingView(root);
    return { rendered: false, reset: true };
  }
  const doc = root.ownerDocument;

  const figure = slot(root, "figure");
  if (figure) {
    figure.textContent = view.totalText;
    if (figure.classList) figure.classList.remove("absent");
  }

  const percent = slot(root, "percent");
  if (percent) {
    percent.textContent = `${view.percentText} of the ${view.goalLabel} goal`;
  }

  const fill = slot(root, "fill");
  if (fill && fill.style) fill.style.width = `${view.barPercent}%`;

  const beyond = slot(root, "beyond");
  if (beyond) {
    if (view.beyondText) {
      beyond.textContent = "";
      beyond.appendChild(doc.createTextNode("Past the goal by "));
      const strong = doc.createElement("b");
      strong.textContent = view.beyondText;
      beyond.appendChild(strong);
      beyond.appendChild(doc.createTextNode(". The goal is a milestone, not a cap; "
        + "anything beyond it supports further research."));
      beyond.hidden = false;
    } else {
      beyond.textContent = "";
      beyond.hidden = true;
    }
  }

  const status = slot(root, "status");
  if (status) {
    status.textContent = view.state === "zero"
      ? "The reconciled reports for this period total zero net sales proceeds."
      : "Cumulative net sales proceeds, reconciled from provider reports for both "
        + "channels. All figures in US dollars.";
  }

  const staleEl = slot(root, "stale");
  if (staleEl) {
    if (view.stale) {
      staleEl.textContent = "Not current. This figure was last verified against provider "
        + `reports for the period ending ${view.asOf}; anything after that date is not `
        + "in it yet.";
      staleEl.hidden = false;
    } else {
      staleEl.textContent = "";
      staleEl.hidden = true;
    }
  }

  const asOf = slot(root, "asof");
  if (asOf) {
    asOf.textContent = `Figures to ${view.asOf}. Published ${view.generated}. `
      + `Counted from ${view.campaignStart}. All figures in US dollars.`;
  }

  const coverage = slot(root, "coverage");
  if (coverage) {
    const sentence = coverageSentence(view);
    coverage.textContent = sentence || "";
    coverage.hidden = !sentence;
  }

  for (const channel of view.channels) {
    const dd = root.querySelector(`[data-channel="${channel.id}"]`);
    if (!dd) continue;
    dd.textContent = channel.amountText || channel.statusText;
    if (dd.classList) dd.classList.toggle("amount", Boolean(channel.amountText));
  }
  return { rendered: true, reset: false };
}

/** Fetch, validate, render — and reset on EVERY failure.
 *
 *  Each of these paths used to be a silent no-op on the grounds that the markup already
 *  in the page was the right answer. That holds on first load and fails on any reload or
 *  refetch, where the page may already be showing a figure. So every one of them resets:
 *  no fetch at all, a rejected request, a non-OK status, unreadable text, a duplicate
 *  key, unparseable JSON, and a payload that fails validation.
 */
export async function bootFunding(root, url = "data/net-sales.json", today = undefined) {
  if (!root || !root.ownerDocument) return { rendered: false, reset: false };
  if (typeof fetch !== "function") {
    resetFundingView(root);
    return { rendered: false, reset: true };
  }
  let payload;
  try {
    const response = await fetch(url, { cache: "no-cache" });
    if (!response.ok) throw new Error("not ok");
    const text = await response.text();
    if (hasDuplicateKeys(text)) throw new Error("duplicate key");
    payload = JSON.parse(text);
  } catch {
    resetFundingView(root);
    return { rendered: false, reset: true };
  }
  const day = today || new Date().toISOString().slice(0, 10);
  return applyFundingView(fundingView(payload, day), root);
}
