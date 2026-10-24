import { API_VERSION, boundedBody, identifier, need, parseJSON, Refusal } from "./stripe-security.mjs";

// Only this adapter has API-key access. No arbitrary URL, Connect account header,
// redirects, automatic POST retries, provider error text or unbounded body reads.
export function stripeClient(env, transport = (url, options) => globalThis.fetch(url, options)) {
  need(typeof env.STRIPE_API_KEY === "string" && /^(?:sk|rk)_(?:test|live)_[A-Za-z0-9]{16,200}$/.test(env.STRIPE_API_KEY), 503, "stripe_unavailable");
  need(env.STRIPE_API_KEY.includes(`_${env.STRIPE_MODE}_`), 503, "stripe_mode_mismatch");
  async function call(path, { form, idempotencyKey } = {}) {
    const abort = new AbortController(), timer = setTimeout(() => abort.abort(), 8000);
    try {
      const result = await transport(`https://api.stripe.com/v1/${path}`, {
        // Workers supports manual/follow, not the Fetch standard's error mode.
        // Returning 3xx to this adapter lets the !ok check reject all redirects.
        method: form ? "POST" : "GET", redirect: "manual", signal: abort.signal,
        headers: { Authorization: `Bearer ${env.STRIPE_API_KEY}`, "Stripe-Version": API_VERSION,
          ...(form ? { "Content-Type": "application/x-www-form-urlencoded", "Idempotency-Key": idempotencyKey } : {}) },
        ...(form ? { body: new URLSearchParams(form) } : {}),
      });
      if (!result.ok) { await result.body?.cancel(); throw new Refusal(503, "stripe_unavailable"); }
      need(/^application\/json(?:\s*;|$)/i.test(result.headers.get("Content-Type") ?? ""), 503, "stripe_unavailable");
      return parseJSON(await boundedBody(result, 256 * 1024));
    } catch { throw new Refusal(503, "stripe_unavailable"); }
    finally { clearTimeout(timer); }
  }
  function exact(value, prefix) { need(identifier(value, prefix), 400, "invalid_provider_id"); return value; }
  return {
    account: () => call("account"),
    price: (id) => call(`prices/${exact(id, "price")}`),
    session: (id) => call(`checkout/sessions/${exact(id, "cs")}`),
    lineItems: (id) => call(`checkout/sessions/${exact(id, "cs")}/line_items?limit=2`),
    paymentIntent: (id) => call(`payment_intents/${exact(id, "pi")}`),
    charge: (id) => call(`charges/${exact(id, "ch")}`),
    refund: (id) => call(`refunds/${exact(id, "re")}`),
    refunds: (id) => call(`refunds?charge=${exact(id, "ch")}&limit=1`),
    sessionsForPayment: (id) => call(`checkout/sessions?payment_intent=${exact(id, "pi")}&limit=2`),
    createCheckout: (form, key) => {
      need(/^[a-zA-Z0-9:_-]{1,200}$/.test(key), 400, "invalid_idempotency_key");
      return call("checkout/sessions", { form, idempotencyKey: key });
    },
  };
}
