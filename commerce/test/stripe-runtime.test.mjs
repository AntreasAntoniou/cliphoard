import test from "node:test";
import assert from "node:assert/strict";
import { Miniflare, Log, LogLevel } from "miniflare";
import { fileURLToPath } from "node:url";
import { fixture, event, webhookRequest } from "./stripe-fixtures.mjs";

test("workerd: actual Stripe DO storage/serialization, encrypted token, webhook, key and refund", { timeout: 30000 }, async () => {
  const f = await fixture();
  const { EMAIL, CHECKOUT_RATE_LIMITER, ...bindings } = f.env;
  bindings.STRIPE_API_KEY = "rk_test_synthetic0123456789012345";
  const deliveries = [], outbound = [];
  // Include the shared telemetry module outside commerce/ in Workerd's module root.
  const mf = new Miniflare({
    modules: true, modulesRoot: fileURLToPath(new URL("../../", import.meta.url)), scriptPath: fileURLToPath(new URL("./stripe-runtime-harness.mjs", import.meta.url)),
    compatibilityDate: "2026-07-01", host: "127.0.0.1", port: 0, log: new Log(LogLevel.NONE), bindings,
    durableObjects: { STRIPE_ORDERS: { className: "TestStripeOrder", useSQLite: true } },
    serviceBindings: { TEST_EMAIL: async (request) => { deliveries.push(await request.json()); return Response.json({ messageId: "synthetic-runtime-accepted" }); } },
    outboundService: async (request) => {
      const url = new URL(request.url); outbound.push(url.origin + url.pathname); assert.equal(url.origin, "https://api.stripe.com");
      let result;
      if (url.pathname === "/v1/account") result = await f.stripe.account();
      else if (url.pathname.startsWith("/v1/prices/")) result = await f.stripe.price();
      else if (url.pathname === "/v1/checkout/sessions" && request.method === "POST") {
        result = await f.stripe.createCheckout(Object.fromEntries(new URLSearchParams(await request.text())), request.headers.get("Idempotency-Key"));
      } else if (url.pathname.endsWith("/line_items")) result = await f.stripe.lineItems();
      else if (url.pathname.startsWith("/v1/checkout/sessions/")) result = await f.stripe.session(url.pathname.split("/").at(-1));
      else if (url.pathname === "/v1/checkout/sessions") result = await f.stripe.sessionsForPayment();
      else if (url.pathname.startsWith("/v1/payment_intents/")) result = await f.stripe.paymentIntent();
      else if (url.pathname.startsWith("/v1/charges/")) result = await f.stripe.charge();
      else if (url.pathname === "/v1/refunds") result = await f.stripe.refunds();
      else if (url.pathname.startsWith("/v1/refunds/")) result = await f.stripe.refund();
      else throw new Error("Unexpected synthetic request");
      return Response.json(result);
    },
  });
  async function dispatch(request) {
    return mf.dispatchFetch(request.url, { method: request.method, headers: Object.fromEntries(request.headers),
      ...(request.method === "POST" ? { body: await request.text() } : {}) });
  }
  try {
    const landing = await mf.dispatchFetch(f.env.PUBLIC_ORIGIN + "/");
    assert.equal(landing.status, 200); assert.match(await landing.text(), /id="checkout"/);
    assert.deepEqual(outbound, []); assert.equal(deliveries.length, 0);
    assert.match(await (await mf.dispatchFetch(f.env.CANCEL_URL)).text(), /You left checkout/);
    const start = () => mf.dispatchFetch(`${f.env.PUBLIC_ORIGIN}/checkout/stripe`, {
      method: "POST", headers: { "Content-Type": "application/json", Origin: f.env.PUBLIC_ORIGIN, "CF-Connecting-IP": "192.0.2.1" },
      body: JSON.stringify({ orderRef: f.ref }),
    });
    const first = await start(); assert.equal(first.status, 200, `${await first.text()} synthetic routes ${JSON.stringify(outbound)}`);
    assert.equal((await start()).status, 200); assert.equal(f.stripe.creates, 1);
    f.stripe.pay();
    const issued = await dispatch(webhookRequest(f, event(f))); assert.equal(issued.status, 200);
    const paidReplies = await Promise.all(Array.from({ length: 3 }, () => dispatch(webhookRequest(f, event(f)))));
    assert.ok(paidReplies.every((r) => r.status === 200));
    const claim = await mf.dispatchFetch(f.stripe.s.success_url); assert.equal(claim.status, 200);
    const html = await claim.text(), key = /CLIP1-[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/.exec(html)?.[0]; assert.ok(key);
    assert.ok((await (await mf.dispatchFetch(f.stripe.s.success_url)).text()).includes(key));
    for (let count = 0; count < 30 && !deliveries.length; count++) await new Promise((resolve) => setTimeout(resolve, 100));
    assert.equal(deliveries.length, 1); assert.ok(deliveries[0].text.includes(f.stripe.s.success_url));
    assert.ok(deliveries[0].text.split("\n").includes(key), "delivered email contains exactly the same key as the claim page");
    assert.ok(outbound.includes("https://api.stripe.com/v1/refunds"));
    assert.equal((await dispatch(webhookRequest(f, event(f, "refund.created")))).status, 200);
    assert.equal((await mf.dispatchFetch(f.stripe.s.success_url)).status, 410);
    await dispatch(webhookRequest(f, event(f))); assert.equal((await mf.dispatchFetch(f.stripe.s.success_url)).status, 410);
  } finally { await mf.dispose(); }
});
