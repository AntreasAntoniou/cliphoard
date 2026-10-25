import { randomUUID, randomBytes, createHmac } from "node:crypto";
import { syntheticKeys } from "./fixtures.mjs";
import { API_VERSION } from "../src/stripe-security.mjs";
import { orderService } from "../src/stripe-order.mjs";
export class Storage {
  data = new Map(); writes = 0; failPut = false;
  async get(key) { return structuredClone(this.data.get(key)); }
  async put(key, value) {
    if (this.failPut) throw new Error("synthetic storage failure");
    this.writes++; this.data.set(key, structuredClone(value));
  }
}
export async function fixture() {
  const keys = await syntheticKeys(), sent = [], alarms = [], storage = new Storage();
  const env = {
    STRIPE_ACCOUNT_ID: "acct_TestAccount", STRIPE_MODE: "test", STRIPE_PRODUCT_ID: "prod_Cliphoard",
    STRIPE_PRICE_ID: "price_Pro", STRIPE_CURRENCY: "gbp", STRIPE_UNIT_AMOUNT: "1000",
    PUBLIC_ORIGIN: "https://purchase.example", CANCEL_URL: "https://purchase.example/?cancelled=1",
    DOWNLOAD_URL: "https://download.example/cliphoard.dmg", CHECKOUT_ENABLED: "true",
    ISSUANCE_ENABLED: "true", DELIVERY_ENABLED: "true", EMAIL_DELIVERY_ENABLED: "true",
    EXPECTED_PUBLIC_KEY_HEX: keys.publicHex, CLIPHOARD_SIGNING_SEED: keys.seed,
    CLAIM_ENCRYPTION_KEY: randomBytes(32).toString("base64url"), CLAIM_KEY_ID: "claim-v1",
    STRIPE_WEBHOOK_SECRET: "whsec_syntheticSecret012345678901", EMAIL_FROM: "support@example.invalid",
    EMAIL: { send: async (message) => { sent.push(message); return { messageId: `synthetic-${sent.length}` }; } },
    CHECKOUT_RATE_LIMITER: { limit: async () => ({ success: true }) },
  };
  const stripe = new FakeStripe(env), ref = randomUUID();
  let clock = Math.floor(Date.now() / 1000);
  const service = () => orderService({ env, storage, stripe, schedule: async (s) => alarms.push(s), now: () => clock });
  return { env, storage, stripe, ref, sent, alarms, service, now: () => clock, advance: (s) => { clock += s; },
    token: () => new URL(stripe.s.success_url).searchParams.get("token"), keys };
}
export class FakeStripe {
  constructor(env) {
    this.env = env; this.calls = []; this.creates = 0; this.s = null; this.refundRows = [];
    this.a = { object: "account", id: env.STRIPE_ACCOUNT_ID, charges_enabled: true, details_submitted: true };
    this.p = { object: "price", id: env.STRIPE_PRICE_ID, product: env.STRIPE_PRODUCT_ID, livemode: false,
      type: "one_time", recurring: null, currency: "gbp", unit_amount: 1000, billing_scheme: "per_unit",
      tax_behavior: "inclusive", custom_unit_amount: null, transform_quantity: null, active: true };
  }
  async account() { this.calls.push("account"); return structuredClone(this.a); }
  async price() { return structuredClone(this.p); }
  async createCheckout(form, key) {
    this.calls.push("createCheckout"); this.creates++;
    if (this.s) { if (key !== this.key || JSON.stringify(form) !== JSON.stringify(this.form)) throw new Error("idempotency conflict"); return structuredClone(this.s); }
    this.key = key; this.form = form;
    this.s = { object: "checkout.session", id: "cs_test_Session1", livemode: false, mode: "payment", ui_mode: "hosted_page",
      managed_payments: { enabled: true }, metadata: { cliphoard_order: form.client_reference_id, fulfilment: "cliphoard-stripe-v1" },
      client_reference_id: form.client_reference_id, payment_link: null, subscription: null, recovered_from: null,
      created: Number(form.expires_at) - 3600, currency: "gbp", status: "open", payment_status: "unpaid", payment_intent: null,
      success_url: form.success_url, cancel_url: form.cancel_url, amount_subtotal: 1000, amount_total: 1000,
      total_details: { amount_discount: 0, amount_shipping: 0, amount_tax: 167 },
      url: "https://checkout.stripe.com/c/pay/cs_test_Session1", customer_details: { email: "synthetic-buyer@example.invalid" } };
    this.items = { object: "list", has_more: false, data: [{ object: "item", id: "li_Test1", price: structuredClone(this.p),
      quantity: 1, currency: "gbp", amount_subtotal: 1000, amount_total: 1000, amount_discount: 0, amount_tax: 167 }] };
    return structuredClone(this.s);
  }
  pay() {
    this.s.status = "complete"; this.s.payment_status = "paid"; this.s.payment_intent = "pi_Payment1";
    this.pi = { object: "payment_intent", id: "pi_Payment1", livemode: false, managed_payments: { enabled: true },
      metadata: structuredClone(this.s.metadata), currency: "gbp", amount: 1000, amount_received: 1000,
      status: "succeeded", latest_charge: "ch_Charge1" };
    this.ch = { object: "charge", id: "ch_Charge1", livemode: false, payment_intent: "pi_Payment1", currency: "gbp",
      status: "succeeded", paid: true, captured: true, amount: 1000, amount_captured: 1000,
      amount_refunded: 0, refunded: false, disputed: false };
  }
  async session(id) { this.calls.push("session"); if (id !== this.s?.id) throw new Error("missing session"); return structuredClone(this.s); }
  async lineItems() { return structuredClone(this.items); }
  async paymentIntent() { return structuredClone(this.pi); }
  async charge() { return structuredClone(this.ch); }
  async refunds() { return { object: "list", has_more: false, data: structuredClone(this.refundRows) }; }
  async refund() { return { object: "refund", id: "re_Refund1", payment_intent: "pi_Payment1", status: "pending", amount: 50 }; }
  async sessionsForPayment() { return { object: "list", has_more: false, data: [structuredClone(this.s)] }; }
}
export function event(f, type = "checkout.session.completed") {
  return { id: "evt_Event1", object: "event", api_version: API_VERSION, livemode: false, type,
    data: { object: type.startsWith("checkout.") ? { object: "checkout.session", id: f.stripe.s.id }
      : type === "charge.refunded" ? { object: "charge", id: "ch_Charge1" } : { object: "refund", id: "re_Refund1" } } };
}
export function webhookRequest(f, payload, { raw = JSON.stringify(payload), stamp = Math.floor(Date.now() / 1000), signature } = {}) {
  const mac = createHmac("sha256", f.env.STRIPE_WEBHOOK_SECRET).update(`${stamp}.${raw}`).digest("hex");
  return new Request(`${f.env.PUBLIC_ORIGIN}/webhooks/stripe`, { method: "POST", body: raw,
    headers: { "Content-Type": "application/json", "Stripe-Signature": signature ?? `t=${stamp},v1=${mac}` } });
}
export function wireOrders(f) {
  let tail = Promise.resolve();
  f.env.STRIPE_ORDERS = {
    idFromName: (name) => name,
    get: () => ({ fetch: (req) => {
      const result = tail.then(async () => {
        const data = await req.json(), service = f.service();
        try {
          let r;
          if (data.action === "start") r = await service.start(data.orderRef);
          else if (data.action === "claim") r = await service.claim(data.orderRef, data.token);
          else r = await service[data.action](data.orderRef, data.sessionId);
          return new Response(JSON.stringify(r), { status: 200, headers: { "Content-Type": "application/json" } });
        } catch (e) { return new Response(JSON.stringify({ result: e.code ?? "service_unavailable" }), { status: e.status ?? 503 }); }
      }); tail = result.catch(() => {}); return result;
    } }),
  };
}
