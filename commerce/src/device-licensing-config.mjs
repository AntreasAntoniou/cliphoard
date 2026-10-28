// Explicit bounded owned-qualification configuration; never production defaults.
import { config, ORDER_REF, validWebhookSecret } from './stripe-security.mjs';
import { decode, base64url, digest } from '../licensing-prototype/protocol.mjs';
import { reconstructHostKeyCapabilities } from '../licensing-prototype/host-key-consumer.mjs';
import { createDeviceBootstrapAdmission } from '../licensing-prototype/bootstrap-admission.mjs';
import { stripeClient } from './stripe-client.mjs';
export const reject = () => { throw Error('device_configuration_unavailable'); };
export const requireValue = value => { if (!value) reject(); };
export function exact(value, names) {
  requireValue(value && [Object.prototype, null].includes(Object.getPrototypeOf(value)));
  const d = Object.getOwnPropertyDescriptors(value);
  requireValue(Reflect.ownKeys(d).length === names.length && names.every(n => d[n] && Object.hasOwn(d[n], 'value')));
  return Object.freeze(Object.fromEntries(names.map(n => [n, d[n].value])));
}
export function captureRPC(value, names) {
  let dispose;
  try {
    requireValue(value && typeof value === 'object'); const d = Object.getOwnPropertyDescriptors(value);
    if (d[Symbol.dispose]) { requireValue(Object.hasOwn(d[Symbol.dispose], 'value') && typeof d[Symbol.dispose].value === 'function'); dispose = d[Symbol.dispose].value; }
    requireValue(Reflect.ownKeys(d).every(n => names.includes(n) || n === Symbol.dispose)
      && names.every(n => d[n] && Object.hasOwn(d[n], 'value')));
    return Object.freeze(Object.fromEntries(names.map(n => [n, d[n].value])));
  } finally { if (dispose) Reflect.apply(dispose, value, []); }
}
function canonicalJSON(value, maximum) {
  requireValue(typeof value === 'string' && value.length > 0 && value.length <= maximum);
  const parsed = JSON.parse(value); requireValue(JSON.stringify(parsed) === value); return parsed;
}
const operationalNames = ['maximumAttemptsPerInvocation', 'maxPendingOperations', 'invocationBudgetMilliseconds',
  'prearmDelayMilliseconds', 'retryDelayMilliseconds', 'continuationDelayMilliseconds'];
