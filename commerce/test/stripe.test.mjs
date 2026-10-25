import test from "node:test";
import assert from "node:assert/strict";
import { createHmac, randomBytes, randomUUID } from "node:crypto";
import { fixture, event, webhookRequest, wireOrders } from "./stripe-fixtures.mjs";
import { createStripeWorker, StripeOrder } from "../src/stripe-worker.mjs";
import { API_VERSION, verifyStripeSignature } from "../src/stripe-security.mjs";
import { stripeClient } from "../src/stripe-client.mjs";
import { verifyLicence } from "../src/licence.mjs";

async function issued() {
  const f = await fixture(); await f.service().start(f.ref); f.stripe.pay(); await f.service().paid(f.ref, f.stripe.s.id); return f;
}
test("paid Stripe order produces stable offline CLIP1, encrypted recovery and native email", async () => {
  const f = await issued(), before = await f.storage.get("order");
  assert.equal(await verifyLicence(before.licence, { provider: "stripe", mode: "test", accountId: f.env.STRIPE_ACCOUNT_ID,
    orderId: f.stripe.s.id, issued: f.stripe.s.created }, f.env.EXPECTED_PUBLIC_KEY_HEX), true);
  const stored = JSON.stringify(before);
  for (const value of [f.token(), f.env.CLAIM_ENCRYPTION_KEY, f.env.CLIPHOARD_SIGNING_SEED, "synthetic-buyer", "@example.invalid"]) assert.ok(!stored.includes(value));
  assert.equal(f.stripe.form["managed_payments[enabled]"], "true");
  assert.equal(f.stripe.form["line_items[0][quantity]"], "1");
  assert.equal(f.stripe.form.mode, "payment");
  assert.equal(f.stripe.form.currency, "gbp");
  assert.equal(f.stripe.form.ui_mode, "hosted_page");
  for (const unsupported of ["automatic_tax", "adaptive_pricing", "payment_method_types", "invoice_creation"]) assert.ok(!Object.keys(f.stripe.form).some((k) => k.startsWith(unsupported)));
  await f.service().paid(f.ref, f.stripe.s.id);
  assert.equal((await f.storage.get("order")).licence, before.licence);
  assert.equal((await f.service().claim(f.ref, f.token())).licence, before.licence);
  assert.equal((await f.service().drain()).result, "email_accepted");
  assert.equal(f.sent.length, 1); assert.ok(f.sent[0].text.includes(f.stripe.s.success_url));
  assert.equal(f.sent[0].to, "synthetic-buyer@example.invalid");
  assert.equal((await f.storage.get("order")).mail.status, "accepted");
  await f.service().paid(f.ref, f.stripe.s.id); await f.service().drain(); assert.equal(f.sent.length, 1);
});
test("delayed payment completion cannot issue until server reports paid", async () => {
  const f = await fixture(); await f.service().start(f.ref); f.stripe.s.status = "complete";
  assert.equal((await f.service().paid(f.ref, f.stripe.s.id)).result, "payment_pending");
  assert.equal((await f.storage.get("order")).licence, null);
  f.stripe.pay(); assert.equal((await f.service().paid(f.ref, f.stripe.s.id)).result, "issued");
});
test("manual currency options cannot change the explicitly submitted integration currency", async () => {
  const f = await fixture(); f.stripe.p.currency_options = { eur: { unit_amount: 900 } };
  await f.service().start(f.ref); assert.equal(f.stripe.form.currency, "gbp");
});
test("refund before issue and late paid replay never issue or email", async () => {
  const f = await fixture(); await f.service().start(f.ref); f.stripe.pay();
  assert.equal((await f.service().refund(f.ref, f.stripe.s.id)).result, "payment_blocked");
  assert.equal((await f.service().paid(f.ref, f.stripe.s.id)).result, "payment_blocked");
  assert.equal((await f.service().claim(f.ref, f.token())).result, "payment_blocked");
  await f.service().drain(); assert.equal(f.sent.length, 0); assert.equal((await f.storage.get("order")).licence, null);
});
for (const [label, mutate] of [
  ["wrong account", (f) => { f.stripe.a.id = "acct_Other"; }],
  ["wrong price", (f) => { f.stripe.items.data[0].price.id = "price_Other"; }],
  ["wrong product", (f) => { f.stripe.items.data[0].price.product = "prod_Other"; }],
  ["wrong mode", (f) => { f.stripe.s.livemode = true; }],
  ["ordinary Stripe session", (f) => { f.stripe.s.managed_payments.enabled = false; }],
  ["ordinary Stripe payment", (f) => { f.stripe.pi.managed_payments = null; }],
  ["quantity", (f) => { f.stripe.items.data[0].quantity = 2; }],
  ["hidden line item", (f) => { f.stripe.items.has_more = true; }],
  ["second line item", (f) => { f.stripe.items.data.push(structuredClone(f.stripe.items.data[0])); }],
  ["wrong currency", (f) => { f.stripe.s.currency = "eur"; }],
  ["discount", (f) => { f.stripe.s.total_details.amount_discount = 100; }],
  ["short capture", (f) => { f.stripe.ch.amount_captured = 100; }],
  ["wrong payment association", (f) => { f.stripe.ch.payment_intent = "pi_Other"; }],
  ["wrong issuer public key", (f) => { f.env.EXPECTED_PUBLIC_KEY_HEX = "1".repeat(64); }],
  ["swapped claim URL", (f) => { f.stripe.s.success_url += "tamper"; }],
  ["wrong session identity", (f) => { f.stripe.s.client_reference_id = randomUUID(); }],
]) test(`fails closed: ${label}`, async () => {
  const f = await fixture(); await f.service().start(f.ref); f.stripe.pay(); mutate(f);
  await assert.rejects(() => f.service().paid(f.ref, f.stripe.s.id));
  assert.equal((await f.storage.get("order")).licence, null); assert.equal(f.sent.length, 0);
});
for (const [label, mutate] of [
  ["partial refund", (f) => { f.stripe.ch.amount_refunded = 50; }],
  ["pending refund", (f) => { f.stripe.refundRows = [{ id: "re_Test", status: "pending" }]; }],
  ["dispute", (f) => { f.stripe.ch.disputed = true; }],
]) test(`live API ${label} blocks claim even before its webhook arrives`, async () => {
  const f = await issued(); mutate(f);
  assert.equal((await f.service().claim(f.ref, f.token())).result, "payment_blocked");
  f.stripe.ch.amount_refunded = 0; f.stripe.ch.disputed = false; f.stripe.refundRows = [];
  assert.equal((await f.service().paid(f.ref, f.stripe.s.id)).result, "payment_blocked");
  await f.service().drain(); assert.equal(f.sent.length, 0);
});
test("retries uncertain create with identical Stripe key/params; never after safety window", async () => {
  const f = await fixture(), original = f.stripe.createCheckout.bind(f.stripe);
  f.stripe.createCheckout = async (...args) => { await original(...args); throw new Error("lost reply"); };
  await assert.rejects(() => f.service().start(f.ref));
  const encrypted = (await f.storage.get("order")).sealed;
  f.stripe.createCheckout = original; await f.service().start(f.ref);
  assert.deepEqual((await f.storage.get("order")).sealed, encrypted); assert.equal(f.stripe.creates, 2);
  const g = await fixture(); g.stripe.createCheckout = async () => { throw new Error("uncertain"); };
  await assert.rejects(() => g.service().start(g.ref)); g.advance(1801);
  await assert.rejects(() => g.service().start(g.ref), { code: "checkout_create_needs_reconciliation" });
});
test("claim token tamper, ciphertext tamper, missing/rotated key all fail closed", async () => {
  const f = await issued();
  await assert.rejects(() => f.service().claim(f.ref, randomBytes(32).toString("base64url")), { code: "claim_unavailable" });
  const saved = await f.storage.get("order"), corrupt = structuredClone(saved);
  corrupt.sealed.ciphertext = (corrupt.sealed.ciphertext[0] === "A" ? "B" : "A") + corrupt.sealed.ciphertext.slice(1);
  await f.storage.put("order", corrupt);
  await assert.rejects(() => f.service().claim(f.ref, f.token()));
  await f.storage.put("order", saved); f.env.CLAIM_KEY_ID = "claim-v2";
  await assert.rejects(() => f.service().claim(f.ref, f.token()), { code: "claim_key_unavailable" });
  f.env.CLAIM_KEY_ID = "claim-v1"; delete f.env.CLAIM_ENCRYPTION_KEY;
  await assert.rejects(() => f.service().drain()); assert.equal(f.sent.length, 0);
});
test("stored scope and order collision cannot reuse a claim or issue into another order", async () => {
  const f = await issued(); const saved = await f.storage.get("order");
  await assert.rejects(() => f.service().start(randomUUID()), { code: "stored_order_invalid" });
  f.env.STRIPE_UNIT_AMOUNT = "2000";
  await assert.rejects(() => f.service().claim(f.ref, f.token()), { code: "stored_order_invalid" });
  assert.deepEqual(await f.storage.get("order"), saved);
});
test("checkout disabled without concrete email binding or matching signer", async () => {
  for (const change of [(f) => { delete f.env.EMAIL; }, (f) => { f.env.EMAIL_DELIVERY_ENABLED = "false"; },
    (f) => { f.env.CLIPHOARD_SIGNING_SEED = randomBytes(32).toString("base64"); }]) {
    const f = await fixture(); change(f); await assert.rejects(() => f.service().start(f.ref)); assert.equal(f.stripe.creates, 0);
  }
});
test("checkout refuses missing or malformed webhook secrets before creating a payable session", async () => {
  for (const secret of [undefined, "", "whsec_short", "sk_" + "live_" + "notAWebhookSecret0123456789", "whsec_validLookingValue0123456789\n"]) {
    const f = await fixture(); f.env.STRIPE_WEBHOOK_SECRET = secret; wireOrders(f);
    const request = new Request(`${f.env.PUBLIC_ORIGIN}/checkout/stripe`, {
      method: "POST", headers: { Origin: f.env.PUBLIC_ORIGIN, "Content-Type": "application/json", "CF-Connecting-IP": "192.0.2.1" },
      body: JSON.stringify({ orderRef: f.ref }),
    });
    const reply = await createStripeWorker(() => f.stripe).fetch(request, f.env);
    assert.equal(reply.status, 503); assert.equal(f.stripe.creates, 0);
    assert.equal((await reply.json()).result, "webhook_unavailable");
  }
});
test("other missing deployment secrets fail before payable session creation", async () => {
  for (const key of ["CLAIM_ENCRYPTION_KEY", "CLIPHOARD_SIGNING_SEED"]) {
    const f = await fixture(); delete f.env[key];
    await assert.rejects(() => f.service().start(f.ref)); assert.equal(f.stripe.creates, 0);
  }
  for (const key of [undefined, "", "rk_" + "live_" + "wrongMode0123456789012345", "not-a-key"]) {
    const f = await fixture(); wireOrders(f); f.env.STRIPE_API_KEY = key;
    let providerCalls = 0;
    assert.throws(() => stripeClient(f.env, async () => { providerCalls++; return Response.json({}); }));
    assert.equal(providerCalls, 0); assert.equal(f.stripe.creates, 0);
  }
});
test("delivery outbox survives failure and uses same link after retry", async () => {
  const f = await issued(), send = f.env.EMAIL.send; f.env.EMAIL.send = async () => { throw new Error("synthetic outage"); };
  await assert.rejects(() => f.service().drain()); assert.equal((await f.storage.get("order")).mail.status, "pending");
  assert.ok(f.alarms.length >= 2); f.env.EMAIL.send = send;
  await f.service().drain(); assert.equal(f.sent.length, 1); assert.ok(f.sent[0].text.includes(f.stripe.s.success_url));
});
test("native email and alarm failures suppress provider details", async () => {
  const f = await issued();
  f.env.EMAIL.send = async () => { throw new Error("synthetic-buyer@example.invalid private provider response"); };
  await assert.rejects(() => f.service().drain(), { code: "email_unavailable", message: "email_unavailable" });
  const object = new StripeOrder({}, f.env);
  object.service = () => ({ drain: async () => { throw new Error("private provider response"); } });
  await assert.rejects(() => object.alarm(), { message: "stripe_outbox_retry_required" });
});
test("private operator recovery resends the same key/link to the current Stripe recipient", async () => {
  const f = await issued(); await f.service().drain();
  const licence = (await f.storage.get("order")).licence;
  f.stripe.s.customer_details.email = "synthetic-recovered@example.invalid";
  assert.equal((await f.service().retryDelivery(f.ref)).result, "email_queued");
  await f.service().drain();
  assert.equal(f.sent.length, 2); assert.equal(f.sent[1].to, "synthetic-recovered@example.invalid");
  assert.equal(f.sent[0].text, f.sent[1].text); assert.equal((await f.storage.get("order")).licence, licence);
  assert.ok(!JSON.stringify(await f.storage.get("order")).includes("synthetic-recovered"));
  f.stripe.ch.amount_refunded = 1;
  assert.equal((await f.service().retryDelivery(f.ref)).result, "payment_blocked");
  await f.service().drain(); assert.equal(f.sent.length, 2);
});
test("email attempts are bounded; only private recovery resets an exhausted outbox", async () => {
  const f = await issued(), send = f.env.EMAIL.send;
  f.env.EMAIL.send = async () => { throw new Error("synthetic outage"); };
  for (let count = 0; count < 12; count++) await assert.rejects(() => f.service().drain());
  assert.equal((await f.service().drain()).result, "exhausted");
  await f.service().paid(f.ref, f.stripe.s.id);
  assert.equal((await f.storage.get("order")).mail.status, "exhausted");
  f.env.EMAIL.send = send; await f.service().retryDelivery(f.ref); await f.service().drain();
  assert.equal(f.sent.length, 1); assert.equal((await f.storage.get("order")).mail.attempts, 1);
  const worker = createStripeWorker(() => f.stripe);
  assert.equal((await worker.fetch(new Request(`${f.env.PUBLIC_ORIGIN}/retryDelivery`, { method: "POST" }), f.env)).status, 404);
});
test("ambiguous email acceptance can duplicate only the same recovery message", async () => {
  const f = await issued(), original = f.env.EMAIL.send;
  f.env.EMAIL.send = async (message) => { const r = await original(message); f.storage.failPut = true; return r; };
  await assert.rejects(() => f.service().drain()); f.storage.failPut = false; f.env.EMAIL.send = original;
  await f.service().drain(); assert.equal(f.sent.length, 2); assert.deepEqual(f.sent[0], f.sent[1]);
});
test("email without recipient stays pending; no PII is written to durable state", async () => {
  const f = await issued(); f.stripe.s.customer_details.email = "bad\r\nBcc:attacker@example.invalid";
  await assert.rejects(() => f.service().drain()); assert.equal(f.sent.length, 0);
  assert.ok(!JSON.stringify(await f.storage.get("order")).includes("attacker"));
});
test("timestamped signature verifies raw bytes and rejects stale/future/ambiguous/tampered headers", async () => {
  const f = await fixture(), raw = new TextEncoder().encode('{"value":"£"}'), now = Math.floor(Date.now() / 1000);
  const mac = createHmac("sha256", f.env.STRIPE_WEBHOOK_SECRET).update(`${now}.`).update(raw).digest("hex");
  assert.equal(await verifyStripeSignature(raw, `t=${now},v1=${"a".repeat(64)},v1=${mac}`, f.env.STRIPE_WEBHOOK_SECRET, now), true);
  for (const [body, header, at] of [[raw, `t=${now},v1=${mac}`, now + 301], [raw, `t=${now},v1=${mac}`, now - 301],
    [raw, `t=${now},t=${now},v1=${mac}`, now], [new TextEncoder().encode('{"value": "£"}'), `t=${now},v1=${mac}`, now],
    [raw, `t=${now},v0=${mac}`, now]]) assert.equal(await verifyStripeSignature(body, header, f.env.STRIPE_WEBHOOK_SECRET, at), false);
});
test("webhook distrusts event payment data and routes only current configured session", async () => {
  const f = await fixture(); await f.service().start(f.ref); wireOrders(f);
  const worker = createStripeWorker(() => f.stripe), e = event(f);
  e.data.object.payment_status = "paid";
  assert.equal((await (await worker.fetch(webhookRequest(f, e), f.env)).json()).result, "payment_pending");
  f.stripe.pay(); const good = await worker.fetch(webhookRequest(f, e), f.env); assert.equal(good.status, 200);
  const r = await worker.fetch(new Request(f.stripe.s.success_url), f.env); assert.equal(r.status, 200);
  assert.match(await r.text(), /CLIP1-/); assert.equal(r.headers.get("Referrer-Policy"), "no-referrer");
  assert.match(r.headers.get("Content-Security-Policy"), /default-src 'none'/);
});
for (const [label, change] of [["mode", (e) => { e.livemode = true; }], ["account", (e) => { e.account = "acct_Other"; }],
  ["API version", (e) => { e.api_version = "2025-03-31.basil"; }], ["organization context", (e) => { e.context = "acct_Unexpected"; }]])
  test(`webhook rejects ${label} before server calls`, async () => {
    const f = await fixture(); await f.service().start(f.ref); wireOrders(f); f.stripe.calls = [];
    const e = event(f); change(e);
    assert.equal((await createStripeWorker(() => f.stripe).fetch(webhookRequest(f, e), f.env)).status, 403);
    assert.deepEqual(f.stripe.calls, []);
  });
