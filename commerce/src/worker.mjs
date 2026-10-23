import { signLicence, verifyLicence, verifyWebhook, sha256 } from "./licence.mjs";

const MAX_BODY = 64 * 1024;
const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ID = /^[1-9][0-9]{0,19}$/;
const SECURITY = {
  "Cache-Control": "no-store, max-age=0",
  "Referrer-Policy": "no-referrer",
  "X-Robots-Tag": "noindex, nofollow, noarchive",
  "X-Content-Type-Options": "nosniff",
  "Content-Security-Policy": "default-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'",
  "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
};
class Rejection extends Error {
  constructor(status, code) { super(code); this.status = status; this.code = code; }
}
function reply(status, code) {
  return new Response(JSON.stringify({ result: code }), {
    status, headers: { ...SECURITY, "Content-Type": "application/json; charset=utf-8" },
  });
}
function requireThat(value, status = 400, code = "invalid_order") {
  if (!value) throw new Rejection(status, code);
}
function id(value) {
  if (typeof value === "number" && !Number.isSafeInteger(value)) return null;
  const string = typeof value === "number" || typeof value === "string" ? String(value) : "";
  return ID.test(string) ? string : null;
}

function config(env) {
  const storeId = id(env.LEMON_STORE_ID), productId = id(env.LEMON_PRODUCT_ID), variantId = id(env.LEMON_VARIANT_ID);
  requireThat(storeId && productId && variantId && ["test", "live"].includes(env.LEMON_MODE), 503, "configuration_unavailable");
  requireThat(typeof env.EXPECTED_PUBLIC_KEY_HEX === "string" && /^[a-f0-9]{64}$/i.test(env.EXPECTED_PUBLIC_KEY_HEX), 503, "configuration_unavailable");
  requireThat(env.RECEIPTS && typeof env.RECEIPTS.get === "function" && typeof env.RECEIPTS.put === "function", 503, "configuration_unavailable");
  const origin = new URL(env.PUBLIC_ORIGIN);
  requireThat(origin.protocol === "https:" && origin.origin === env.PUBLIC_ORIGIN && !origin.username && !origin.password,
    503, "configuration_unavailable");
  const download = new URL(env.DOWNLOAD_URL);
  requireThat(download.protocol === "https:" && !download.username && !download.password, 503, "configuration_unavailable");
  return { storeId, productId, variantId, mode: env.LEMON_MODE, origin: origin.origin,
    publicKey: env.EXPECTED_PUBLIC_KEY_HEX.toLowerCase(), download: download.href,
    prefix: `v1:${env.LEMON_MODE}:${storeId}:${productId}:${variantId}:` };
}

async function readBounded(request) {
  const declared = request.headers.get("Content-Length");
  if (declared !== null) requireThat(/^\d+$/.test(declared) && Number(declared) <= MAX_BODY, 413, "body_too_large");
  const reader = request.body?.getReader();
  requireThat(reader, 400, "empty_body");
  let size = 0; const chunks = [];
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_BODY) { await reader.cancel(); throw new Rejection(413, "body_too_large"); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(size); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  return bytes;
}

function orderFrom(body, cfg) {
  requireThat(body && body.data?.type === "orders");
  const a = body.data.attributes, item = a?.first_order_item;
  requireThat(a && item && id(body.data.id) && id(item.order_id) === id(body.data.id));
  requireThat(id(a.store_id) === cfg.storeId && id(item.product_id) === cfg.productId && id(item.variant_id) === cfg.variantId,
    403, "unconfigured_product");
  const isTest = cfg.mode === "test";
  requireThat(a.test_mode === isTest && item.test_mode === isTest &&
    (body.meta.test_mode === undefined || body.meta.test_mode === isTest), 403, "mode_mismatch");
  requireThat(typeof a.identifier === "string" && UUID_V4.test(a.identifier), 400, "unsupported_order_identifier");
  requireThat(typeof a.created_at === "string" && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$/.test(a.created_at));
  const issued = Math.floor(Date.parse(a.created_at) / 1000);
  requireThat(Number.isSafeInteger(issued) && issued >= 1577836800 && issued <= Math.floor(Date.now() / 1000) + 300);
  // A one-variant hosted checkout is the supported product shape. If a payload
  // explicitly discloses multiple items/quantity, refuse instead of guessing.
  for (const items of [a.order_items, body.data.relationships?.["order-items"]?.data]) {
    requireThat(items === undefined || (Array.isArray(items) && items.length === 1), 400, "unsupported_order_shape");
  }
  requireThat(item.quantity === undefined || item.quantity === 1, 400, "unsupported_order_shape");
  return { schema: 1, mode: cfg.mode, storeId: cfg.storeId, productId: cfg.productId,
    variantId: cfg.variantId, orderId: id(body.data.id), issued,
    identifier: a.identifier.toLowerCase(), attributes: a };
}