function operational(raw, bootstrap = false) {
  const value = exact(raw, [...operationalNames, ...(bootstrap ? ['deliveryLeaseSeconds'] : [])]);
  requireValue(Object.values(value).every(n => Number.isSafeInteger(n) && n > 0)
    && value.maximumAttemptsPerInvocation <= 100 && value.maxPendingOperations <= 64 && value.invocationBudgetMilliseconds <= 60000
    && [value.prearmDelayMilliseconds, value.retryDelayMilliseconds, value.continuationDelayMilliseconds].every(n => n <= 86400000)
    && (!bootstrap || value.deliveryLeaseSeconds <= 1800));
  return value;
}
export function deviceConfiguration(env) {
  try {
    const commerce = config(env), raw = exact(canonicalJSON(env.DEVICE_LICENCE_CONFIG_V1, 8192),
      ['version', 'realm', 'selection', 'sealerKeyID', 'sealerCommitment', 'qualification', 'operational']);
    requireValue(raw.version === 1 && typeof raw.realm === 'string' && /^[a-z0-9][a-z0-9_-]{0,63}$/.test(raw.realm));
    const selection = exact(raw.selection, ['profileID', 'bootstrapKeyID', 'bootstrapPublicKey', 'receiptIssuerKeyID', 'receiptIssuerPublicKey']);
    const trust = Object.freeze({ expectedProfileID: selection.profileID, bootstrapKeyID: selection.bootstrapKeyID,
      bootstrapPublicKey: selection.bootstrapPublicKey, receiptIssuerKeyIDs: Object.freeze([selection.receiptIssuerKeyID]) });
    createDeviceBootstrapAdmission({ enabled: true, realm: raw.realm, origin: commerce.origin, trust });
    requireValue(decode(selection.receiptIssuerPublicKey, 65)[0] === 4
      && typeof raw.sealerKeyID === 'string' && /^[a-z0-9][a-z0-9_-]{0,31}$/.test(raw.sealerKeyID)
      && new Set([selection.bootstrapKeyID, selection.receiptIssuerKeyID, raw.sealerKeyID]).size === 3
      && selection.bootstrapPublicKey !== selection.receiptIssuerPublicKey);
    decode(raw.sealerCommitment, 32);
    const q = exact(raw.qualification, ['recipient', 'orderRefs', 'startsAt', 'endsAt']);
    // One concrete owned purchase allocation. No public allow policy is supplied.
    requireValue(q.recipient === 'iam@antreas.io' && Array.isArray(q.orderRefs) && q.orderRefs.length === 1
      && typeof q.orderRefs[0] === 'string' && ORDER_REF.test(q.orderRefs[0])
      && Number.isSafeInteger(q.startsAt) && Number.isSafeInteger(q.endsAt) && q.startsAt > 0
      && q.endsAt > q.startsAt && q.endsAt - q.startsAt <= 900);
    const qualification = Object.freeze({ ...q, orderRefs: Object.freeze([...q.orderRefs]) });
    const p = exact(raw.operational, ['bootstrap', 'activation', 'limits', 'httpBodyTimeoutMilliseconds', 'mailTimeoutMilliseconds',
      'maxConcurrentRequests', 'alarmRecoveryDelayMilliseconds', 'orderRetrySeconds']);
    const limits = exact(p.limits, ['challengeTTLSeconds', 'deliveryLeaseSeconds']);
    requireValue(Object.values(limits).every(n => Number.isSafeInteger(n) && n > 0 && n <= 1800));
    requireValue(['httpBodyTimeoutMilliseconds', 'mailTimeoutMilliseconds', 'maxConcurrentRequests', 'alarmRecoveryDelayMilliseconds', 'orderRetrySeconds']
      .every(k => Number.isSafeInteger(p[k]) && p[k] > 0)
      && p.httpBodyTimeoutMilliseconds <= 60000 && p.mailTimeoutMilliseconds <= 60000 && p.alarmRecoveryDelayMilliseconds <= 86400000);
    const policy = Object.freeze({ ...p, limits, bootstrap: operational(p.bootstrap, true), activation: operational(p.activation) });
    return Object.freeze({ ...raw, selection, trust, qualification, operational: policy, commerce });
  } catch { reject(); }
}
export function qualificationActive(c, now = Math.floor(Date.now() / 1000)) {
  return Number.isSafeInteger(now) && now >= c.qualification.startsAt && now < c.qualification.endsAt;
}
export function qualifiedScope(c, scope) {
  const f = c.commerce;
  requireValue(c.qualification.orderRefs.includes(scope.orderRef)
    && ['accountId', 'mode', 'productId', 'priceId', 'currency', 'unitAmount', 'taxBehavior'].every(k => scope[k] === f[k]));
}
const keyCache = new WeakMap();
export async function deviceKeys(env, c) {
  let entry = keyCache.get(env);
  if (entry) { requireValue(entry.configuration === env.DEVICE_LICENCE_CONFIG_V1 && entry.binding === env.DEVICE_LICENCE_CUSTODY_V1); return entry.promise; }
  const binding = env.DEVICE_LICENCE_CUSTODY_V1, configuration = env.DEVICE_LICENCE_CONFIG_V1;
  const promise = Promise.resolve().then(async () => {
    let raw, bytes;
    try {
      raw = exact(canonicalJSON(binding, 8192), ['bootstrapSigner', 'receiptSigner', 'setupSealer']);
      const sealer = exact(raw.setupSealer, ['role', 'keyID', 'keyBytes']);
      requireValue(Array.isArray(sealer.keyBytes) && sealer.keyBytes.length === 32
        && sealer.keyBytes.every(n => Number.isInteger(n) && n >= 0 && n <= 255));
      bytes = Uint8Array.from(sealer.keyBytes);
      requireValue(sealer.keyID === c.sealerKeyID && await digest(bytes) === c.sealerCommitment
        && raw.bootstrapSigner.keyID === c.selection.bootstrapKeyID && raw.bootstrapSigner.publicKey === c.selection.bootstrapPublicKey
        && raw.receiptSigner.keyID === c.selection.receiptIssuerKeyID && raw.receiptSigner.publicKey === c.selection.receiptIssuerPublicKey);
      return await reconstructHostKeyCapabilities({ enabled: true, material: { ...raw, setupSealer: { ...sealer, keyBytes: bytes } } });
    } catch { reject(); }
    finally {
      bytes?.fill(0); raw?.setupSealer?.keyBytes?.fill(0);
      if (raw?.bootstrapSigner?.privateJWK) raw.bootstrapSigner.privateJWK.d = '';
      if (raw?.receiptSigner?.privateJWK) raw.receiptSigner.privateJWK.d = '';
    }
  });
  entry = { binding, configuration, promise }; keyCache.set(env, entry);
  promise.catch(() => { if (keyCache.get(env) === entry) keyCache.delete(env); });
  return promise;
}
export async function deviceReadiness(env) {
  const c = deviceConfiguration(env);
  requireValue(env.DEVICE_FULFILMENT_ENABLED === 'true' && qualificationActive(c)
    && ['CHECKOUT_ENABLED', 'ISSUANCE_ENABLED', 'DELIVERY_ENABLED', 'EMAIL_DELIVERY_ENABLED'].every(k => env[k] === 'true')
    && env.EMAIL_FROM === 'support@cliphoard.dev' && typeof env.EMAIL?.send === 'function'
    && typeof env.CHECKOUT_RATE_LIMITER?.limit === 'function' && validWebhookSecret(env.STRIPE_WEBHOOK_SECRET));
  for (const binding of [env.STRIPE_ORDERS, env.DEVICE_LICENCE_DIRECTORY, env.DEVICE_LICENCE_ENTITLEMENTS])
    requireValue(binding && ['idFromName', 'get', 'getByName'].every(k => typeof binding[k] === 'function'));
  decode(env.CLAIM_ENCRYPTION_KEY, 32); stripeClient(env); await deviceKeys(env, c); return true;
}
export function guardedDeviceMail(env, c, claimURL) {
  requireValue(typeof claimURL === 'string'); const link = new URL(claimURL);
  requireValue(link.origin === c.commerce.origin && link.pathname === '/pro/claim' && !link.hash
    && [...link.searchParams.keys()].length === 2 && c.qualification.orderRefs.includes(link.searchParams.get('order'))
    && /^[A-Za-z0-9_-]{43}$/.test(link.searchParams.get('token') ?? ''));
  return input => {
    let bootstrap = false, message;
    if (input && Object.hasOwn(input, 'deliveryID')) {
      const value = exact(input, ['deliveryID', 'message']);
      requireValue(typeof value.deliveryID === 'string' && /^[A-Za-z0-9_-]{22}\.(?:initial|[A-Za-z0-9_-]{22})$/.test(value.deliveryID));
      message = exact(value.message, ['from', 'to', 'replyTo', 'subject', 'text']); bootstrap = true;
    } else message = exact(input, ['from', 'to', 'replyTo', 'subject', 'text']);
    requireValue(message.from === 'support@cliphoard.dev' && message.replyTo === 'support@cliphoard.dev'
      && message.to === c.qualification.recipient && typeof message.subject === 'string' && typeof message.text === 'string');
    const dispatch = bootstrap ? { ...message, text: `${message.text}\n\nPrivate setup recovery (use the page button to request setup instructions):\n${claimURL}` } : message;
    // This entire wrapper is synchronous until EMAIL.send: preserve the caller's
    // immediately preceding same-SQLite authority/lease fence and kill switches.
    requireValue(env.DELIVERY_ENABLED === 'true' && env.EMAIL_DELIVERY_ENABLED === 'true'
      && env.DEVICE_FULFILMENT_ENABLED === 'true' && qualificationActive(c));
    const operation = env.EMAIL.send(dispatch);
    return Promise.resolve(operation).then(value => {
      const result = captureRPC(value, ['messageId']);
      requireValue(typeof result.messageId === 'string' && result.messageId.length > 0 && result.messageId.length < 256 && !/[\x00-\x1f\x7f]/.test(result.messageId));
      return result;
    }, () => reject());
  };
}
export const randomID = () => base64url(crypto.getRandomValues(new Uint8Array(16)));
