import { createHmac, randomUUID } from "node:crypto";

export class MemoryKV {
  values = new Map(); writes = 0; failRead = false; failWrite = false; staleMiss = false;
  async get(key) {
    if (this.failRead) throw new Error("synthetic read failure");
    if (this.staleMiss) return null;
    return this.values.get(key) ?? null;
  }
  async put(key, value) {
    if (this.failWrite) throw new Error("synthetic write failure");
    this.writes++; this.values.set(key, value);
  }
}

export async function syntheticKeys() {
  const pair = await crypto.subtle.generateKey("Ed25519", true, ["sign", "verify"]);
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const pub = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  return { seed: Buffer.from(der.slice(-32)).toString("base64"),
    publicHex: Buffer.from(pub).toString("hex") };
}

export async function environment() {
  const keys = await syntheticKeys();
  return {
    LEMON_MODE: "test", LEMON_STORE_ID: "123", LEMON_PRODUCT_ID: "456", LEMON_VARIANT_ID: "789",
    PUBLIC_ORIGIN: "https://fulfilment.example", DOWNLOAD_URL: "https://download.example/Cliphoard.dmg",
    ISSUANCE_ENABLED: "true", DELIVERY_ENABLED: "true",
    EXPECTED_PUBLIC_KEY_HEX: keys.publicHex, CLIPHOARD_SIGNING_SEED: keys.seed,
    LEMON_WEBHOOK_SECRET: "synthetic-test-webhook-secret", RECEIPTS: new MemoryKV(),
  };
}

export function order(event = "order_created") {
  return {
    meta: { event_name: event, test_mode: true },
    data: { type: "orders", id: "1001", attributes: {
      store_id: 123, identifier: randomUUID(), test_mode: true,
      status: "paid", refunded: false, refunded_at: null, refunded_amount: 0,
      currency: "USD", total: 1000, created_at: "2026-01-02T03:04:05.000000Z",
      user_name: "Synthetic Buyer", user_email: "synthetic-buyer@example.invalid",
      first_order_item: { id: 987, order_id: 1001, product_id: 456, variant_id: 789, test_mode: true },
    } },
  };
}

export function request(env, payload, options = {}) {
  const body = options.raw ?? JSON.stringify(payload);
  const signature = options.signature ?? createHmac("sha256", env.LEMON_WEBHOOK_SECRET).update(body).digest("hex");
  return new Request(env.PUBLIC_ORIGIN + "/webhooks/lemon", {
    method: "POST", body,
    headers: { "Content-Type": "application/json", "X-Signature": signature,
      "X-Event-Name": payload.meta.event_name, ...options.headers },
  });
}

export function receipt(env, payload, query = null) {
  return new Request(env.PUBLIC_ORIGIN + "/pro/claim?" +
    (query ?? `order=${payload.data.attributes.identifier}`));
}

export function licenseFrom(html) { return /CLIP1-[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/.exec(html)?.[0]; }
