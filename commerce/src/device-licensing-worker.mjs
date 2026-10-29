// Complete opt-in candidate entry. Existing stripe-worker/default deployment is
// unchanged. No production keys, realm, policy values or secrets are embedded.
import { DurableObject } from 'cloudflare:workers';
import { createStripeWorker } from './stripe-worker.mjs';
import { stripeClient } from './stripe-client.mjs';
import { purchasePage } from './stripe-frontdoor.mjs';
import { boundedBody, parseJSON, failure, need, ORDER_REF } from './stripe-security.mjs';
import { sha256 } from './licence.mjs';
import { createStripeDeviceOrderHost } from './stripe-device-order-host.mjs';
import { createDeviceSetupRecoveryRoute } from './device-setup-recovery.mjs';
import { createDeviceLicenceDurableObjectClasses, createDeviceLicenceAuthenticatedEdge } from '../licensing-prototype/durable-object-hosts.mjs';
import { createDeviceBootstrapAdmission } from '../licensing-prototype/bootstrap-admission.mjs';
import { decode } from '../licensing-prototype/protocol.mjs';
import { exact, captureRPC, requireValue, deviceConfiguration, deviceKeys, deviceReadiness,
  guardedDeviceMail, qualificationActive, qualifiedScope, randomID } from './device-licensing-config.mjs';
