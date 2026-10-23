import test from "node:test";
import assert from "node:assert/strict";
import worker from "../src/worker.mjs";
import { environment, order, request, receipt, licenseFrom, syntheticKeys } from "./fixtures.mjs";
import { verifyLicence } from "../src/licence.mjs";

test("paid signed order issues a verified direct key; receipt binds to UUID; no personal data stored", async () => {
  const env = await environment(), payload = order();
  const response = await worker.fetch(request(env, payload), env);
  assert.equal(response.status, 200);
  assert.equal((await response.json()).result, "issued");
  const delivered = await worker.fetch(receipt(env, payload), env), html = await delivered.text();
  assert.equal(delivered.status, 200);
  const licence = licenseFrom(html);
  const stored = JSON.parse([...env.RECEIPTS.values.values()][0]);
  assert.ok(await verifyLicence(licence, stored, env.EXPECTED_PUBLIC_KEY_HEX));
  assert.equal(stored.orderId, "1001");
  assert.equal(stored.issued, 1767323045);
  const all = [...env.RECEIPTS.values.entries()].flat().join(" ");
  for (const forbidden of [payload.data.attributes.identifier, "synthetic-buyer", "Synthetic Buyer", env.CLIPHOARD_SIGNING_SEED, env.LEMON_WEBHOOK_SECRET]) {
    assert.ok(!all.includes(forbidden), "KV must omit personal data, raw UUID and secrets");
  }
  assert.equal(env.RECEIPTS.writes, 1);
});

test("normal replay skips write; stale KV and concurrent retries produce identical keys", async () => {
  const env = await environment(), payload = order();
  await worker.fetch(request(env, payload), env);
  const first = [...env.RECEIPTS.values.values()][0];
  assert.equal((await worker.fetch(request(env, payload), env)).status, 200);
  assert.equal(env.RECEIPTS.writes, 1);
  env.RECEIPTS.staleMiss = true;
  const results = await Promise.all(Array.from({ length: 4 }, () => worker.fetch(request(env, payload), env)));
  assert.ok(results.every((r) => r.status === 200));
  assert.ok([...env.RECEIPTS.values.values()].every((value) => value === first), "all writes have exactly the same signed value");
});

test("invalid signature and changed raw bytes never write or issue", async () => {
  const env = await environment(), payload = order();
  for (const signature of ["", "f".repeat(64), "not-hex", "a".repeat(63), "a".repeat(65)]) {
    assert.equal((await worker.fetch(request(env, payload, { signature }), env)).status, 401);
  }
  const signed = request(env, payload), signature = signed.headers.get("X-Signature");
  assert.equal((await worker.fetch(request(env, payload, { signature, raw: JSON.stringify(payload) + " " }), env)).status, 401);
  assert.equal(env.RECEIPTS.writes, 0);
});

test("HMAC accepts precisely the original raw formatting, not reserialized JSON", async () => {
  const env = await environment(), payload = order();
  const response = await worker.fetch(request(env, payload, { raw: JSON.stringify(payload, null, 2) + "\n" }), env);
  assert.equal(response.status, 200);
});

test("provider microsecond timestamps are accepted and signed as stable whole Unix seconds", async () => {
  const env = await environment(), p = order();
  p.data.attributes.created_at = "2026-01-02T03:04:05.123456Z";
  assert.equal((await worker.fetch(request(env, p), env)).status, 200);
  const record = JSON.parse([...env.RECEIPTS.values.values()][0]);
  assert.equal(record.issued, 1767323045);
});

test("wrong store, product, variant, order item and mode are rejected", async () => {
  const env = await environment();
  const mutations = [
    (p) => { p.data.attributes.store_id = 124; },
    (p) => { p.data.attributes.first_order_item.product_id = 457; },
    (p) => { p.data.attributes.first_order_item.variant_id = 790; },
    (p) => { p.data.attributes.first_order_item.order_id = 1002; },
    (p) => { p.data.attributes.test_mode = false; },
    (p) => { p.data.attributes.first_order_item.test_mode = false; },
    (p) => { p.meta.test_mode = false; },
    (p) => { delete p.data.attributes.test_mode; },
    (p) => { delete p.data.attributes.first_order_item.test_mode; },
  ];
  for (const change of mutations) {
    const p = order(); change(p);
    assert.ok([400, 403].includes((await worker.fetch(request(env, p), env)).status));
  }
  env.LEMON_MODE = "live";
  assert.equal((await worker.fetch(request(env, order()), env)).status, 403);
  assert.equal(env.RECEIPTS.writes, 0);
});

test("same numeric IDs in live and test stay in separate namespaces", async () => {
  const env = await environment(), p = order();
  await worker.fetch(request(env, p), env);
  const live = { ...env, LEMON_MODE: "live" }, q = structuredClone(p);
  q.meta.test_mode = false; q.data.attributes.test_mode = false; q.data.attributes.first_order_item.test_mode = false;
  assert.equal((await worker.fetch(receipt(live, q), live)).status, 202);
  assert.equal((await worker.fetch(request(live, q), live)).status, 200);
  assert.equal(env.RECEIPTS.values.size, 2);
  const records = [...env.RECEIPTS.values.values()].map(JSON.parse);
  assert.ok(records[0].licence !== records[1].licence, "mode is part of signed identity");
});

