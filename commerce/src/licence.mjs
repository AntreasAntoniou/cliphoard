// Wire format matches the direct edition's Licence.swift. Never import a private
// key with format "raw": Workers supports Ed25519 PKCS#8 private-key import.
const encoder = new TextEncoder();
const pkcs8SeedPrefix = Uint8Array.from([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30,
  0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20]);

export function base64url(bytes) {
  return btoa(String.fromCharCode(...new Uint8Array(bytes)))
    .replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

export function fromHex(value) {
  if (typeof value !== "string" || !/^(?:[0-9a-f]{2})+$/i.test(value)) throw new Error("hex");
  return Uint8Array.from(value.match(/../g), (pair) => Number.parseInt(pair, 16));
}

export function payloadFor(order) {
  // JSON serialization, never string interpolation of untrusted fields.
  return encoder.encode(JSON.stringify({
    o: `ls:${order.mode}:${order.storeId}:${order.orderId}`,
    i: order.issued,
    p: "pro",
    v: 1,
  }));
}

export async function signLicence(order, seedBase64, publicHex) {
  if (typeof seedBase64 !== "string" || !/^[A-Za-z0-9+/]{43}=$/.test(seedBase64)) {
    throw new Error("signer configuration");
  }
  const seed = Uint8Array.from(atob(seedBase64), (c) => c.charCodeAt(0));
  if (seed.length !== 32 || btoa(String.fromCharCode(...seed)) !== seedBase64) {
    throw new Error("signer configuration");
  }
  const der = new Uint8Array(pkcs8SeedPrefix.length + seed.length);
  der.set(pkcs8SeedPrefix); der.set(seed, pkcs8SeedPrefix.length);
  let key;
  try {
    key = await crypto.subtle.importKey("pkcs8", der, "Ed25519", false, ["sign"]);
  } finally {
    seed.fill(0); der.fill(0);
  }
  const payload = payloadFor(order);
  const signature = await crypto.subtle.sign("Ed25519", key, payload);
  const result = `CLIP1-${base64url(payload)}.${base64url(signature)}`;
  // Fail before storing if the secret does not match the approved public key.
  if (!await verifyLicence(result, order, publicHex)) throw new Error("signer mismatch");
  return result;
}

export async function verifyLicence(value, order, publicHex) {
  if (typeof value !== "string" || value.length > 1024) return false;
  const match = /^CLIP1-([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)$/.exec(value);
  if (!match || match[1] !== base64url(payloadFor(order))) return false;
  try {
    const encoded = match[2].replaceAll("-", "+").replaceAll("_", "/");
    const signature = Uint8Array.from(atob(encoded + "=".repeat((4 - encoded.length % 4) % 4)),
      (c) => c.charCodeAt(0));
    if (signature.length !== 64 || base64url(signature) !== match[2]) return false;
    const key = await crypto.subtle.importKey("raw", fromHex(publicHex), "Ed25519", false, ["verify"]);
    return await crypto.subtle.verify("Ed25519", key, signature, payloadFor(order));
  } catch { return false; }
}

export async function verifyWebhook(raw, signature, secret) {
  if (typeof signature !== "string" || !/^[a-f0-9]{64}$/i.test(signature)) return false;
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
  // The crypto implementation compares the MAC; no manual early-exit comparison.
  return crypto.subtle.verify("HMAC", key, fromHex(signature), raw);
}

export async function sha256(value) {
  const bytes = new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(value)));
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}
