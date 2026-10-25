import { base64url, fromHex } from "./licence.mjs";

export const API_VERSION = "2026-09-30.endive";
export const ORDER_REF = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
export const TOKEN = /^[A-Za-z0-9_-]{43}$/;
export const SECURITY = {
  "Cache-Control": "no-store, max-age=0", "Referrer-Policy": "no-referrer",
  "X-Robots-Tag": "noindex, nofollow, noarchive", "X-Content-Type-Options": "nosniff",
  "Content-Security-Policy": "default-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'",
  "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
};
const encoder = new TextEncoder();
export class Refusal extends Error {
  constructor(status, code) { super(code); this.status = status; this.code = code; }
}
export function need(ok, status = 400, code = "invalid_request") {
  if (!ok) throw new Refusal(status, code);
}
export function response(status, result, extra = {}) {
  return new Response(JSON.stringify({ result, ...extra }), {
    status, headers: { ...SECURITY, "Content-Type": "application/json; charset=utf-8" },
  });
}
export function failure(error) {
  return error instanceof Refusal ? response(error.status, error.code) : response(503, "service_unavailable");
}
export function identifier(value, prefix) {
  return typeof value === "string" && new RegExp(`^${prefix}_[A-Za-z0-9_]{1,180}$`).test(value);
}
export function objectId(value) { return typeof value === "string" ? value : value?.id; }
export function integer(value) { return Number.isSafeInteger(value) && value >= 0; }
export function parseJSON(bytes) {
  try { return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)); }
  catch { throw new Refusal(400, "invalid_json"); }
}
export async function boundedBody(message, maximum) {
  const declared = message.headers.get("Content-Length");
  need(declared === null || (/^\d+$/.test(declared) && Number(declared) <= maximum), 413, "body_too_large");
  const reader = message.body?.getReader();
  need(reader, 400, "empty_body");
  let size = 0; const chunks = [];
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.length;
      if (size > maximum) { await reader.cancel(); throw new Refusal(413, "body_too_large"); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const result = new Uint8Array(size); let offset = 0;
  for (const chunk of chunks) { result.set(chunk, offset); offset += chunk.length; }
  return result;
}
export function validWebhookSecret(secret) {
  return typeof secret === "string" && /^whsec_[A-Za-z0-9]{16,200}$/.test(secret) && !/[\r\n]/.test(secret);
}
export async function verifyStripeSignature(raw, header, secret, now = Math.floor(Date.now() / 1000)) {
  if (typeof header !== "string" || header.length > 2048 || !validWebhookSecret(secret)) return false;
  const pieces = header.split(",").map((part) => part.trim().split("="));
  const timestamps = pieces.filter(([key]) => key === "t");
  const signatures = pieces.filter(([key, value]) => key === "v1" && /^[0-9a-f]{64}$/.test(value ?? ""));
  if (timestamps.length !== 1 || !/^\d{10,11}$/.test(timestamps[0][1] ?? "") || signatures.length < 1 || signatures.length > 8) return false;
  const stamp = Number(timestamps[0][1]);
  if (!Number.isSafeInteger(stamp) || Math.abs(now - stamp) > 300) return false;
  const prefix = encoder.encode(`${stamp}.`), signed = new Uint8Array(prefix.length + raw.length);
  signed.set(prefix); signed.set(raw, prefix.length);
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
  for (const [, signature] of signatures) {
    if (await crypto.subtle.verify("HMAC", key, fromHex(signature), signed)) return true;
  }
  return false;
}
function decode64(value) {
  need(typeof value === "string" && /^[A-Za-z0-9_-]+$/.test(value), 503, "claim_key_unavailable");
  const text = value.replaceAll("-", "+").replaceAll("_", "/");
  const bytes = Uint8Array.from(atob(text + "=".repeat((4 - text.length % 4) % 4)), (c) => c.charCodeAt(0));
  need(base64url(bytes) === value, 503, "claim_key_unavailable"); return bytes;
}
async function encryptionKey(env) {
  const bytes = decode64(env.CLAIM_ENCRYPTION_KEY);
  need(bytes.length === 32, 503, "claim_key_unavailable");
  try { return await crypto.subtle.importKey("raw", bytes, "AES-GCM", false, ["encrypt", "decrypt"]); }
  finally { bytes.fill(0); }
}
export async function sealToken(token, aad, env) {
  const iv = crypto.getRandomValues(new Uint8Array(12)), key = await encryptionKey(env);
  const encrypted = await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: encoder.encode(aad), tagLength: 128 }, key, encoder.encode(token));
  return { version: 1, keyId: env.CLAIM_KEY_ID, iv: base64url(iv), ciphertext: base64url(encrypted) };
}
export async function openToken(sealed, aad, env) {
  need(sealed?.version === 1 && sealed.keyId === env.CLAIM_KEY_ID, 503, "claim_key_unavailable");
  const iv = decode64(sealed.iv), ciphertext = decode64(sealed.ciphertext);
  need(iv.length === 12 && ciphertext.length === 59, 503, "claim_key_unavailable");
  const key = await encryptionKey(env);
  try {
    const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv, additionalData: encoder.encode(aad), tagLength: 128 }, key, ciphertext);
    const token = new TextDecoder("utf-8", { fatal: true }).decode(plain);
    need(TOKEN.test(token), 503, "claim_key_unavailable"); return token;
  } catch { throw new Refusal(503, "claim_key_unavailable"); }
}
export function randomToken() { return base64url(crypto.getRandomValues(new Uint8Array(32))); }
export function config(env) {
  need(identifier(env.STRIPE_ACCOUNT_ID, "acct") && ["test", "live"].includes(env.STRIPE_MODE) &&
    identifier(env.STRIPE_PRICE_ID, "price") && identifier(env.STRIPE_PRODUCT_ID, "prod") &&
    /^[a-z]{3}$/.test(env.STRIPE_CURRENCY ?? "") && /^[1-9][0-9]{0,7}$/.test(env.STRIPE_UNIT_AMOUNT ?? "") &&
    /^[a-f0-9]{64}$/.test(env.EXPECTED_PUBLIC_KEY_HEX ?? "") && /^[A-Za-z0-9-]{1,40}$/.test(env.CLAIM_KEY_ID ?? ""),
    503, "configuration_unavailable");
  let origin, download, cancel;
  try { origin = new URL(env.PUBLIC_ORIGIN); download = new URL(env.DOWNLOAD_URL); cancel = new URL(env.CANCEL_URL); }
  catch { throw new Refusal(503, "configuration_unavailable"); }
  need(origin.protocol === "https:" && origin.origin === env.PUBLIC_ORIGIN &&
    download.protocol === "https:" && !download.username && !download.password &&
    cancel.protocol === "https:" && !cancel.username && !cancel.password && cancel.origin === origin.origin &&
    cancel.pathname === "/" && !cancel.hash &&
    (!cancel.search || (cancel.searchParams.size === 1 && cancel.searchParams.get("cancelled") === "1")), 503, "configuration_unavailable");
  const scope = {
    schema: 2, provider: "stripe", apiVersion: API_VERSION, accountId: env.STRIPE_ACCOUNT_ID,
    mode: env.STRIPE_MODE, productId: env.STRIPE_PRODUCT_ID, priceId: env.STRIPE_PRICE_ID,
    currency: env.STRIPE_CURRENCY, unitAmount: Number(env.STRIPE_UNIT_AMOUNT), taxBehavior: "inclusive",
    publicKey: env.EXPECTED_PUBLIC_KEY_HEX, origin: origin.origin,
  };
  return { ...scope, scope: JSON.stringify(scope), download: download.href, cancel: cancel.href, live: env.STRIPE_MODE === "live" };
}
export function aadFor(cfg, orderRef) { return `${cfg.scope}\n${orderRef}`; }