test("webhook refunds and concurrent duplicate deliveries serialize without re-issuance", async () => {
  const f = await issued(); wireOrders(f); const worker = createStripeWorker(() => f.stripe), licence = (await f.storage.get("order")).licence;
  await Promise.all(Array.from({ length: 4 }, () => worker.fetch(webhookRequest(f, event(f)), f.env)));
  assert.equal((await f.storage.get("order")).licence, licence);
  assert.equal((await worker.fetch(webhookRequest(f, event(f, "refund.created")), f.env)).status, 200);
  assert.equal((await worker.fetch(new Request(f.stripe.s.success_url), f.env)).status, 410);
  await worker.fetch(webhookRequest(f, event(f)), f.env); await f.service().drain(); assert.equal(f.sent.length, 0);
});
test("checkout route requires same origin, bounded JSON, admission, and explicit enablement", async () => {
  const f = await fixture(); wireOrders(f); const w = createStripeWorker(() => f.stripe);
  const request = (headers = {}, body = JSON.stringify({ orderRef: f.ref })) => new Request(`${f.env.PUBLIC_ORIGIN}/checkout/stripe`, {
    method: "POST", body, headers: { Origin: f.env.PUBLIC_ORIGIN, "Content-Type": "application/json", "CF-Connecting-IP": "192.0.2.1", ...headers } });
  assert.equal((await w.fetch(request({ Origin: "https://attacker.invalid" }), f.env)).status, 403);
  assert.equal((await w.fetch(request({}, "x".repeat(1025)), f.env)).status, 413);
  f.env.CHECKOUT_RATE_LIMITER.limit = async () => ({ success: false }); assert.equal((await w.fetch(request(), f.env)).status, 429);
  f.env.CHECKOUT_RATE_LIMITER.limit = async () => ({ success: true });
  const good = await w.fetch(request(), f.env); assert.equal(good.status, 200); assert.match((await good.json()).url, /^https:\/\/checkout\.stripe\.com\//);
  f.env.CHECKOUT_ENABLED = "false"; assert.equal((await w.fetch(request(), f.env)).status, 503);
});
test("restricted API client pins version, origin, mode, timeout and redirects", async () => {
  const f = await fixture(); f.env.STRIPE_API_KEY = "rk_test_synthetic0123456789012345";
  const calls = [], client = stripeClient(f.env, async (url, options) => { calls.push({ url, options }); return Response.json({ object: "account" }); });
  await client.account(); await client.createCheckout({ mode: "payment" }, "synthetic-idempotency");
  assert.equal(calls[0].url, "https://api.stripe.com/v1/account");
  assert.equal(calls[0].options.headers["Stripe-Version"], API_VERSION); assert.equal(calls[0].options.redirect, "manual");
  assert.ok(calls[0].options.signal instanceof AbortSignal); assert.equal(calls[1].options.headers["Idempotency-Key"], "synthetic-idempotency");
  await assert.rejects(async () => client.session("../../account"));
  f.env.STRIPE_MODE = "live"; assert.throws(() => stripeClient(f.env));
});
test("API client suppresses upstream secrets/errors, bounds responses and does not retry POST", async () => {
  const f = await fixture(); f.env.STRIPE_API_KEY = "rk_test_synthetic0123456789012345"; let requests = 0;
  for (const transport of [async () => { requests++; return new Response("sensitive body", { status: 500 }); },
    async () => new Response(null, { status: 302, headers: { Location: "https://attacker.invalid/" } }),
    async () => new Response("x".repeat(256 * 1024 + 1), { headers: { "Content-Type": "application/json" } })]) {
    const client = stripeClient(f.env, transport);
    await assert.rejects(() => client.createCheckout({ mode: "payment" }, "synthetic-key"), { code: "stripe_unavailable" });
  }
  assert.equal(requests, 1);
});

test("recorded Stripe inclusive amounts remain pending until a verified payment", async () => {
  const f = await fixture(); await f.service().start(f.ref);
  // Observed in the 2026-09-30.endive test API: the inclusive subtotal is
  // 1000, not the 833 tax-exclusive component. This is still an unpaid order.
  f.stripe.s.amount_subtotal = 1000; f.stripe.s.amount_total = 1000;
  f.stripe.s.total_details.amount_tax = 167;
  Object.assign(f.stripe.items.data[0], { amount_subtotal: 1000, amount_tax: 167, amount_total: 1000 });
  assert.equal((await f.service().paid(f.ref, f.stripe.s.id)).result, "payment_pending");
  assert.equal((await f.storage.get("order")).licence, null); assert.equal(f.sent.length, 0);
  // Payment below is synthetic; the real response used for this regression
  // was open/unpaid and cannot establish a provider purchase or delivery.
  f.stripe.pay(); assert.equal((await f.service().paid(f.ref, f.stripe.s.id)).result, "issued");
  assert.equal((await f.service().claim(f.ref, f.token())).result, "ready");
});

for (const tax of [0, 167, 200, 1000]) test(`GBP inclusive payment keeps the total at £10 with tax ${tax}`, async () => {
  const f = await fixture(); await f.service().start(f.ref);
  f.stripe.s.total_details.amount_tax = tax; f.stripe.items.data[0].amount_tax = tax;
  assert.equal(f.stripe.s.amount_subtotal, 1000); assert.equal(f.stripe.items.data[0].amount_subtotal, 1000);
  f.stripe.pay(); assert.equal((await f.service().paid(f.ref, f.stripe.s.id)).result, "issued");
  assert.equal(f.stripe.pi.amount, 1000); assert.equal(f.stripe.ch.amount_captured, 1000);
});
test("exclusive tax price is refused before creating a payable session", async () => {
  const f = await fixture(); f.stripe.p.tax_behavior = "exclusive";
  await assert.rejects(() => f.service().start(f.ref), { code: "unconfigured_price" });
  assert.equal(f.stripe.creates, 0); assert.equal(f.storage.writes, 0);
});
for (const [label, change] of [
  ["tax added on top", f => { f.stripe.s.amount_subtotal = 1000; f.stripe.s.amount_total = 1167; f.stripe.items.data[0].amount_subtotal = 1000; f.stripe.items.data[0].amount_total = 1167; }],
  ["negative tax", f => { f.stripe.s.total_details.amount_tax = -1; f.stripe.items.data[0].amount_tax = -1; }],
  ["fractional tax", f => { f.stripe.s.total_details.amount_tax = 167.5; f.stripe.items.data[0].amount_tax = 167.5; }],
  ["string tax", f => { f.stripe.s.total_details.amount_tax = "167"; f.stripe.items.data[0].amount_tax = "167"; }],
  ["tax exceeds total", f => { f.stripe.s.total_details.amount_tax = 1001; f.stripe.items.data[0].amount_tax = 1001; }],
  ["Session/line tax disagreement", f => { f.stripe.s.total_details.amount_tax = 166; }],
  ["net subtotal convention", f => { f.stripe.s.amount_subtotal = 833; f.stripe.items.data[0].amount_subtotal = 833; }],
  ["subtotal mismatch", f => { f.stripe.items.data[0].amount_subtotal = 834; }],
  ["session subtotal mismatch", f => { f.stripe.s.amount_subtotal = 834; }],
  ["line discount", f => { f.stripe.items.data[0].amount_discount = 1; }],
  ["shipping", f => { f.stripe.s.total_details.amount_shipping = 1; }],
  ["line item uses USD", f => { f.stripe.items.data[0].currency = "usd"; }],
  ["price uses USD", f => { f.stripe.items.data[0].price.currency = "usd"; }],
]) test(`inclusive settlement rejects ${label}`, async () => {
  const f = await fixture(); await f.service().start(f.ref); f.stripe.pay(); change(f);
  await assert.rejects(() => f.service().paid(f.ref, f.stripe.s.id));
  assert.equal((await f.storage.get("order")).licence, null); assert.equal(f.sent.length, 0);
});

test("pre-inclusive stored orders cannot be silently reinterpreted", async () => {
  const f = await issued(), old = await f.storage.get("order"), scope = JSON.parse(old.scope);
  scope.schema = 1; delete scope.taxBehavior; old.scope = JSON.stringify(scope);
  await f.storage.put("order", old);
  await assert.rejects(() => f.service().claim(f.ref, f.token()), { code: "stored_order_invalid" });
  assert.deepEqual(await f.storage.get("order"), old);
});