test("non-paid status and refund indicators never issue", async () => {
  const env = await environment();
  for (const changes of [{ status: "pending" }, { status: "failed" }, { status: "refunded" },
    { refunded: true }, { refunded_at: "2026-01-03T00:00:00Z" }, { refunded_amount: 1 },
    { status: "partial_refund" }, { status: "fraudulent" }, { refunded: undefined }, { refunded: "false" }]) {
    const p = order(); Object.assign(p.data.attributes, changes);
    const r = await worker.fetch(request(env, p), env);
    assert.equal(r.status, 200); assert.equal((await r.json()).result, "not_eligible");
  }
  assert.equal(env.RECEIPTS.writes, 0);
});

test("official webhook shape: nullable refunded, fractional foreign-currency totals, microseconds", async () => {
  // https://docs.lemonsqueezy.com/help/webhooks/example-payloads#order_created
  // Relevant provider field shapes, with synthetic identity and signature.
  const env = await environment(), p = order();
  Object.assign(p.data.attributes, { refunded: null, refunded_at: null,
    currency: "EUR", currency_rate: "1.08405", subtotal: 1499.985, tax: 359.775, total: 1859.76,
    created_at: "2023-01-17T12:26:23.000000Z" });
  delete p.data.attributes.refunded_amount;
  delete p.meta.test_mode;
  assert.equal((await worker.fetch(request(env, p), env)).status, 200);
  assert.equal((await worker.fetch(receipt(env, p), env)).status, 200);
});

test("authenticated paid product authorization does not depend on amounts or discounts", async () => {
  for (const total of [undefined, 0, 10.5]) {
    const env = await environment(), p = order();
    p.data.attributes.total = total;
    assert.equal((await worker.fetch(request(env, p), env)).status, 200);
    assert.equal(env.RECEIPTS.writes, 1);
  }
});

test("wrong event header and malformed signed JSON fail closed; unrelated events ignored", async () => {
  const env = await environment(), p = order();
  assert.equal((await worker.fetch(request(env, p, { headers: { "X-Event-Name": "order_refunded" } }), env)).status, 400);
  assert.equal((await worker.fetch(request(env, p, { raw: "{" }), env)).status, 400);
  const unrelated = { meta: { event_name: "customer_updated" } };
  assert.equal((await worker.fetch(request(env, unrelated), env)).status, 200);
  assert.equal(env.RECEIPTS.writes, 0);
});

test("unsupported IDs, identifiers, timestamps and multi-item shapes fail closed", async () => {
  const env = await environment();
  const changes = [
    (p) => { p.data.id = '10"1'; },
    (p) => { p.data.id = Number.MAX_SAFE_INTEGER + 1; },
    (p) => { p.data.attributes.identifier = "104e18a2-d755-1d4b-80c4-a6c1dcbe1c10"; },
    (p) => { p.data.attributes.identifier = "1001"; },
    (p) => { p.data.attributes.created_at = "not a date"; },
    (p) => { p.data.attributes.created_at = "2100-01-01T00:00:00Z"; },
    (p) => { p.data.attributes.order_items = [{}, {}]; },
    (p) => { p.data.relationships = { "order-items": { data: [{}, {}] } }; },
    (p) => { p.data.attributes.first_order_item.quantity = 2; },
  ];
  for (const change of changes) { const p = order(); change(p); assert.equal((await worker.fetch(request(env, p), env)).status, 400); }
  assert.equal(env.RECEIPTS.writes, 0);
});

test("unsupported body type, empty body, declared and streamed limits are enforced", async () => {
  const env = await environment(), p = order();
  assert.equal((await worker.fetch(request(env, p, { headers: { "Content-Type": "text/plain" } }), env)).status, 415);
  assert.equal((await worker.fetch(request(env, p, { headers: { "Content-Length": "65537" } }), env)).status, 413);
  assert.equal((await worker.fetch(request(env, p, { raw: " ".repeat(65537) }), env)).status, 413);
  assert.equal((await worker.fetch(new Request(env.PUBLIC_ORIGIN + "/webhooks/lemon", { method: "POST", headers: { "Content-Type": "application/json" } }), env)).status, 400);
  assert.equal(env.RECEIPTS.writes, 0);
});