const scopeFields = ['accountId', 'mode', 'orderRef', 'sessionId', 'productId', 'priceId', 'currency', 'unitAmount', 'taxBehavior'];
// The native alarm entry receives platform retry metadata. Domain alarm methods
// intentionally take no arguments; capture this boundary before invoking them.
function nativeAlarm(args) {
  requireValue(args.length <= 1);
  if (args.length && args[0] !== undefined) {
    requireValue(args[0] !== null && typeof args[0] === 'object');
    // Workerd supplies an AlarmInvocationInfo platform instance, not a plain
    // object. Copy only own data slots; never invoke getters or prototype methods.
    const descriptors = Object.getOwnPropertyDescriptors(args[0]), scheduled = Object.hasOwn(descriptors, 'scheduledTime');
    const names = ['retryCount', 'isRetry', ...(scheduled ? ['scheduledTime'] : [])];
    requireValue(Reflect.ownKeys(descriptors).length === names.length && names.every(k => descriptors[k] && Object.hasOwn(descriptors[k], 'value')));
    const value = Object.fromEntries(names.map(k => [k, descriptors[k].value]));
    requireValue(Number.isSafeInteger(value.retryCount) && value.retryCount >= 0 && typeof value.isRetry === 'boolean');
    if (scheduled) requireValue(Number.isSafeInteger(value.scheduledTime) && value.scheduledTime > 0);
  }
}
const common = (env, c) => ({ realm: c.realm, directoryNamespace: env.DEVICE_LICENCE_DIRECTORY, targetNamespace: env.DEVICE_LICENCE_ENTITLEMENTS });
function order(env, c, orderRef) {
  requireValue(typeof orderRef === 'string' && ORDER_REF.test(orderRef));
  return env.STRIPE_ORDERS.getByName(`${c.commerce.accountId}:${c.commerce.mode}:${orderRef}`);
}
function inspector(env, c) {
  return async scope => {
    qualifiedScope(c, scope);
    const value = captureRPC(await order(env, c, scope.orderRef).inspectDeviceAuthority(), [...scopeFields, 'state', 'ownerEmail']);
    requireValue(scopeFields.every(k => value[k] === scope[k]) && ['active', 'pending', 'blocked'].includes(value.state)
      && (value.state === 'active' ? value.ownerEmail === c.qualification.recipient : value.ownerEmail === null));
    return value;
  };
}
// Admission is durable, target-owned and initially HOLD. Only a trusted binding
// operator can CAS a revision; no public route exposes this operation.
function admission(ctx, c, reservation) {
  qualifiedScope(c, reservation.scope); decode(reservation.entitlementID, 16);
  const binding = JSON.stringify({ realm: c.realm, profile: c.selection.profileID, entitlementID: reservation.entitlementID, scope: reservation.scope });
  const sql = ctx.storage.sql;
  const read = () => {
    ctx.storage.transactionSync(() => {
      sql.exec('CREATE TABLE IF NOT EXISTS device_qualification_admission(singleton INTEGER PRIMARY KEY CHECK(singleton=1), binding TEXT NOT NULL, revision INTEGER NOT NULL, decision TEXT NOT NULL)');
      sql.exec("INSERT OR IGNORE INTO device_qualification_admission VALUES(1,?,1,'hold')", binding);
    });
    const rows = Array.from(sql.exec('SELECT binding,revision,decision FROM device_qualification_admission'));
    requireValue(rows.length === 1 && rows[0].binding === binding && Number.isSafeInteger(rows[0].revision)
      && rows[0].revision > 0 && ['hold', 'allow'].includes(rows[0].decision));
    return rows[0];
  };
  const current = () => {
    const row = read(); return Object.freeze({ entitlementID: reservation.entitlementID, revision: row.revision,
      decision: qualificationActive(c) ? row.decision : 'hold' });
  };
  return Object.freeze({
    evaluate: async value => { requireValue(value?.entitlementID === reservation.entitlementID); const row = current(); return { revision: row.revision, decision: row.decision }; },
    readCurrent: async id => { requireValue(id === reservation.entitlementID); return current(); },
    set: async input => {
      const value = exact(input, ['expectedRevision', 'decision']);
      requireValue(Number.isSafeInteger(value.expectedRevision) && value.expectedRevision > 0 && ['hold', 'allow'].includes(value.decision));
      requireValue(value.decision === 'hold' || qualificationActive(c));
      read(); let result;
      ctx.storage.transactionSync(() => {
        const rows = Array.from(sql.exec('SELECT binding,revision,decision FROM device_qualification_admission'));
        requireValue(rows.length === 1 && rows[0].binding === binding);
        const old = rows[0]; requireValue(old.revision === value.expectedRevision && Number.isSafeInteger(old.revision + 1));
        sql.exec('UPDATE device_qualification_admission SET revision=?,decision=? WHERE singleton=1 AND revision=?', old.revision + 1, value.decision, old.revision);
        result = Object.freeze({ entitlementID: reservation.entitlementID, revision: old.revision + 1, decision: qualificationActive(c) ? value.decision : 'hold' });
      });
      await ctx.storage.sync(); return result;
    },
  });
}
const Hosts = createDeviceLicenceDurableObjectClasses({ enabled: true, DurableObject,
  configureDirectory: (_ctx, env) => {
    const c = deviceConfiguration(env);
    return { ...common(env, c), inspectDeviceAuthority: inspector(env, c), allocateEntitlementID: randomID, allocateProvisioningID: randomID };
  },
  configureEntitlement: async (ctx, env, reservation) => {
    const c = deviceConfiguration(env); qualifiedScope(c, reservation.scope);
    const keys = await deviceKeys(env, c);
    // Private claim bearer remains in memory only, before any dispatch fence.
    const link = captureRPC(await order(env, c, reservation.scope.orderRef).setupRecoveryLink(), ['claimURL']);
    const send = guardedDeviceMail(env, c, link.claimURL), gate = admission(ctx, c, reservation);
    return { ...common(env, c), selection: c.selection, keys, inspectDeviceAuthority: inspector(env, c),
      admission: { evaluate: gate.evaluate, readCurrent: gate.readCurrent },
      mail: { from: 'support@cliphoard.dev', replyTo: 'support@cliphoard.dev', send, timeoutMilliseconds: c.operational.mailTimeoutMilliseconds },
      clocks: { epochMilliseconds: () => Date.now(), monotonicMilliseconds: () => performance.now() },
      bootstrapOperational: c.operational.bootstrap, activationOperational: c.operational.activation, limits: c.operational.limits,
      http: { origin: c.commerce.origin, bodyTimeoutMs: c.operational.httpBodyTimeoutMilliseconds },
      maxConcurrentRequests: c.operational.maxConcurrentRequests, alarmRecoveryDelayMilliseconds: c.operational.alarmRecoveryDelayMilliseconds };
  },
});
export class DeviceLicenceDirectory extends Hosts.Directory {}
export class DeviceLicenceEntitlement extends Hosts.Entitlement {
  #ctx; #env;
  constructor(ctx, env) { super(ctx, env); this.#ctx = ctx; this.#env = env; }
  alarm(...args) { nativeAlarm(args); return super.alarm(); }
  // Trusted binding inspection only: SELECT existing state, never initialize it.
  readAdmission(...args) {
    requireValue(args.length === 0); const c = deviceConfiguration(this.#env), sql = this.#ctx.storage.sql;
    const tables = Array.from(sql.exec("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('device_licence_host_reservation','device_qualification_admission')"));
    const present = name => tables.some(row => row.name === name), uninitialized = () => Object.freeze({ state: 'uninitialized' });
    if (!present('device_licence_host_reservation')) { requireValue(!present('device_qualification_admission')); return uninitialized(); }
    const rows = Array.from(sql.exec('SELECT singleton,reservation_json,ready_ack FROM device_licence_host_reservation'));
    requireValue(rows.length === 1 && rows[0].singleton === 1);
    const raw = exact(JSON.parse(rows[0].reservation_json), ['entitlementID', 'provisioningID', 'scope']);
    const reservation = Object.freeze({ ...raw, scope: exact(raw.scope, scopeFields) });
    requireValue(JSON.stringify(reservation) === rows[0].reservation_json);
    decode(reservation.entitlementID, 16); decode(reservation.provisioningID, 16); qualifiedScope(c, reservation.scope);
    requireValue(typeof reservation.scope.sessionId === 'string' && /^cs_[A-Za-z0-9_]{1,180}$/.test(reservation.scope.sessionId)
      && this.#ctx.id.toString() === this.#env.DEVICE_LICENCE_ENTITLEMENTS.idFromName(`${c.realm}:entitlement:${reservation.entitlementID}`).toString());
    if (rows[0].ready_ack === null) { requireValue(!present('device_qualification_admission')); return uninitialized(); }
    const ack = exact(JSON.parse(rows[0].ready_ack), ['entitlementID', 'provisioningID', 'bindingDigest']);
    requireValue(JSON.stringify(ack) === rows[0].ready_ack && ack.entitlementID === reservation.entitlementID && ack.provisioningID === reservation.provisioningID);
    decode(ack.bindingDigest, 32);
    if (!present('device_qualification_admission')) return uninitialized();
    const admissionRows = Array.from(sql.exec('SELECT singleton,binding,revision,decision FROM device_qualification_admission'));
    const binding = JSON.stringify({ realm: c.realm, profile: c.selection.profileID, entitlementID: reservation.entitlementID, scope: reservation.scope });
    requireValue(admissionRows.length === 1 && admissionRows[0].singleton === 1 && admissionRows[0].binding === binding
      && Number.isSafeInteger(admissionRows[0].revision) && admissionRows[0].revision > 0 && ['hold', 'allow'].includes(admissionRows[0].decision));
    const row = admissionRows[0];
    return Object.freeze({ entitlementID: reservation.entitlementID, revision: row.revision,
      storedDecision: row.decision, effectiveDecision: qualificationActive(c) ? row.decision : 'hold' });
  }
  async setAdmission(...args) {
    requireValue(args.length === 1); const c = deviceConfiguration(this.#env);
    const rows = Array.from(this.#ctx.storage.sql.exec('SELECT reservation_json,ready_ack FROM device_licence_host_reservation WHERE singleton=1'));
    requireValue(rows.length === 1 && rows[0].ready_ack !== null);
    const reservation = JSON.parse(rows[0].reservation_json);
    requireValue(this.#ctx.id.toString() === this.#env.DEVICE_LICENCE_ENTITLEMENTS.idFromName(`${c.realm}:entitlement:${reservation.entitlementID}`).toString());
    return admission(this.#ctx, c, reservation).set(args[0]);
  }
}
const OrderHost = createStripeDeviceOrderHost({ enabled: true, DurableObject, configure: (_ctx, env) => {
  const c = deviceConfiguration(env);
  return { orderNamespace: env.STRIPE_ORDERS, directoryNamespace: env.DEVICE_LICENCE_DIRECTORY,
    directoryName: `${c.realm}:directory`, stripe: stripeClient(env), deliver: undefined,
    now: () => Math.floor(Date.now() / 1000), retrySeconds: c.operational.orderRetrySeconds,
    alarmRecoveryDelayMilliseconds: c.operational.alarmRecoveryDelayMilliseconds,
    // Keep the trusted device-row interpreter present while switches are paused.
    // Its readiness callback blocks new Sessions; refunds/inspection still run.
    deviceFulfilment: { enabled: true, readiness: () => deviceReadiness(env) } };
} });
// Preserve original deployed namespace/export name and existing order rows.
export class StripeOrder extends OrderHost { alarm(...args) { nativeAlarm(args); return super.alarm(); } }
const stripeWorker = createStripeWorker();
const edgeCache = new WeakMap();
function edge(env, c) {
  if (!edgeCache.has(env)) {
    const signed = createDeviceBootstrapAdmission({ enabled: true, realm: c.realm, origin: c.commerce.origin, trust: c.trust });
    edgeCache.set(env, { configuration: env.DEVICE_LICENCE_CONFIG_V1, value: createDeviceLicenceAuthenticatedEdge({ enabled: true, ...common(env, c), origin: c.commerce.origin,
      maxConcurrentRequests: c.operational.maxConcurrentRequests, authenticate: signed.authenticate }) });
  }
  const entry = edgeCache.get(env); requireValue(entry.configuration === env.DEVICE_LICENCE_CONFIG_V1); return entry.value;
}
export default { async fetch(request, env) {
  try {
    const url = new URL(request.url), c = deviceConfiguration(env);
    if (url.pathname === '/') {
      need(request.method === 'GET', 405, 'method_not_allowed');
      return purchasePage(env, url, { deviceFulfilment: { enabled: true, readiness: () => deviceReadiness(env) } });
    }
    if (url.pathname.startsWith('/device-licensing/')) {
      requireValue(env.DEVICE_FULFILMENT_ENABLED === 'true' && qualificationActive(c)); return edge(env, c).handle(request);
    }
    if (url.pathname === '/checkout/stripe') {
      await deviceReadiness(env);
      const value = parseJSON(await boundedBody(request.clone(), 1024));
      requireValue(c.qualification.orderRefs.includes(value?.orderRef));
    }
    if (url.pathname === '/pro/recover') {
      requireValue(env.DEVICE_FULFILMENT_ENABLED === 'true' && qualificationActive(c));
      const route = createDeviceSetupRecoveryRoute({ enabled: true, origin: c.commerce.origin,
        bodyTimeoutMilliseconds: c.operational.httpBodyTimeoutMilliseconds,
        admit: async (original, ref) => {
          if (!c.qualification.orderRefs.includes(ref)) return false;
          const ip = original.headers.get('CF-Connecting-IP'); if (!ip) return false;
          return (await env.CHECKOUT_RATE_LIMITER.limit({ key: await sha256(`${c.commerce.accountId}:${ip}:${ref}`) }))?.success === true;
        },
        requestRecovery: async input => {
          const ack = captureRPC(await order(env, c, input.orderRef).requestSetupRecovery(input), ['ok', 'code']);
          requireValue(ack.ok === true && ack.code === 'delivery_requested'); return ack;
        },
      });
      return route.handle(request);
    }
    return stripeWorker.fetch(request, env);
  } catch (error) { return failure(error); }
} };

// Explicit service-binding RPC export; default HTTP routing is unchanged.
export { DeviceLicenceOperator } from './device-licensing-operator.mjs';
