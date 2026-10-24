// Local-only test entrypoint. No deployed configuration imports this file.
import worker, { StripeOrder } from "../src/stripe-worker.mjs";
function withEmail(env) {
  return { ...env, EMAIL: { send: async (message) => {
    const result = await env.TEST_EMAIL.fetch("https://email.test/", {
      method: "POST", body: JSON.stringify(message), headers: { "Content-Type": "application/json" },
    });
    return result.json();
  } } };
}
export class TestStripeOrder extends StripeOrder {
  constructor(ctx, env) {
    super(ctx, withEmail(env));
  }
}
export default {
  fetch(request, env) {
    return worker.fetch(request, { ...withEmail(env), CHECKOUT_RATE_LIMITER: { limit: async () => ({ success: true }) } });
  },
};