async function webhook(request, env, cfg) {
  requireThat(request.method === "POST", 405, "method_not_allowed");
  requireThat(typeof env.LEMON_WEBHOOK_SECRET === "string" && env.LEMON_WEBHOOK_SECRET.length >= 6 && env.LEMON_WEBHOOK_SECRET.length <= 40,
    503, "configuration_unavailable");
  requireThat(/^application\/json(?:\s*;|$)/i.test(request.headers.get("Content-Type") ?? ""), 415, "json_required");
  const raw = await readBounded(request);
  requireThat(await verifyWebhook(raw, request.headers.get("X-Signature"), env.LEMON_WEBHOOK_SECRET), 401, "invalid_signature");
  let body;
  try { body = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(raw)); }
  catch { throw new Rejection(400, "invalid_json"); }
  const event = body?.meta?.event_name;
  requireThat(typeof event === "string" && event === request.headers.get("X-Event-Name"), 400, "event_mismatch");
  if (!["order_created", "order_refunded"].includes(event)) return reply(200, "ignored_event");
  const order = orderFrom(body, cfg);
  const hash = await sha256(order.identifier);
  const key = `${cfg.prefix}claim:${hash}`;
  const refundKey = `${cfg.prefix}refund:${order.orderId}`;
  if (event === "order_refunded") {
    // The authenticated event itself covers both full and partial refunds;
    // do not require a fully-refunded boolean for a partial refund.
    // Append-only tombstone: a late order_created never overwrites this key.
    if (await env.RECEIPTS.get(refundKey) === null) await env.RECEIPTS.put(refundKey, "1");
    return reply(200, "refund_recorded");
  }
  requireThat(env.ISSUANCE_ENABLED === "true", 503, "issuance_paused");
  const a = order.attributes;
  // Lemon's official webhook example uses refunded:null and fractional converted
  // totals; its API example uses false and integer cents. The authenticated paid
  // status + exact product are authorization, not amount formatting or currency.
  if (a.status !== "paid" || (a.refunded !== false && a.refunded !== null) || a.refunded_at != null ||
      (a.refunded_amount != null && a.refunded_amount !== 0)) return reply(200, "not_eligible");
  if (await env.RECEIPTS.get(refundKey) !== null) return reply(200, "refund_recorded");
  const stored = { schema: 1, mode: order.mode, storeId: order.storeId, productId: order.productId,
    variantId: order.variantId, orderId: order.orderId, issued: order.issued, identifierHash: hash };
  const existing = await env.RECEIPTS.get(key);
  if (existing !== null) {
    const record = JSON.parse(existing);
    for (const [field, value] of Object.entries(stored)) requireThat(record[field] === value, 409, "order_conflict");
    requireThat(await verifyLicence(record.licence, stored, cfg.publicKey), 503, "stored_licence_invalid");
    return reply(200, "already_issued");
  }
  const licence = await signLicence(stored, env.CLIPHOARD_SIGNING_SEED, cfg.publicKey);
  // One write per new order. Same input and seed produce byte-identical values,
  // including concurrent retries which both observed an eventually-consistent miss.
  await env.RECEIPTS.put(key, JSON.stringify({ ...stored, licence }));
  return reply(200, "issued");
}

function escapeHtml(value) {
  return value.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}
function page(status, content, retry = false) {
  return new Response(`<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Cliphoard Pro key</title><main>${content}</main></html>`, {
    status, headers: { ...SECURITY, "Content-Type": "text/html; charset=utf-8", ...(retry ? { "Retry-After": "60" } : {}) },
  });
}
async function claim(request, env, cfg, url) {
  requireThat(request.method === "GET", 405, "method_not_allowed");
  requireThat(env.DELIVERY_ENABLED === "true", 503, "delivery_paused");
  const values = [...url.searchParams];
  requireThat(values.length === 1 && values[0][0] === "order" && UUID_V4.test(values[0][1]), 400, "invalid_receipt_link");
  const identifier = values[0][1].toLowerCase(), hash = await sha256(identifier);
  const raw = await env.RECEIPTS.get(`${cfg.prefix}claim:${hash}`);
  if (raw === null) return page(202, "<h1>Your key is being prepared</h1><p>This receipt is not ready here yet. Wait a minute, then reload this page. If it stays unavailable, use the support link in your receipt.</p>", true);
  const record = JSON.parse(raw);
  requireThat(record.schema === 1 && record.mode === cfg.mode && record.storeId === cfg.storeId && record.productId === cfg.productId &&
    record.variantId === cfg.variantId && record.identifierHash === hash && id(record.orderId) && Number.isSafeInteger(record.issued), 503, "stored_order_invalid");
  if (await env.RECEIPTS.get(`${cfg.prefix}refund:${record.orderId}`) !== null) return page(410, "<h1>Key delivery is unavailable</h1><p>This order has a refund record. Contact the support address in your receipt.</p>");
  requireThat(await verifyLicence(record.licence, record, cfg.publicKey), 503, "stored_licence_invalid");
  return page(200, `<h1>Your Cliphoard Pro key</h1><p>For the direct-download edition. In Cliphoard, open Settings → Pro, paste this key and choose Verify.</p><textarea aria-label="Cliphoard Pro key" readonly rows="5" cols="60">${escapeHtml(record.licence)}</textarea><p><a href="${escapeHtml(cfg.download)}" rel="noreferrer">Download Cliphoard</a></p><p>Keep this receipt link private. This key does not unlock the Mac App Store edition.</p>`);
}

export default {
  async fetch(request, env) {
    try {
      const url = new URL(request.url), cfg = config(env);
      requireThat(url.origin === cfg.origin, 400, "invalid_origin");
      if (url.pathname === "/webhooks/lemon") {
        requireThat(!url.search, 400, "unexpected_query");
        return await webhook(request, env, cfg);
      }
      if (url.pathname === "/pro/claim") return await claim(request, env, cfg, url);
      return reply(404, "not_found");
    } catch (error) {
      // Never log request URLs, payloads, keys, email addresses or exceptions.
      if (error instanceof Rejection) return reply(error.status, error.code);
      return reply(503, "service_unavailable");
    }
  },
};