test("refund tombstone blocks delivery and later paid replay, including refund-before-paid", async () => {
  for (const before of [false, true]) {
    const env = await environment(), p = order();
    const refund = structuredClone(p); refund.meta.event_name = "order_refunded";
    refund.data.attributes.refunded = true; refund.data.attributes.refunded_amount = 1000;
    if (!before) await worker.fetch(request(env, p), env);
    assert.equal((await worker.fetch(request(env, refund), env)).status, 200);
    assert.equal((await worker.fetch(request(env, p), env)).status, 200);
    assert.equal((await worker.fetch(receipt(env, p), env)).status, before ? 202 : 410);
    const count = env.RECEIPTS.writes;
    await worker.fetch(request(env, refund), env);
    assert.equal(env.RECEIPTS.writes, count, "duplicate refund skips same-key write");
  }
});

test("partial refund is recorded while new issuance is paused; no online revocation claim", async () => {
  const env = await environment(), p = order();
  await worker.fetch(request(env, p), env); env.ISSUANCE_ENABLED = "false";
  p.meta.event_name = "order_refunded"; p.data.attributes.refunded_amount = 100;
  assert.equal((await worker.fetch(request(env, p), env)).status, 200);
  assert.equal((await worker.fetch(receipt(env, p), env)).status, 410);
});

test("storage failures return retryable error, not delivery success", async () => {
  const env = await environment(), p = order();
  env.RECEIPTS.failWrite = true;
  assert.equal((await worker.fetch(request(env, p), env)).status, 503);
  env.RECEIPTS.failRead = true;
  assert.equal((await worker.fetch(receipt(env, p), env)).status, 503);
  assert.equal(env.RECEIPTS.writes, 0);
});

test("wrong signer and invalid secret configuration never issue", async () => {
  const env = await environment(), p = order();
  env.CLIPHOARD_SIGNING_SEED = (await syntheticKeys()).seed;
  assert.equal((await worker.fetch(request(env, p), env)).status, 503);
  env.CLIPHOARD_SIGNING_SEED = "invalid";
  assert.equal((await worker.fetch(request(env, p), env)).status, 503);
  env.LEMON_WEBHOOK_SECRET = "x";
  assert.equal((await worker.fetch(request(env, p), env)).status, 503);
  assert.equal(env.RECEIPTS.writes, 0);
});

test("pending, unknown and malformed receipt never leak or mint a licence", async () => {
  const env = await environment(), p = order();
  const pending = await worker.fetch(receipt(env, p), env);
  assert.equal(pending.status, 202); assert.equal(pending.headers.get("Retry-After"), "60");
  assert.ok(!licenseFrom(await pending.text()));
  for (const query of ["order=1001", "", `order=${p.data.attributes.identifier}&order=${p.data.attributes.identifier}`, `order=${p.data.attributes.identifier}&paid=true`]) {
    assert.equal((await worker.fetch(receipt(env, p, query), env)).status, 400);
  }
  assert.equal(env.RECEIPTS.writes, 0);
});

test("security headers and page have no automatic or third-party requests", async () => {
  const env = await environment(), p = order();
  await worker.fetch(request(env, p), env);
  const r = await worker.fetch(receipt(env, p), env), html = await r.text();
  assert.equal(r.headers.get("Cache-Control"), "no-store, max-age=0");
  assert.equal(r.headers.get("Referrer-Policy"), "no-referrer");
  assert.match(r.headers.get("X-Robots-Tag"), /noindex/);
  assert.match(r.headers.get("Content-Security-Policy"), /default-src 'none'/);
  assert.ok(!/<script|<img|<iframe|<link|http-equiv="refresh"/i.test(html));
  assert.ok(!r.headers.has("Set-Cookie"));
});

test("stored invalid or conflicting row cannot issue or disclose another order's licence", async () => {
  const env = await environment(), p = order();
  await worker.fetch(request(env, p), env);
  const key = [...env.RECEIPTS.values.keys()][0];
  const record = JSON.parse(env.RECEIPTS.values.get(key));
  record.orderId = "9999"; env.RECEIPTS.values.set(key, JSON.stringify(record));
  assert.equal((await worker.fetch(request(env, p), env)).status, 409);
  assert.equal((await worker.fetch(receipt(env, p), env)).status, 503);
  env.RECEIPTS.values.set(key, "{");
  assert.equal((await worker.fetch(receipt(env, p), env)).status, 503);
});

test("configuration, method, origin and kill switches fail closed", async () => {
  const env = await environment(), p = order();
  assert.equal((await worker.fetch(new Request(env.PUBLIC_ORIGIN + "/webhooks/lemon"), env)).status, 405);
  assert.equal((await worker.fetch(new Request("https://other.example/pro/claim?order=" + p.data.attributes.identifier), env)).status, 400);
  assert.equal((await worker.fetch(new Request(env.PUBLIC_ORIGIN + "/other"), env)).status, 404);
  env.ISSUANCE_ENABLED = "false";
  assert.equal((await worker.fetch(request(env, p), env)).status, 503);
  env.DELIVERY_ENABLED = "false";
  assert.equal((await worker.fetch(receipt(env, p), env)).status, 503);
  env.LEMON_STORE_ID = "REPLACE";
  assert.equal((await worker.fetch(receipt(env, p), env)).status, 503);
  assert.equal(env.RECEIPTS.writes, 0);
});
