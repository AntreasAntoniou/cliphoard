import test from "node:test";
import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { fixture, wireOrders } from "./stripe-fixtures.mjs";
import { createStripeWorker } from "../src/stripe-worker.mjs";
import { checkoutPageClient } from "../src/stripe-checkout-client.mjs";

const ATTEMPT_KEY = "cliphoard:purchase:attempt:v1";
function clientFixture({ saved, reply, time = Date.now() } = {}) {
  const values = new Map(saved === undefined ? [] : [[ATTEMPT_KEY, saved]]), calls = [], redirects = [], events = new Map();
  const node = () => ({ textContent: "", disabled: false, value: "system", listeners: {}, addEventListener(type, fn) { this.listeners[type] = fn; } });
  const button = node(), status = node(), appearance = node();
  const runtime = {
    document: { documentElement: { dataset: {} }, getElementById: (id) => ({ checkout: button, "checkout-status": status, appearance })[id] },
    sessionStorage: { getItem: (key) => values.get(key) ?? null, setItem: (key, value) => values.set(key, value) },
    crypto: { randomUUID }, Date: { now: () => time }, AbortController, setTimeout, clearTimeout,
    location: { assign: (url) => redirects.push(url) }, addEventListener: (type, fn) => events.set(type, fn),
    fetch: async (url, options) => { calls.push({ url, options }); return reply ? reply() : Response.json({ result: "checkout_ready", url: "https://checkout.stripe.com/c/pay/cs_test_Fixture" }); },
  };
  return { runtime, values, calls, redirects, button, status, appearance, events, click: () => button.listeners.click() };
}
test("front door has truthful enabled purchase copy, Free path and hashed inline-only CSP", async () => {
  const f = await fixture(); wireOrders(f); f.env.STRIPE_API_KEY = "rk_test_synthetic0123456789012345";
  f.env.CANCEL_URL = f.env.PUBLIC_ORIGIN + "/?cancelled=1";
  const response = await createStripeWorker(() => { throw new Error("No provider call expected"); }).fetch(new Request(f.env.PUBLIC_ORIGIN + "/"), f.env);
  assert.equal(response.status, 200); const html = await response.text(), csp = response.headers.get("Content-Security-Policy");
  for (const text of ["US$10", "one-time", "applicable taxes", "direct-download", "offline", "Free", "Store edition", 'id="checkout"']) assert.ok(html.includes(text), text);
  for (const tag of ["script", "style"]) {
    const content = new RegExp(`<${tag}>([\\s\\S]+?)</${tag}>`).exec(html)?.[1]; assert.ok(content);
    assert.ok(csp.includes(`'sha256-${createHash("sha256").update(content).digest("base64")}'`));
  }
  assert.ok(!csp.includes("unsafe-inline")); assert.match(csp, /connect-src 'self'/);
  for (const secret of [f.env.STRIPE_API_KEY, f.env.CLIPHOARD_SIGNING_SEED, f.env.CLAIM_ENCRYPTION_KEY, f.env.STRIPE_WEBHOOK_SECRET]) assert.ok(!html.includes(secret));
  assert.equal(response.headers.get("Referrer-Policy"), "no-referrer");
});
test("disabled/default or missing prerequisites never render a checkout button", async () => {
  for (const missing of ["CHECKOUT_ENABLED", "ISSUANCE_ENABLED", "DELIVERY_ENABLED", "EMAIL_DELIVERY_ENABLED", "STRIPE_WEBHOOK_SECRET", "STRIPE_API_KEY", "CLAIM_ENCRYPTION_KEY", "CLIPHOARD_SIGNING_SEED", "EMAIL", "STRIPE_ORDERS", "CHECKOUT_RATE_LIMITER"]) {
    const f = await fixture(); wireOrders(f); f.env.STRIPE_API_KEY = "rk_test_synthetic0123456789012345";
    f.env.CANCEL_URL = f.env.PUBLIC_ORIGIN + "/?cancelled=1"; delete f.env[missing];
    const response = await createStripeWorker().fetch(new Request(f.env.PUBLIC_ORIGIN + "/"), f.env), html = await response.text();
    assert.equal(response.status, 200); assert.match(html, /Purchases are not available yet/); assert.ok(!html.includes('id="checkout"'), missing);
  }
  const response = await createStripeWorker().fetch(new Request("https://purchase.example/"), {});
  assert.equal(response.status, 200); assert.match(await response.text(), /Purchases are not available yet/);
});
test("front door handles cancellation, enforces origin/method/query and escapes configuration URLs", async () => {
  const f = await fixture(); wireOrders(f); f.env.CANCEL_URL = f.env.PUBLIC_ORIGIN + "/?cancelled=1";
  f.env.DOWNLOAD_URL = "https://download.example/?a=1&b=%22";
  const w = createStripeWorker();
  const html = await (await w.fetch(new Request(f.env.CANCEL_URL), f.env)).text();
  assert.match(html, /You left checkout/); assert.ok(html.includes("?a=1&amp;b=%22"));
  assert.equal((await w.fetch(new Request("https://other.example/"), f.env)).status, 400);
  assert.equal((await w.fetch(new Request(f.env.PUBLIC_ORIGIN + "/?unexpected=1"), f.env)).status, 400);
  assert.equal((await w.fetch(new Request(f.env.PUBLIC_ORIGIN + "/", { method: "POST" }), f.env)).status, 405);
});
test("client persists only attempt metadata before one same-origin POST, then validates redirect", async () => {
  const f = clientFixture(); checkoutPageClient(f.runtime); await f.click();
  assert.equal(f.calls.length, 1); assert.equal(f.calls[0].url, "/checkout/stripe");
  const saved = JSON.parse(f.values.get(ATTEMPT_KEY)); assert.equal(saved.attempts, 1);
  assert.deepEqual(Object.keys(saved).sort(), ["attempts", "created", "orderRef"]);
  assert.deepEqual(JSON.parse(f.calls[0].options.body), { orderRef: saved.orderRef });
  assert.equal(f.calls[0].options.credentials, "omit"); assert.equal(f.calls[0].options.mode, "same-origin");
  assert.equal(f.redirects[0], "https://checkout.stripe.com/c/pay/cs_test_Fixture");
});
test("uncertain failures retain the same UUID across reload and stop after three manual attempts", async () => {
  const f = clientFixture({ reply: () => { throw new Error("connection lost"); } }); checkoutPageClient(f.runtime);
  await f.click(); const original = JSON.parse(f.values.get(ATTEMPT_KEY));
  const g = clientFixture({ saved: f.values.get(ATTEMPT_KEY), reply: () => Response.json({ result: "service_unavailable" }, { status: 503 }) });
  checkoutPageClient(g.runtime); assert.equal(g.calls.length, 0); await g.click(); await g.click(); await g.click();
  assert.equal(g.calls.length, 2); assert.equal(JSON.parse(g.values.get(ATTEMPT_KEY)).orderRef, original.orderRef);
  assert.equal(g.button.disabled, true); assert.match(g.status.textContent, /contact support/i);
});
test("client blocks concurrent clicks, unavailable storage and stale/invalid attempts without creating new UUID", async () => {
  let finish; const f = clientFixture({ reply: () => new Promise((resolve) => { finish = resolve; }) });
  checkoutPageClient(f.runtime); const first = f.click(); await f.click(); assert.equal(f.calls.length, 1);
  finish(Response.json({ result: "service_unavailable" }, { status: 503 })); await first;
  for (const saved of ["bad JSON", JSON.stringify({ orderRef: randomUUID(), attempts: 1, created: Date.now() - 30 * 60 * 1000 })]) {
    const g = clientFixture({ saved }); checkoutPageClient(g.runtime); await g.click(); assert.equal(g.calls.length, 0);
  }
  const g = clientFixture(); g.runtime.sessionStorage.setItem = () => { throw new Error("storage blocked"); };
  checkoutPageClient(g.runtime); await g.click(); assert.equal(g.calls.length, 0);
});
test("restored or older landing documents adopt the shared attempt before every submission", async () => {
  const a = clientFixture(), b = clientFixture(); b.runtime.sessionStorage = a.runtime.sessionStorage;
  checkoutPageClient(a.runtime); checkoutPageClient(b.runtime); await b.click();
  const first = JSON.parse(a.values.get(ATTEMPT_KEY));
  a.events.get("pageshow")({ persisted: true }); await a.click();
  assert.equal(JSON.parse(a.calls[0].options.body).orderRef, first.orderRef);
  assert.equal(JSON.parse(a.values.get(ATTEMPT_KEY)).attempts, 2);
  b.events.get("pageshow")({ persisted: true }); await b.click();
  assert.equal(JSON.parse(b.calls[1].options.body).orderRef, first.orderRef);
  assert.equal(JSON.parse(a.values.get(ATTEMPT_KEY)).attempts, 3);
  a.events.get("pageshow")({ persisted: true }); await a.click(); assert.equal(a.calls.length, 1);
  a.values.delete(ATTEMPT_KEY); a.events.get("pageshow")({ persisted: true }); await a.click();
  assert.equal(a.calls.length, 1); assert.equal(a.values.has(ATTEMPT_KEY), false);
});
test("client rejects hostile redirects and restores controls when returning from Checkout", async () => {
  for (const url of ["https://checkout.stripe.com.evil.invalid/pay", "javascript:alert(1)", "http://checkout.stripe.com/pay", "https://user:secret@checkout.stripe.com/pay", "https://checkout.stripe.com:444/pay"]) {
    const f = clientFixture({ reply: () => Response.json({ result: "checkout_ready", url }) });
    checkoutPageClient(f.runtime); await f.click(); assert.equal(f.redirects.length, 0);
  }
  const f = clientFixture(); checkoutPageClient(f.runtime); await f.click();
  f.events.get("pageshow")({ persisted: true }); assert.equal(f.button.disabled, false); assert.match(f.button.textContent, /Continue/);
  f.appearance.value = "dark"; f.appearance.listeners.change(); assert.equal(f.runtime.document.documentElement.dataset.appearance, "dark");
});
