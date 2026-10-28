// Opt-in host composition only. No default Worker, environment names, production
// policy values, secret acquisition or deployment configuration are selected.
import { decode } from './protocol.mjs';
import { identifier, ORDER_REF } from '../src/stripe-security.mjs';
import { createDeviceBootstrapDirectory } from './bootstrap-directory.mjs';
import { createDeviceBootstrapDirectoryEdge, captureDeviceBootstrapDirectoryRPCAcknowledgement as captureAck } from './bootstrap-directory-edge.mjs';
import { createPurchaseBootstrapCoordinator } from './purchase-bootstrap-coordinator.mjs';
import { createDeviceBootstrapService } from './bootstrap-service.mjs';
import { createDeviceBootstrapMail } from './bootstrap-mail.mjs';
import { createDeviceLicenceAlarmMultiplexer } from './bootstrap-alarm.mjs';
import { createDeviceLicenceRouteTarget, createDeviceLicencePublicRouter } from './public-router.mjs';

class HostError extends Error { constructor(code) { super(code); this.name = 'DeviceLicenceHostError'; this.code = code; } }
const fail = (code = 'host_unavailable') => { throw new HostError(code); };
const need = condition => { if (!condition) fail(); };
const fields = ['accountId', 'mode', 'orderRef', 'sessionId', 'productId', 'priceId', 'currency', 'unitAmount', 'taxBehavior'];
function data(value, names) {
  need(value && typeof value === 'object' && [Object.prototype, null].includes(Object.getPrototypeOf(value)));
  const d = Object.getOwnPropertyDescriptors(value);
  need(Reflect.ownKeys(d).length === names.length && names.every(n => d[n] && Object.hasOwn(d[n], 'value')));
  return Object.freeze(Object.fromEntries(names.map(n => [n, d[n].value])));
}
function enabled(options) {
  need(options && typeof options === 'object'); const d = Object.getOwnPropertyDescriptor(options, 'enabled');
  if (d === undefined) return false; need(Object.hasOwn(d, 'value')); return d.value === true;
}
function scope(value) {
  const v = data(value, fields);
  need(identifier(v.accountId, 'acct') && ['test', 'live'].includes(v.mode) && typeof v.orderRef === 'string'
    && ORDER_REF.test(v.orderRef) && identifier(v.sessionId, 'cs') && identifier(v.productId, 'prod')
    && identifier(v.priceId, 'price') && typeof v.currency === 'string' && /^[a-z]{3}$/.test(v.currency)
    && Number.isSafeInteger(v.unitAmount) && v.unitAmount > 0 && v.taxBehavior === 'inclusive');
  return v;
}
function reservation(value) {
  const v = data(value, ['entitlementID', 'provisioningID', 'scope']); decode(v.entitlementID, 16); decode(v.provisioningID, 16);
  return Object.freeze({ ...v, scope: scope(v.scope) });
}
function common(value) {
  need(typeof value.realm === 'string' && /^[a-z0-9][a-z0-9_-]{0,63}$/.test(value.realm));
  for (const ns of [value.directoryNamespace, value.targetNamespace])
    need(ns && typeof ns.getByName === 'function' && typeof ns.idFromName === 'function');
  return value;
}
const targetName = (realm, id) => `${realm}:entitlement:${id}`;
const directoryName = realm => `${realm}:directory`;
const storageAdapter = s => ({ sql: { exec: (q, ...p) => s.sql.exec(q, ...p) },
  transactionSync: f => s.transactionSync(f), sync: () => s.sync() });
const alarmAdapter = s => ({ getAlarm: () => s.getAlarm(), setAlarm: n => s.setAlarm(n),
  deleteAlarm: () => s.deleteAlarm(), sync: () => s.sync() });
const unavailable = (status = 503) => Response.json({ ok: false, code: 'temporarily_unavailable' },
  { status, headers: { 'cache-control': 'no-store', 'referrer-policy': 'no-referrer' } });
async function guarded(operation) { try { return await operation(); } catch { fail(); } }

