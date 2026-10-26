import { validSiteEvent, SOURCES } from "../docs/assets/telemetry.mjs";

export const COMMERCE_EVENTS = new Set([
  "checkout_created", "licence_issued", "payment_blocked", "claim_ready",
  "email_attempt", "email_accepted", "email_failed", "email_exhausted", "email_retry_queued",
  "request_ok", "request_rejected", "request_error",
]);
const ROUTES = new Set(["frontdoor", "checkout", "webhook", "claim", "other", "order"]);

// Fixed vocabulary only. Never accept an order object, URL, error message, or identity.
// Best effort: an analytics outage must not change a payment, licence or email result.
export function recordMetric(env, { surface, mode, event, placement, source = "none", country = "ZZ" }) {
  if (!["website", "commerce"].includes(surface) || !["live", "test", "qa"].includes(mode) ||
      !SOURCES.includes(source) || !/^[A-Z]{2}$/.test(country) ||
      !(surface === "website" ? validSiteEvent(event, placement) : COMMERCE_EVENTS.has(event) && ROUTES.has(placement))) return false;
  try {
    if (typeof env.METRICS?.writeDataPoint !== "function") return false;
    env.METRICS.writeDataPoint({ indexes: [`${surface}:${mode}`],
      blobs: ["v1", surface, mode, event, placement, source, country], doubles: [1] });
    return true;
  } catch { return false; }
}
export function commerceMetric(env, event, placement = "order") {
  return recordMetric(env, { surface: "commerce", mode: env.STRIPE_MODE, event, placement });
}
