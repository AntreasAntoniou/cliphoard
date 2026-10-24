import { sha256 } from "./licence.mjs";
import { stripeClient } from "./stripe-client.mjs";
import { orderService, verifyAccount } from "./stripe-order.mjs";
import { purchasePage } from "./stripe-frontdoor.mjs";
import { API_VERSION, boundedBody, config, failure, identifier, need, objectId, ORDER_REF,
  parseJSON, response, SECURITY, verifyStripeSignature } from "./stripe-security.mjs";

const CHECKOUT_EVENTS = new Set(["checkout.session.completed", "checkout.session.async_payment_succeeded", "checkout.session.async_payment_failed"]);
const REFUND_EVENTS = new Set(["refund.created", "refund.updated", "refund.failed", "charge.refunded"]);
function escapeHtml(value) {
  return value.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}
function claimPage(result) {
  let status = 202, html = "<h1>Your key is being prepared</h1><p>Payment confirmation may take a little time. Reload this page later. Your private recovery link will also arrive by email after payment is confirmed.</p>";
  if (result.result === "payment_blocked") {
    status = 410; html = "<h1>Key delivery is unavailable</h1><p>This purchase has a refund or dispute record. Contact product support from your purchase email.</p>";
  } else if (result.result === "ready") {
    status = 200; html = `<h1>Your Cliphoard Pro key</h1><p>In the direct-download edition, open Settings → Pro, paste this key and choose Verify.</p><textarea aria-label="Cliphoard Pro key" readonly rows="6" cols="60">${escapeHtml(result.licence)}</textarea><p><a href="${escapeHtml(result.download)}" rel="noreferrer">Download Cliphoard</a></p><p>Keep this private link. This key works on every Mac you own using the direct-download edition; the Mac App Store edition uses its separate purchase.</p>`;
  }
  return new Response(`<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Cliphoard Pro key</title><main>${html}</main></html>`, {
    status, headers: { ...SECURITY, "Content-Type": "text/html; charset=utf-8", ...(status === 202 ? { "Retry-After": "60" } : {}) },
  });
}
async function orderCall(env, cfg, orderRef, action, value) {
  need(ORDER_REF.test(orderRef ?? ""), 400, "invalid_order_reference");
  need(env.STRIPE_ORDERS?.idFromName && env.STRIPE_ORDERS?.get, 503, "storage_unavailable");
  const object = env.STRIPE_ORDERS.get(env.STRIPE_ORDERS.idFromName(`${cfg.accountId}:${cfg.mode}:${orderRef}`));
  return object.fetch(new Request("https://order.internal/", {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ action, orderRef, ...value }),
  }));
}
async function webhook(request, env, cfg, stripe) {
  need(request.method === "POST", 405, "method_not_allowed");
  need(/^application\/json(?:\s*;|$)/i.test(request.headers.get("Content-Type") ?? ""), 415, "json_required");
  const raw = await boundedBody(request, 64 * 1024);
  need(await verifyStripeSignature(raw, request.headers.get("Stripe-Signature"), env.STRIPE_WEBHOOK_SECRET), 401, "invalid_signature");
  const event = parseJSON(raw);
  need(event?.object === "event" && identifier(event.id, "evt") && event.api_version === API_VERSION &&
    event.livemode === cfg.live && (event.account === undefined || event.account === cfg.accountId) &&
    event.context === undefined, 403, "event_scope_mismatch");
  if (!CHECKOUT_EVENTS.has(event.type) && !REFUND_EVENTS.has(event.type)) return response(200, "ignored_event");
  await verifyAccount(stripe, cfg);
  let session;
  if (CHECKOUT_EVENTS.has(event.type)) {
    need(event.data?.object?.object === "checkout.session" && identifier(event.data.object.id, "cs"));
    session = await stripe.session(event.data.object.id);
  } else {
    const value = event.data?.object;
    let paymentId;
    if (event.type === "charge.refunded") {
      need(value?.object === "charge" && identifier(value.id, "ch"));
      const charge = await stripe.charge(value.id);
      need(charge?.object === "charge" && charge.id === value.id && charge.livemode === cfg.live &&
        identifier(objectId(charge.payment_intent), "pi"), 409, "refund_mismatch");
      paymentId = objectId(charge.payment_intent);
    } else {
      need(value?.object === "refund" && identifier(value.id, "re"));
      const refund = await stripe.refund(value.id);
      need(refund?.object === "refund" && refund.id === value.id && identifier(objectId(refund.payment_intent), "pi"), 409, "refund_mismatch");
      paymentId = objectId(refund.payment_intent);
    }
    const sessions = await stripe.sessionsForPayment(paymentId);
    need(sessions?.object === "list" && sessions.has_more === false && Array.isArray(sessions.data) && sessions.data.length <= 1,
      409, "refund_session_ambiguous");
    if (sessions.data.length === 0) return response(200, "unowned_payment");
    session = sessions.data[0];
    need(objectId(session.payment_intent) === paymentId, 409, "refund_mismatch");
  }
  if (session?.metadata?.fulfilment !== "cliphoard-stripe-v1") return response(200, "unowned_session");
  need(session.object === "checkout.session" && identifier(session.id, "cs") && ORDER_REF.test(session.metadata?.cliphoard_order ?? ""),
    409, "session_mismatch");
  return orderCall(env, cfg, session.metadata.cliphoard_order, REFUND_EVENTS.has(event.type) ? "refund" : "paid", { sessionId: session.id });
}
export function createStripeWorker(clientFactory = stripeClient) {
  return {
    async fetch(request, env) {
      try {
        const url = new URL(request.url);
        if (url.pathname === "/") {
          need(request.method === "GET", 405, "method_not_allowed");
          return await purchasePage(env, url);
        }
        const cfg = config(env);
        need(url.origin === cfg.origin, 400, "invalid_origin");
        if (url.pathname === "/webhooks/stripe") {
          need(!url.search, 400, "unexpected_query");
          return await webhook(request, env, cfg, clientFactory(env));
        }
        if (url.pathname === "/checkout/stripe") {
          need(request.method === "POST", 405, "method_not_allowed");
          need(!url.search && request.headers.get("Origin") === cfg.origin, 403, "origin_mismatch");
          need(/^application\/json(?:\s*;|$)/i.test(request.headers.get("Content-Type") ?? ""), 415, "json_required");
          need(env.CHECKOUT_ENABLED === "true", 503, "checkout_paused");
          const ip = request.headers.get("CF-Connecting-IP");
          need(ip && typeof env.CHECKOUT_RATE_LIMITER?.limit === "function", 503, "rate_limiter_unavailable");
          const admission = await env.CHECKOUT_RATE_LIMITER.limit({ key: await sha256(`${cfg.accountId}:${ip}`) });
          need(admission?.success === true, 429, "try_later");
          const data = parseJSON(await boundedBody(request, 1024));
          need(data && Object.keys(data).length === 1 && ORDER_REF.test(data.orderRef ?? ""), 400, "invalid_order_reference");
          return await orderCall(env, cfg, data.orderRef, "start", {});
        }
        if (url.pathname === "/pro/claim") {
          need(request.method === "GET", 405, "method_not_allowed");
          need([...url.searchParams].length === 2 && url.searchParams.has("order") && url.searchParams.has("token"), 400, "invalid_claim");
          const result = await orderCall(env, cfg, url.searchParams.get("order"), "claim", { token: url.searchParams.get("token") });
          if (!result.ok) return result;
          return claimPage(await result.json());
        }
        return response(404, "not_found");
      } catch (error) { return failure(error); }
    },
  };
}