// configure* are trusted application capabilities, never request-controlled.
// Their inspector must query the existing authoritative order service. This
// composition creates no duplicate payment/order ledger.
export function createDeviceLicenceDurableObjectClasses(options = {}) {
  if (!enabled(options)) fail('host_disabled');
  const o = data(options, ['enabled', 'DurableObject', 'configureDirectory', 'configureEntitlement']);
  need([o.DurableObject, o.configureDirectory, o.configureEntitlement].every(f => typeof f === 'function'));
  class Directory extends o.DurableObject {
    #config; #directory; #pending = new Map();
    constructor(ctx, env) {
      super(ctx, env);
      this.#config = common(data(o.configureDirectory(ctx, env), ['realm', 'directoryNamespace', 'targetNamespace',
        'inspectDeviceAuthority', 'allocateEntitlementID', 'allocateProvisioningID']));
      const c = this.#config;
      need([c.inspectDeviceAuthority, c.allocateEntitlementID, c.allocateProvisioningID].every(f => typeof f === 'function'));
      need(ctx.id.toString() === c.directoryNamespace.idFromName(directoryName(c.realm)).toString());
      this.#directory = createDeviceBootstrapDirectory({ enabled: true, storage: storageAdapter(ctx.storage),
        provisionTarget: async pinned => captureAck(await c.targetNamespace.getByName(targetName(c.realm, pinned.entitlementID)).provision(pinned)) });
    }
    processPurchase(...args) {
      try {
        need(args.length === 1); const pinned = scope(args[0]), key = JSON.stringify(pinned), c = this.#config;
        if (this.#pending.has(key)) return this.#pending.get(key);
        const operation = Promise.resolve().then(() => guarded(() => createPurchaseBootstrapCoordinator({ enabled: true,
          scope: pinned, inspectDeviceAuthority: () => c.inspectDeviceAuthority(pinned), directory: this.#directory,
          allocateEntitlementID: c.allocateEntitlementID, allocateProvisioningID: c.allocateProvisioningID,
          resolveTarget: ack => ({ ...ack, requestIssue: async () => captureResult(await c.targetNamespace
            .getByName(targetName(c.realm, ack.entitlementID)).requestIssue(ack), ['issued', 'already_issued']) }),
        }).process())).finally(() => { if (this.#pending.get(key) === operation) this.#pending.delete(key); });
        this.#pending.set(key, operation); return operation;
      } catch { return Promise.reject(new HostError('host_unavailable')); }
    }
    lookupReady(...args) { return guarded(() => { need(args.length === 1); return this.#directory.lookupReady(args[0]); }); }
    refreshPurchase(...args) {
      return guarded(async () => {
        need(args.length === 1); const pinned = scope(args[0]), old = await this.#directory.lookupReservation(pinned);
        if (old === null) return Object.freeze({ ok: true, code: 'absent' });
        const ack = await this.#directory.lookupReady(old.entitlementID); need(ack !== null);
        return captureResult(await this.#config.targetNamespace.getByName(targetName(this.#config.realm, ack.entitlementID)).refreshAuthority(ack), ['authority_refreshed']);
      });
    }
    fetch() { return unavailable(404); }
  }
  class Entitlement extends o.DurableObject {
    #ctx; #env; #opening; #pinned; #components;
    constructor(ctx, env) { super(ctx, env); this.#ctx = ctx; this.#env = env; }
    #read() {
      const s = this.#ctx.storage;
      if (Array.from(s.sql.exec("SELECT name FROM sqlite_master WHERE type='table' AND name='device_licence_host_reservation'")).length === 0) return null;
      const rows = Array.from(s.sql.exec('SELECT singleton,reservation_json FROM device_licence_host_reservation'));
      need(rows.length === 1 && rows[0].singleton === 1);
      const pinned = reservation(JSON.parse(rows[0].reservation_json)); need(JSON.stringify(pinned) === rows[0].reservation_json); return pinned;
    }
    #ready() {
      if (this.#read() === null) return false;
      const rows = Array.from(this.#ctx.storage.sql.exec('SELECT ready_ack FROM device_licence_host_reservation WHERE singleton=1'));
      need(rows.length === 1); return rows[0].ready_ack !== null;
    }
    #open(value, mayProvision = false) {
      const pinned = reservation(value), encoded = JSON.stringify(pinned);
      const persisted = this.#read();
      need(persisted === null ? mayProvision : JSON.stringify(persisted) === encoded);
      if (this.#pinned) need(JSON.stringify(this.#pinned) === encoded);
      if (this.#opening) return this.#opening;
      this.#pinned = pinned;
      this.#opening = Promise.resolve().then(async () => {
        const c = common(data(await o.configureEntitlement(this.#ctx, this.#env, pinned), ['realm', 'directoryNamespace', 'targetNamespace',
          'selection', 'keys', 'inspectDeviceAuthority', 'admission', 'mail', 'clocks', 'bootstrapOperational', 'activationOperational',
          'limits', 'http', 'maxConcurrentRequests', 'alarmRecoveryDelayMilliseconds']));
        need(this.#ctx.id.toString() === c.targetNamespace.idFromName(targetName(c.realm, pinned.entitlementID)).toString());
        need(typeof c.inspectDeviceAuthority === 'function');
        const s = this.#ctx.storage, storage = storageAdapter(s), previous = this.#read();
        need(previous === null ? mayProvision : JSON.stringify(previous) === encoded);
        // Persist only the immutable reservation. A crash before service provision
        // is recoverable through the same trusted reservation, never a new ID.
        if (previous === null) {
          s.transactionSync(() => {
            s.sql.exec('CREATE TABLE IF NOT EXISTS device_licence_host_reservation(singleton INTEGER PRIMARY KEY CHECK(singleton=1), reservation_json TEXT NOT NULL, ready_ack TEXT)');
            s.sql.exec('INSERT OR IGNORE INTO device_licence_host_reservation VALUES(1,?,NULL)', encoded);
            need(JSON.stringify(this.#read()) === encoded);
          });
          await s.sync();
        }
        const keys = data(c.keys, ['bootstrapSigner', 'receiptSigner', 'setupSealer']);
        const selection = data(c.selection, ['profileID', 'bootstrapKeyID', 'bootstrapPublicKey', 'receiptIssuerKeyID', 'receiptIssuerPublicKey']);
        need(keys.bootstrapSigner.bootstrapKeyID === selection.bootstrapKeyID && keys.bootstrapSigner.bootstrapPublicKey === selection.bootstrapPublicKey
          && keys.receiptSigner.issuerKeyID === selection.receiptIssuerKeyID && keys.receiptSigner.issuerPublicKey === selection.receiptIssuerPublicKey);
        let bootstrap, target;
        const mux = createDeviceLicenceAlarmMultiplexer({ enabled: true, storage, physicalAlarm: alarmAdapter(s),
          clockMilliseconds: c.clocks.epochMilliseconds, recoveryDelayMilliseconds: c.alarmRecoveryDelayMilliseconds,
          handlers: { activation: () => target.alarm(), bootstrap: () => bootstrap.alarm() } });
        const inspect = () => c.inspectDeviceAuthority(pinned.scope);
        const delivery = createDeviceBootstrapMail({ enabled: true, entitlementID: pinned.entitlementID,
          trust: { expectedProfileID: selection.profileID, bootstrapKeyID: selection.bootstrapKeyID,
            bootstrapPublicKey: selection.bootstrapPublicKey, receiptIssuerKeyIDs: [selection.receiptIssuerKeyID] }, ...c.mail });
        bootstrap = createDeviceBootstrapService({ enabled: true, storage, reservation: pinned, selection,
          signer: { sign: keys.bootstrapSigner.sign }, custody: keys.setupSealer, inspectDeviceAuthority: inspect,
          delivery, alarmStorage: mux.bootstrap, clocks: c.clocks, operational: c.bootstrapOperational });
        const ack = await bootstrap.provision(), binding = bootstrap.readActivationBinding();
        target = createDeviceLicenceRouteTarget({ enabled: true, lifecycle: { enabled: true, storage, binding,
          inspectDeviceAuthority: inspect, issuer: keys.receiptSigner,
          tokenCustody: { sealToken: (value, aad) => keys.setupSealer.seal(value, `cliphoard.activation-token.v1\n${aad}`),
            openToken: (value, aad) => keys.setupSealer.open(value, `cliphoard.activation-token.v1\n${aad}`) },
          admission: { evaluate: (...a) => c.admission.evaluate(...a), readCurrent: () => c.admission.readCurrent(pinned.entitlementID) },
          mail: c.mail, alarmStorage: mux.activation, clocks: c.clocks, limits: c.limits,
          operational: c.activationOperational, http: c.http } });
        const router = createDeviceLicencePublicRouter({ enabled: true, origin: c.http.origin,
          maxConcurrentRequests: c.maxConcurrentRequests, lookupTarget: id => id === pinned.entitlementID ? target : null });
        s.transactionSync(() => {
          const value = JSON.stringify(ack);
          s.sql.exec('UPDATE device_licence_host_reservation SET ready_ack=? WHERE singleton=1 AND ready_ack IS NULL', value);
          need(Array.from(s.sql.exec('SELECT ready_ack FROM device_licence_host_reservation WHERE singleton=1'))[0].ready_ack === value);
        });
        await s.sync();
        this.#components = { bootstrap, target, mux, router, ack }; return this.#components;
      }).catch(() => { this.#opening = undefined; this.#components = undefined; this.#pinned = undefined; fail(); });
      return this.#opening;
    }
    async #existing(ack, required = false) {
      const v = required ? data(ack, ['entitlementID', 'provisioningID', 'bindingDigest']) : null;
      const stored = this.#read(); need(stored !== null && this.#ready());
      if (required) {
        const persisted = data(JSON.parse(Array.from(this.#ctx.storage.sql.exec(
          'SELECT ready_ack FROM device_licence_host_reservation WHERE singleton=1'))[0].ready_ack), ['entitlementID', 'provisioningID', 'bindingDigest']);
        need(Object.keys(v).every(key => v[key] === persisted[key]));
      }
      const c = await this.#open(stored);
      if (required) need(Object.keys(v).every(key => v[key] === c.ack[key]));
      return c;
    }
    provision(...a) { return guarded(async () => { need(a.length === 1); return (await this.#open(a[0], true)).ack; }); }
    requestIssue(...a) { return guarded(async () => { need(a.length === 1); return (await this.#existing(a[0], true)).bootstrap.requestIssue(); }); }
    requestRecovery(...a) { return guarded(async () => { need(a.length === 2); decode(a[1], 16); return (await this.#existing(a[0], true)).bootstrap.requestRecovery({ requestID: a[1] }); }); }
    refreshAuthority(...a) { return guarded(async () => {
      need(a.length === 1); const c = await this.#existing(a[0], true);
      // Both services share the same SQLite authority. Publish the terminal fence
      // to both outboxes even if one feed operation rejects.
      const results = await Promise.allSettled([c.bootstrap.refreshAuthority(), c.target.refreshAuthority()]);
      need(results.every(r => r.status === 'fulfilled')); return { ok: true, code: 'authority_refreshed' };
    }); }
    recover(...a) { return guarded(async () => {
      need(a.length === 1); const c = await this.#existing(a[0], true);
      const results = await Promise.allSettled([c.bootstrap.recover(), c.target.recover(), c.mux.recover()]);
      need(results.every(r => r.status === 'fulfilled')); return { ok: true, code: 'recovered' };
    }); }
    alarm(...a) { return guarded(async () => { need(a.length === 0); return (await this.#existing()).mux.alarm(); }); }
    async fetch(request) {
      try {
        need(request instanceof Request); const stored = this.#read();
        need(stored !== null && this.#ready() && request.headers.get('X-Cliphoard-Entitlement') === stored.entitlementID);
        return (await this.#open(stored)).router.handle(request);
      } catch { return unavailable(); }
    }
  }
  return Object.freeze({ Directory, Entitlement });
}

// RPC records can carry Cloudflare's own disposal metadata. Capture only the
// exact primitive result and release it, never pass RPC wrappers into domains.
function captureResult(value, acceptedCodes) {
  let dispose;
  try {
    need(value && typeof value === 'object'); const d = Object.getOwnPropertyDescriptors(value);
    if (d[Symbol.dispose]) { need(Object.hasOwn(d[Symbol.dispose], 'value') && typeof d[Symbol.dispose].value === 'function'); dispose = d[Symbol.dispose].value; }
    need(Reflect.ownKeys(d).every(k => ['ok', 'code'].includes(k) || k === Symbol.dispose));
    need(['ok', 'code'].every(k => d[k] && Object.hasOwn(d[k], 'value')) && d.ok.value === true && acceptedCodes.includes(d.code.value));
    return Object.freeze({ ok: true, code: d.code.value });
  } finally { if (dispose) Reflect.apply(dispose, value, []); }
}

export function createDeviceLicenceAuthenticatedEdge(options = {}) {
  if (!enabled(options)) return Object.freeze({ handle: async () => unavailable(404) });
  const c = common(data(options, ['enabled', 'realm', 'directoryNamespace', 'targetNamespace', 'origin', 'maxConcurrentRequests', 'authenticate']));
  need(typeof c.authenticate === 'function' && Number.isSafeInteger(c.maxConcurrentRequests) && c.maxConcurrentRequests > 0);
  let pending = 0;
  return Object.freeze({ async handle(request) {
    if (pending >= c.maxConcurrentRequests) return unavailable();
    pending++;
    try {
      const edge = createDeviceBootstrapDirectoryEdge({ enabled: true, origin: c.origin, maxConcurrentRequests: c.maxConcurrentRequests,
        lookupReady: async id => {
          const auth = data(await c.authenticate(request, id), ['decision', 'realm', 'entitlementID']);
          need(auth.decision === 'allow' && auth.realm === c.realm && auth.entitlementID === id);
          need(!request.bodyUsed && !request.body?.locked);
          return captureAck(await c.directoryNamespace.getByName(directoryName(c.realm)).lookupReady(id));
        },
        forward: (ack, original) => c.targetNamespace.getByName(targetName(c.realm, ack.entitlementID)).fetch(original) });
      return await edge.handle(request);
    } catch { return unavailable(); }
    finally { pending--; }
  } });
}
