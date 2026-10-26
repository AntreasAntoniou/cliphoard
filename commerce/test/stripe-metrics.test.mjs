import test from "node:test";
import assert from "node:assert/strict";
import { fixture, wireOrders } from "./stripe-fixtures.mjs";
import { createStripeWorker } from "../src/stripe-worker.mjs";

async function metricsFixture() {
  const f = await fixture(), points = [];
  f.env.METRICS = { writeDataPoint: (p) => points.push(p) };
  return { ...f, points, count: (event) => points.filter((p) => p.blobs[3] === event).length };
}
test("checkout and issuance metrics follow persisted transitions, not webhook replays", async () => {
  const f = await metricsFixture();
  await f.service().start(f.ref); await f.service().start(f.ref);
  f.stripe.pay(); await f.service().paid(f.ref, f.stripe.s.id); await f.service().paid(f.ref, f.stripe.s.id);
  await f.service().drain(); await f.service().drain();
  assert.equal(f.count("checkout_created"), 1); assert.equal(f.count("licence_issued"), 1);
  assert.equal(f.count("email_attempt"), 1); assert.equal(f.count("email_accepted"), 1);
  const serial = JSON.stringify(f.points), order = await f.storage.get("order");
  for (const forbidden of [f.ref, order.licence, f.token(), f.env.STRIPE_ACCOUNT_ID, "synthetic-buyer", "@example.invalid"]) assert.ok(!serial.includes(forbidden));
  for (const p of f.points) assert.equal(p.blobs[2], "test");
  await f.service().refund(f.ref, f.stripe.s.id); await f.service().refund(f.ref, f.stripe.s.id);
  assert.equal(f.count("payment_blocked"), 1);
});
test("failed email and later retry are distinct, no false accepted event", async () => {
  const f = await metricsFixture(); await f.service().start(f.ref); f.stripe.pay(); await f.service().paid(f.ref, f.stripe.s.id);
  const send = f.env.EMAIL.send; f.env.EMAIL.send = async () => { throw new Error("synthetic mail failure"); };
  await assert.rejects(() => f.service().drain()); assert.equal(f.count("email_failed"), 1); assert.equal(f.count("email_accepted"), 0);
  f.env.EMAIL.send = send; await f.service().drain(); assert.equal(f.count("email_attempt"), 2); assert.equal(f.count("email_accepted"), 1);
});
test("analytics outage cannot stop payment, recovery or full-key email", async () => {
  const f = await fixture(); f.env.METRICS = { writeDataPoint() { throw new Error("analytics unavailable"); } };
  await f.service().start(f.ref); f.stripe.pay(); await f.service().paid(f.ref, f.stripe.s.id);
  const claim = await f.service().claim(f.ref, f.token()); assert.match(claim.licence, /^CLIP1-/);
  assert.equal((await f.service().drain()).result, "email_accepted"); assert.ok(f.sent[0].text.includes(claim.licence));
});
test("public request metrics classify routes without recording claim query or error detail", async () => {
  const f = await metricsFixture(); wireOrders(f);
  const worker = createStripeWorker(() => f.stripe);
  const response = await worker.fetch(new Request(f.env.PUBLIC_ORIGIN + "/pro/claim?token=private&order=bad"), f.env);
  assert.equal(response.status, 400); assert.equal(f.count("request_rejected"), 1);
  assert.equal(f.points.at(-1).blobs[4], "claim"); assert.ok(!JSON.stringify(f.points).includes("private"));
});
