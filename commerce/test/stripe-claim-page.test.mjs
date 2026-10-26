import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { runInNewContext } from "node:vm";
import { claimPage } from "../src/stripe-claim-page.mjs";
import { claimPageClient } from "../src/stripe-claim-client.mjs";

const syntheticKey = "CLIP1-synthetic_fixture.not_a_real_signature";
for (const [result, expected] of [["ready", 200], ["payment_pending", 202], ["payment_blocked", 410]]) {
  test(`claim ${result}: preserves status, privacy headers and exact inline CSP hashes`, async () => {
    const response = await claimPage({ result, licence: syntheticKey, download: "https://cliphoard.dev/#download" });
    const html = await response.text(), csp = response.headers.get("Content-Security-Policy");
    assert.equal(response.status, expected);
    assert.equal(response.headers.get("Retry-After"), expected === 202 ? "60" : null);
    assert.match(response.headers.get("Cache-Control"), /no-store/);
    assert.equal(response.headers.get("Referrer-Policy"), "no-referrer");
    assert.match(response.headers.get("X-Robots-Tag"), /noindex/);
    assert.match(csp, /default-src 'none'/);
    assert.match(csp, /frame-ancestors 'none'/);
    assert.doesNotMatch(csp, /unsafe-inline|https:|connect-src/);
    for (const tag of ["script", "style"]) {
      const contents = new RegExp(`<${tag}>([\\s\\S]+?)</${tag}>`).exec(html)?.[1];
      assert.ok(contents); assert.ok(csp.includes(`'sha256-${createHash("sha256").update(contents).digest("base64")}'`));
    }
    assert.doesNotMatch(html, /<(?:script|link|img)[^>]+(?:src|href)=/);
    assert.equal(html.includes(syntheticKey), result === "ready");
    assert.equal(html.includes('id="copy-key"'), result === "ready");
    assert.equal(html.includes('id="check-status"'), result === "payment_pending");
    assert.match(html, /mailto:support@cliphoard.dev/);
  });
}
test("claim escapes key and link attributes, retaining a selectable no-JavaScript key", async () => {
  const html = await (await claimPage({ result: "ready", licence: '</textarea><script>alert("x")</script>',
    download: 'https://download.example/?x="&y=<bad>' })).text();
  assert.doesNotMatch(html, /<script>alert/);
  assert.match(html, /&lt;\/textarea&gt;&lt;script&gt;alert\(&quot;x&quot;\)/);
  assert.ok(html.includes('href="https://download.example/?x=&quot;&amp;y=&lt;bad&gt;"'));
  assert.match(html, /readonly rows="5"/);
  assert.match(html, /<noscript><p>Select the key/);
  assert.match(html, /Settings → Pro/); assert.match(html, /separate in-app purchase/);
});

function clientFixture({ clipboard = "success", saved = "system", storageBlocked = false, state = "ready" } = {}) {
  const values = new Map([["cliphoard:purchase:appearance", saved]]), copied = [], selections = [], reloads = [];
  const node = (value = "") => ({ value, hidden: true, textContent: "", disabled: false, listeners: {},
    addEventListener(type, fn) { this.listeners[type] = fn; },
    focus() { selections.push("focus"); }, select() { selections.push("select"); } });
  const elements = { appearance: node("system"), "appearance-control": node() };
  if (state === "ready") Object.assign(elements, { "licence-key": node(syntheticKey), "copy-key": node(), "copy-status": node(), "copy-label": node() });
  if (state === "pending") elements["check-status"] = node();
  const runtime = {
    document: { documentElement: { dataset: {} }, getElementById: id => elements[id] ?? null },
    sessionStorage: { getItem: key => { if (storageBlocked) throw new Error("storage disabled"); return values.get(key); },
      setItem: (key, value) => { if (storageBlocked) throw new Error("storage disabled"); values.set(key, value); } },
    navigator: clipboard === "missing" ? {} : { clipboard: { writeText: async value => {
      if (clipboard === "denied") throw new Error("permission denied"); copied.push(value);
    } } },
    location: { reload: () => reloads.push(true) },
  };
  return { runtime, elements, values, copied, selections, reloads };
}
test("copy writes the full unchanged key only on click, announces success and persists only appearance", async () => {
  const f = clientFixture({ saved: "dark" }); claimPageClient(f.runtime);
  assert.deepEqual(f.copied, []); assert.equal(f.elements["copy-key"].hidden, false);
  assert.equal(f.runtime.document.documentElement.dataset.appearance, "dark");
  await f.elements["copy-key"].listeners.click();
  assert.deepEqual(f.copied, [syntheticKey]); assert.equal(f.elements["copy-label"].textContent, "Copied");
  assert.match(f.elements["copy-status"].textContent, /Key copied/);
  assert.equal(f.elements["copy-key"].disabled, false);
  assert.deepEqual([...f.values], [["cliphoard:purchase:appearance", "dark"]]);
});
for (const clipboard of ["denied", "missing"]) test(`clipboard ${clipboard}: selects key for manual copy, never reports success`, async () => {
  const f = clientFixture({ clipboard, storageBlocked: true }); claimPageClient(f.runtime);
  await f.elements["copy-key"].listeners.click();
  assert.deepEqual(f.copied, []); assert.deepEqual(f.selections, ["focus", "select"]);
  assert.match(f.elements["copy-status"].textContent, /⌘C.*Ctrl\+C/);
  assert.equal(f.elements["copy-label"].textContent, "Copy key"); assert.equal(f.elements["copy-key"].disabled, false);
});
test("pending and blocked clients do not copy or poll; pending refresh is explicit", () => {
  for (const state of ["pending", "blocked"]) {
    const f = clientFixture({ state, saved: "invalid" }); claimPageClient(f.runtime);
    assert.equal(f.runtime.document.documentElement.dataset.appearance, "system");
    assert.deepEqual(f.copied, []); assert.deepEqual(f.reloads, []);
    if (state === "pending") {
      f.elements["check-status"].listeners.click();
      assert.deepEqual(f.reloads, [true]); assert.equal(f.elements["check-status"].disabled, true);
    }
  }
});
test("emitted page script runs standalone without imported names or Worker globals", async () => {
  const html = await (await claimPage({ result: "ready", licence: syntheticKey, download: "https://cliphoard.dev/#download" })).text();
  const script = /<script>([\s\S]+?)<\/script>/.exec(html)[1], f = clientFixture();
  runInNewContext(script, f.runtime);
  await f.elements["copy-key"].listeners.click(); assert.deepEqual(f.copied, [syntheticKey]);
});
