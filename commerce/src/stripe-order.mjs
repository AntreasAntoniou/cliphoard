import { signLicence, verifyLicence, sha256 } from "./licence.mjs";
import { aadFor, config, identifier, integer, need, objectId, openToken, ORDER_REF, randomToken, sealToken, TOKEN, validWebhookSecret } from "./stripe-security.mjs";

const MARKER = "cliphoard-stripe-v1";
const MAX_MAIL_ATTEMPTS = 12;
export function deliveryConfigured(env) {
  return env.EMAIL_DELIVERY_ENABLED === "true" && typeof env.EMAIL?.send === "function" &&
    typeof env.EMAIL_FROM === "string" && /^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9.-]+$/.test(env.EMAIL_FROM);
}
export async function nativeDelivery(env, { email, licence, claimUrl }) {
  need(deliveryConfigured(env), 503, "email_delivery_unavailable");
  need(typeof email === "string" && email.length <= 254 && /^[^\s@<>\r\n]+@[^\s@<>\r\n]+\.[^\s@<>\r\n]+$/.test(email), 503, "recipient_unavailable");
  // Native API acceptance is not inbox delivery and has no idempotency contract.
  // After an ambiguous crash a retry can send the SAME key and recovery link again.
  let result;
  try {
    result = await env.EMAIL.send({
      from: env.EMAIL_FROM, to: email, replyTo: env.EMAIL_FROM,
      subject: "Your Cliphoard Pro key",
      text: `Thanks for supporting Cliphoard. Your direct-download Pro key is ready.\n\nYour licence key:\n${licence}\n\nActivate Cliphoard Pro:\n1. Copy the entire key above, including the CLIP1- prefix.\n2. Open the direct-download Cliphoard app and go to Settings → Pro.\n3. Paste your key and choose Verify.\n\nYour key works on every Mac you own. The Mac App Store edition uses its separate App Store purchase.\n\nKeep this email and key private. You can also retrieve the same key using your private recovery link:\n${claimUrl}\n\nFor product help, reply to this email. Your payment receipt comes separately from Link.`,
    });
  } catch { need(false, 503, "email_unavailable"); }
  need(result && typeof result.messageId === "string" && result.messageId.length > 0 && result.messageId.length < 256, 503, "email_not_accepted");
  // Do not persist arbitrary provider strings. A digest is enough for correlation.
  return { acceptanceHash: await sha256(result.messageId) };
}
function validatePrice(price, cfg, active = false) {
  need(price?.object === "price" && price.id === cfg.priceId && objectId(price.product) === cfg.productId &&
    price.livemode === cfg.live && price.type === "one_time" && price.recurring === null &&
    price.currency === cfg.currency && price.unit_amount === cfg.unitAmount && price.billing_scheme === "per_unit" &&
    price.tax_behavior === cfg.taxBehavior && price.custom_unit_amount === null && price.transform_quantity === null &&
    (!active || price.active === true), 409, "unconfigured_price");
}
export async function verifyAccount(stripe, cfg, forCheckout = false) {
  const account = await stripe.account();
  need(account?.object === "account" && account.id === cfg.accountId, 403, "account_mismatch");
  if (forCheckout) need(account.charges_enabled === true && account.details_submitted === true, 503, "account_not_ready");
}
function validateSession(session, record, cfg) {
  need(session?.object === "checkout.session" && identifier(session.id, "cs") && session.livemode === cfg.live &&
    session.mode === "payment" && session.ui_mode === "hosted_page" && session.managed_payments?.enabled === true &&
    session.payment_link === null && session.subscription === null && session.recovered_from === null &&
    session.client_reference_id === record.orderRef && session.metadata?.cliphoard_order === record.orderRef &&
    session.metadata?.fulfilment === MARKER && session.currency === cfg.currency &&
    integer(session.created) && session.created >= record.created - 5 && session.created <= record.created + 1800 &&
    (!record.sessionId || record.sessionId === session.id), 409, "session_mismatch");
}
async function itemsFor(stripe, session, cfg) {
  const items = await stripe.lineItems(session.id);
  need(items?.object === "list" && items.has_more === false && Array.isArray(items.data) && items.data.length === 1,
    409, "unsupported_line_items");
  const item = items.data[0]; validatePrice(item.price, cfg);
  // With an inclusive price and no discounts, Stripe's subtotal already
  // contains the tax component. Adding amount_tax would count it twice.
  need(item.quantity === 1 && item.currency === cfg.currency && item.amount_subtotal === cfg.unitAmount &&
    item.amount_discount === 0 && integer(item.amount_tax) && item.amount_tax <= cfg.unitAmount &&
    item.amount_total === cfg.unitAmount &&
    session.amount_subtotal === item.amount_subtotal && session.amount_total === item.amount_total &&
    session.total_details?.amount_discount === 0 && session.total_details?.amount_shipping === 0 &&
    session.total_details?.amount_tax === item.amount_tax, 409, "amount_or_quantity_mismatch");
}
export function orderService({ env, storage, stripe, schedule = async () => {}, now = () => Math.floor(Date.now() / 1000), deliver, deviceAuthority, deviceFulfilment }) {
  const cfg = config(env);
  let deviceReadiness;
  if (deviceFulfilment !== undefined) {
    need(deviceFulfilment && Object.getPrototypeOf(deviceFulfilment) === Object.prototype, 503, "device_fulfilment_configuration");
    const d = Object.getOwnPropertyDescriptors(deviceFulfilment);
    need(Reflect.ownKeys(d).every(k => typeof k === "string" && "value" in d[k]) &&
      [true, false].includes(d.enabled?.value), 503, "device_fulfilment_configuration");
    if (d.enabled.value) {
      need(Reflect.ownKeys(d).length === 2 && typeof d.readiness?.value === "function", 503, "device_fulfilment_configuration");
      deviceReadiness = d.readiness.value;
    } else need(Reflect.ownKeys(d).length === 1, 503, "device_fulfilment_configuration");
  }
  async function requireDeviceReady() {
    try { need(await deviceReadiness() === true, 503, "device_fulfilment_unavailable"); }
    catch { need(false, 503, "device_fulfilment_unavailable"); }
  }
  // Trusted construction only. No Worker route supplies this opt-in or its IDs.
  let authorityScope;
  if (deviceAuthority !== undefined) {
    need(deviceAuthority && Object.getPrototypeOf(deviceAuthority) === Object.prototype,
      503, "device_authority_configuration");
    const fields = Object.getOwnPropertyDescriptors(deviceAuthority);
    need(Reflect.ownKeys(fields).every(key => typeof key === "string" && "value" in fields[key]) &&
      [true, false].includes(fields.enabled?.value), 503, "device_authority_configuration");
    if (fields.enabled.value === true) {
      need(Reflect.ownKeys(fields).length === 3 && typeof fields.orderRef?.value === "string" && ORDER_REF.test(fields.orderRef.value) &&
        identifier(fields.sessionId?.value, "cs"), 503, "device_authority_configuration");
      authorityScope = Object.freeze({ orderRef: fields.orderRef.value, sessionId: fields.sessionId.value });
    } else need(Reflect.ownKeys(fields).length === 1, 503, "device_authority_configuration");
  }
  const send = deliver ?? ((message) => nativeDelivery(env, message));
  const save = (record) => storage.put("order", record);
  async function load(orderRef, optional = false) {
    const record = await storage.get("order");
    if (!record && optional) return null;
    need(record && record.scope === cfg.scope && record.orderRef === orderRef && ORDER_REF.test(record.orderRef) &&
      integer(record.created) && record.created <= now() + 300 &&
      /^[0-9a-f]{64}$/.test(record.tokenHash ?? "") && typeof record.blocked === "boolean" &&
      (record.sessionId === null || identifier(record.sessionId, "cs")) &&
      (record.issued === null || integer(record.issued)) &&
      (record.licence === null || typeof record.licence === "string") &&
      ["idle", "pending", "accepted", "blocked", "exhausted"].includes(record.mail?.status) &&
      integer(record.mail.attempts) && record.mail.attempts <= MAX_MAIL_ATTEMPTS,
      503, "stored_order_invalid");
    need(record.fulfilment === undefined || record.fulfilment === "device-v1", 503, "stored_order_invalid");
    if (record.fulfilment === "device-v1") {
      // Persisted selection is immutable. An older/default host must never issue
      // a legacy bearer licence when it encounters a device-policy order.
      need(deviceReadiness && record.issued === null && record.licence === null &&
        ["idle", "blocked"].includes(record.mail.status) && record.mail.attempts === 0, 503, "device_fulfilment_unavailable");
    }
    return record;
  }
  async function tokenFor(record) {
    const token = await openToken(record.sealed, aadFor(cfg, record.orderRef), env);
    need(await sha256(token) === record.tokenHash, 503, "claim_key_unavailable"); return token;
  }
  function licenceOrder(record) {
    return { provider: "stripe", mode: cfg.mode, accountId: cfg.accountId, orderId: record.sessionId, issued: record.issued };
  }
  async function block(record) {
    const first = !record.blocked;
    record.blocked = true; record.mail.status = "blocked"; await save(record);
    if (first) commerceMetric(env, "payment_blocked");
    return { result: "payment_blocked" };
  }
  async function inspectCheckout(record, sessionId) {
    await verifyAccount(stripe, cfg);
    const session = await stripe.session(sessionId); validateSession(session, record, cfg);
    await itemsFor(stripe, session, cfg);
    // A success URL must be the exact link minted for this order, not customer input.
    const token = await tokenFor(record), claimUrl = `${cfg.origin}/pro/claim?order=${record.orderRef}&token=${token}`;
    need(session.success_url === claimUrl && session.cancel_url === cfg.cancel, 409, "session_link_mismatch");
    return { session, claimUrl };
  }
  async function inspectPayment(record, session) {
    need(identifier(objectId(session.payment_intent), "pi"), 409, "payment_mismatch");
    const payment = await stripe.paymentIntent(objectId(session.payment_intent));
    need(payment?.object === "payment_intent" && payment.id === objectId(session.payment_intent) &&
      payment.livemode === cfg.live && payment.managed_payments?.enabled === true &&
      payment.metadata?.cliphoard_order === record.orderRef && payment.metadata?.fulfilment === MARKER &&
      payment.currency === cfg.currency && payment.amount === session.amount_total &&
      payment.amount_received === session.amount_total && payment.status === "succeeded" &&
      identifier(objectId(payment.latest_charge), "ch"), 409, "payment_mismatch");
    const charge = await stripe.charge(objectId(payment.latest_charge));
    need(charge?.object === "charge" && charge.id === objectId(payment.latest_charge) && charge.livemode === cfg.live &&
      objectId(charge.payment_intent) === payment.id && charge.currency === cfg.currency && charge.status === "succeeded" &&
      charge.paid === true && charge.captured === true && charge.amount === session.amount_total &&
      charge.amount_captured === session.amount_total && integer(charge.amount_refunded) &&
      typeof charge.refunded === "boolean" && typeof charge.disputed === "boolean", 409, "charge_mismatch");
    const refunds = await stripe.refunds(charge.id);
    need(refunds?.object === "list" && Array.isArray(refunds.data) && typeof refunds.has_more === "boolean", 503, "refund_state_unavailable");
    // Fail closed on any refund attempt, even one still pending or later failed.
    // This conservative tombstone is never undone by a late paid notification.
    if (charge.refunded || charge.amount_refunded > 0 || charge.disputed || refunds.data.length > 0 || refunds.has_more) {
      return false;
    }
    return true;
  }
  async function refresh(record, sessionId = record.sessionId) {
    const { session, claimUrl } = await inspectCheckout(record, sessionId);
    if (!record.sessionId) { record.sessionId = session.id; await save(record); }
    if (record.blocked) return { result: "payment_blocked" };
    if (session.status !== "complete" || session.payment_status !== "paid") return { result: "payment_pending" };
    if (!await inspectPayment(record, session)) return await block(record);
    return { result: "eligible", session, claimUrl };
  }
  async function inspectDeviceAuthority(...args) {
    need(authorityScope, 503, "device_authority_disabled");
    need(args.length === 0, 400, "device_authority_arguments");
    let record;
    try { record = await load(authorityScope.orderRef); }
    catch { need(false, 503, "device_authority_unavailable"); }
    need(record.sessionId === authorityScope.sessionId, 409, "device_authority_scope_mismatch");
    try {
      const { session } = await inspectCheckout(record, authorityScope.sessionId);
      let state = "pending", ownerEmail = null;
      if (record.blocked) state = "blocked";
      else if (session.status === "complete" && session.payment_status === "paid") {
        state = await inspectPayment(record, session) ? "active" : "blocked";
        if (state === "active") {
          ownerEmail = session.customer_details?.email;
          need(typeof ownerEmail === "string" && ownerEmail.length <= 254 &&
            /^[^\s@<>\r\n]+@[^\s@<>\r\n]+\.[^\s@<>\r\n]+$/.test(ownerEmail), 503, "recipient_unavailable");
        }
      }
      return { accountId: cfg.accountId, mode: cfg.mode, orderRef: authorityScope.orderRef,
        sessionId: authorityScope.sessionId, productId: cfg.productId, priceId: cfg.priceId,
        currency: cfg.currency, unitAmount: cfg.unitAmount, taxBehavior: cfg.taxBehavior, state, ownerEmail };
    } catch { need(false, 503, "device_authority_unavailable"); }
  }
  async function start(orderRef) {
    need(ORDER_REF.test(orderRef), 400, "invalid_order_reference");
    need(env.CHECKOUT_ENABLED === "true" && env.ISSUANCE_ENABLED === "true" && env.DELIVERY_ENABLED === "true" && deliveryConfigured(env),
      503, "checkout_paused");
    need(validWebhookSecret(env.STRIPE_WEBHOOK_SECRET), 503, "webhook_unavailable");
    await verifyAccount(stripe, cfg, true); validatePrice(await stripe.price(cfg.priceId), cfg, true);
    let record = await load(orderRef, true);
    if ((!record && deviceReadiness) || record?.fulfilment === "device-v1") await requireDeviceReady();
    if (!record) {
      const token = randomToken();
      record = { scope: cfg.scope, orderRef, created: now(), tokenHash: await sha256(token),
        sealed: await sealToken(token, aadFor(cfg, orderRef), env), sessionId: null, issued: null,
        licence: null, blocked: false, mail: { status: "idle", attempts: 0 } };
      if (deviceReadiness) record.fulfilment = "device-v1";
      await save(record);
    }
    need(!record.blocked, 409, "payment_blocked");
    const token = await tokenFor(record);
    // Also check signer BEFORE accepting payment, using an unpersisted probe.
    if (record.fulfilment !== "device-v1")
      await signLicence({ provider: "stripe", mode: cfg.mode, accountId: cfg.accountId, orderId: "probe", issued: record.created },
        env.CLIPHOARD_SIGNING_SEED, cfg.publicKey);
    const firstSession = !record.sessionId;
    let session;
    if (record.sessionId) session = await stripe.session(record.sessionId);
    else {
      // Stripe retains idempotency for at least 24h. Never replay an uncertain
      // create after 30min, nor extend its original fixed one-hour expiration.
      need(now() < record.created + 1800, 409, "checkout_create_needs_reconciliation");
      const form = {
        mode: "payment", ui_mode: "hosted_page", currency: cfg.currency, "managed_payments[enabled]": "true",
        "line_items[0][price]": cfg.priceId, "line_items[0][quantity]": "1",
        client_reference_id: orderRef, "metadata[cliphoard_order]": orderRef, "metadata[fulfilment]": MARKER,
        "payment_intent_data[metadata][cliphoard_order]": orderRef, "payment_intent_data[metadata][fulfilment]": MARKER,
        success_url: `${cfg.origin}/pro/claim?order=${orderRef}&token=${token}`, cancel_url: cfg.cancel,
        expires_at: String(record.created + 3600), allow_promotion_codes: "false",
      };
      session = await stripe.createCheckout(form, `cliphoard:${cfg.mode}:${orderRef}`);
    }
    validateSession(session, record, cfg);
    need(session.success_url === `${cfg.origin}/pro/claim?order=${orderRef}&token=${token}` &&
      session.cancel_url === cfg.cancel, 409, "session_link_mismatch");
    record.sessionId = session.id; await save(record);
    need(session.status === "open" && session.payment_status === "unpaid", 409, "checkout_not_open");
    let url; try { url = new URL(session.url); } catch { need(false, 503, "checkout_url_invalid"); }
    need(url.protocol === "https:" && url.hostname === "checkout.stripe.com" && !url.username && !url.password &&
      url.port === "", 503, "checkout_url_invalid");
    if (firstSession) commerceMetric(env, "checkout_created");
    return { result: "checkout_ready", url: url.href };
  }
  async function paid(orderRef, sessionId) {
    const record = await load(orderRef);
    if (record.blocked) return { result: "payment_blocked" };
    const current = await refresh(record, sessionId);
    if (current.result !== "eligible") return { result: current.result };
    if (record.fulfilment === "device-v1") {
      need(env.ISSUANCE_ENABLED === "true", 503, "issuance_paused");
      return { result: "device_pending" };
    }
    if (!record.licence) {
      need(env.ISSUANCE_ENABLED === "true", 503, "issuance_paused");
      record.issued = current.session.created;
      record.licence = await signLicence(licenceOrder(record), env.CLIPHOARD_SIGNING_SEED, cfg.publicKey);
      record.mail.status = "pending"; await save(record);
      commerceMetric(env, "licence_issued");
    } else {
      need(record.issued === current.session.created && await verifyLicence(record.licence, licenceOrder(record), cfg.publicKey),
        503, "stored_licence_invalid");
    }
    if (record.mail.status === "pending") await schedule(now() + 1);
    return { result: "issued" };
  }
  async function refund(orderRef, sessionId) {
    const record = await load(orderRef);
    // The outer authenticated handler has retrieved this refund/charge and its
    // exact session. Revalidate its ownership before applying the tombstone.
    const session = await stripe.session(sessionId); validateSession(session, record, cfg);
    await itemsFor(stripe, session, cfg); return await block(record);
  }
  async function claim(orderRef, token) {
    need(TOKEN.test(token ?? ""), 404, "claim_unavailable");
    const record = await load(orderRef);
    need(await sha256(token) === record.tokenHash, 404, "claim_unavailable");
    need(env.DELIVERY_ENABLED === "true", 503, "delivery_paused");
    if (record.blocked) return { result: "payment_blocked" };
    if (record.fulfilment === "device-v1") {
      if (!record.sessionId) return { result: "payment_pending" };
      const current = await refresh(record);
      return { result: current.result === "eligible" ? "device_pending" : current.result };
    }
    if (!record.licence || !record.sessionId) return { result: "payment_pending" };
    const current = await refresh(record);
    if (current.result !== "eligible") return { result: current.result };
    need(record.issued === current.session.created && await verifyLicence(record.licence, licenceOrder(record), cfg.publicKey),
      503, "stored_licence_invalid");
    commerceMetric(env, "claim_ready");
    return { result: "ready", licence: record.licence, download: cfg.download };
  }
  async function drain() {
    const stored = await storage.get("order"); if (!stored) return { result: "idle" };
    const record = await load(stored.orderRef);
    if (record.blocked || record.mail.status !== "pending") return { result: record.mail.status };
    need(deliveryConfigured(env) && env.DELIVERY_ENABLED === "true", 503, "delivery_paused");
    if (record.mail.attempts >= MAX_MAIL_ATTEMPTS) {
      record.mail.status = "exhausted"; await save(record);
      commerceMetric(env, "email_exhausted"); return { result: "exhausted" };
    }
    record.mail.attempts++; await save(record);
    // Arm before network: a crash after send/acceptance still has a recovery run.
    await schedule(now() + Math.min(60 * 2 ** record.mail.attempts, 21600));
    const current = await refresh(record);
    if (current.result !== "eligible") return { result: current.result };
    need(await verifyLicence(record.licence, licenceOrder(record), cfg.publicKey), 503, "stored_licence_invalid");
    commerceMetric(env, "email_attempt");
    let acceptance;
    try {
      acceptance = await send({ email: current.session.customer_details?.email, licence: record.licence, claimUrl: current.claimUrl });
      need(/^[0-9a-f]{64}$/.test(acceptance?.acceptanceHash ?? ""), 503, "email_not_accepted");
    } catch (error) { commerceMetric(env, "email_failed"); throw error; }
    record.mail = { status: "accepted", attempts: record.mail.attempts, acceptanceHash: acceptance.acceptanceHash };
    await save(record); commerceMetric(env, "email_accepted"); return { result: "email_accepted" };
  }
  async function retryDelivery(orderRef) {
    // This is a private Durable Object action for an authenticated operator.
    // No public route accepts it, an email address or a replacement claim token.
    const record = await load(orderRef);
    need(deliveryConfigured(env) && env.DELIVERY_ENABLED === "true", 503, "delivery_paused");
    if (record.blocked) return { result: "payment_blocked" };
    need(record.licence && record.sessionId, 409, "licence_not_issued");
    const current = await refresh(record);
    if (current.result !== "eligible") return { result: current.result };
    need(record.issued === current.session.created && await verifyLicence(record.licence, licenceOrder(record), cfg.publicKey),
      503, "stored_licence_invalid");
    record.mail = { status: "pending", attempts: 0 }; await save(record); await schedule(now() + 1);
    commerceMetric(env, "email_retry_queued");
    return { result: "email_queued" };
  }
  return { start, paid, refund, claim, drain, retryDelivery, inspectDeviceAuthority };
}
import { commerceMetric } from "../../telemetry/metrics.mjs";