// A strongly consistent object per random order reference serializes all local
// operations, including alarms. No KV propagation window for refund tombstones.
export class StripeOrder {
  constructor(ctx, env) {
    this.ctx = ctx; this.env = env; this.tail = Promise.resolve();
  }
  serial(fn) { const result = this.tail.then(fn, fn); this.tail = result.catch(() => {}); return result; }
  service() {
    return orderService({ env: this.env, storage: this.ctx.storage, stripe: stripeClient(this.env),
      schedule: (seconds) => this.ctx.storage.setAlarm(seconds * 1000) });
  }
  fetch(request) {
    return this.serial(async () => {
      try {
        need(request.method === "POST", 405, "method_not_allowed");
        const data = parseJSON(await boundedBody(request, 4096)), service = this.service();
        let result;
        if (data.action === "start") result = await service.start(data.orderRef);
        else if (data.action === "paid") result = await service.paid(data.orderRef, data.sessionId);
        else if (data.action === "refund") result = await service.refund(data.orderRef, data.sessionId);
        else if (data.action === "claim") result = await service.claim(data.orderRef, data.token);
        else if (data.action === "retryDelivery") result = await service.retryDelivery(data.orderRef);
        else return response(404, "not_found");
        return response(200, result.result, result);
      } catch (error) { return failure(error); }
    });
  }
  alarm() {
    return this.serial(async () => {
      try { await this.service().drain(); }
      catch { throw new Error("stripe_outbox_retry_required"); }
    });
  }
}
export default createStripeWorker();
