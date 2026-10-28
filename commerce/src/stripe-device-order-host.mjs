// Explicit host composition for the ORIGINAL order ledger. No Worker export,
// route, new-order fulfilment mode, production policy or credentials selected.
import { StripeOrder } from './stripe-worker.mjs';
import { orderService } from './stripe-order.mjs';
import { config, identifier, need, ORDER_REF, TOKEN } from './stripe-security.mjs';
import { sha256 } from './licence.mjs';
import { createStripeDeviceFeed } from './stripe-device-feed.mjs';
import { createDeviceLicenceAlarmMultiplexer } from '../licensing-prototype/bootstrap-alarm.mjs';
import { decode } from '../licensing-prototype/protocol.mjs';

const FEED_KEY = 'cliphoard_device_feed_v1';
const reject = () => need(false, 503, 'order_host_unavailable');
const requireValue = value => { if (!value) reject(); };
function data(value, keys) {
  requireValue(value && [Object.prototype, null].includes(Object.getPrototypeOf(value)));
  const d = Object.getOwnPropertyDescriptors(value);
  requireValue(Reflect.ownKeys(d).length === keys.length && keys.every(k => d[k] && Object.hasOwn(d[k], 'value')));
  return Object.freeze(Object.fromEntries(keys.map(k => [k, d[k].value])));
}
// Cloudflare RPC adds disposal metadata. Capture primitives only, including the
// domain-specific ACK shape, and release metadata on success AND rejection.
function acknowledgement(value, kind) {
  let dispose;
  try {
    requireValue(value && typeof value === 'object');
    const d = Object.getOwnPropertyDescriptors(value);
    if (d[Symbol.dispose]) {
      requireValue(Object.hasOwn(d[Symbol.dispose], 'value') && typeof d[Symbol.dispose].value === 'function');
      dispose = d[Symbol.dispose].value;
    }
    const keys = kind === 'process' ? ['entitlementID', 'provisioningID', 'bindingDigest', 'ok', 'code'] : ['ok', 'code'];
    requireValue(Reflect.ownKeys(d).every(k => keys.includes(k) || k === Symbol.dispose)
      && keys.every(k => d[k] && Object.hasOwn(d[k], 'value')) && d.ok.value === true);
    requireValue((kind === 'process' ? ['issued', 'already_issued'] : ['absent', 'authority_refreshed']).includes(d.code.value));
    if (kind === 'process') {
      decode(d.entitlementID.value, 16); decode(d.provisioningID.value, 16); decode(d.bindingDigest.value, 32);
    }
    return true;
  } finally { if (dispose) Reflect.apply(dispose, value, []); }
}

export function createStripeDeviceOrderHost(options = {}) {
  const flag = Object.getOwnPropertyDescriptor(options, 'enabled');
  if (!flag || (Object.hasOwn(flag, 'value') && flag.value !== true)) throw Error('order_host_disabled');
  requireValue(Object.hasOwn(flag, 'value'));
  const o = data(options, ['enabled', 'DurableObject', 'configure']);
  requireValue(typeof o.DurableObject === 'function' && typeof o.configure === 'function');
  return class StripeDeviceOrderHost extends o.DurableObject {
    #ctx; #env; #config; #cfg; #order; #mux; #feed; #feedScope; #deviceFulfilment;
    constructor(ctx, env) {
      super(ctx, env); this.#ctx = ctx; this.#env = env; this.#cfg = config(env);
      const c = this.#config = data(o.configure(ctx, env), ['orderNamespace', 'directoryNamespace', 'directoryName',
        'stripe', 'deliver', 'now', 'retrySeconds', 'alarmRecoveryDelayMilliseconds', 'deviceFulfilment']);
      const mode = Object.getOwnPropertyDescriptor(c.deviceFulfilment, 'enabled');
      requireValue(mode && Object.hasOwn(mode, 'value') && [true, false].includes(mode.value));
      this.#deviceFulfilment = data(c.deviceFulfilment, mode.value ? ['enabled', 'readiness'] : ['enabled']);
      if (mode.value) requireValue(typeof this.#deviceFulfilment.readiness === 'function');
      requireValue(c.orderNamespace && typeof c.orderNamespace.idFromName === 'function'
        && c.directoryNamespace && typeof c.directoryNamespace.getByName === 'function'
        && typeof c.directoryName === 'string' && /^[a-z0-9][a-z0-9_-]{0,63}:directory$/.test(c.directoryName)
        && c.stripe && typeof c.now === 'function' && (c.deliver === undefined || typeof c.deliver === 'function')
        && Number.isSafeInteger(c.retrySeconds) && c.retrySeconds > 0);
      const s = ctx.storage, host = this;
      requireValue(s && ['get', 'put', 'transaction', 'transactionSync', 'sync', 'getAlarm', 'setAlarm', 'deleteAlarm'].every(k => typeof s[k] === 'function'));
      this.#mux = createDeviceLicenceAlarmMultiplexer({ enabled: true,
        storage: { sql: { exec: (q, ...a) => s.sql.exec(q, ...a) }, transactionSync: f => s.transactionSync(f), sync: () => s.sync() },
        physicalAlarm: { getAlarm: () => s.getAlarm(), setAlarm: n => s.setAlarm(n), deleteAlarm: () => s.deleteAlarm(), sync: () => s.sync() },
        clockMilliseconds: () => host.#now() * 1000, recoveryDelayMilliseconds: c.alarmRecoveryDelayMilliseconds,
        // Existing mux labels: activation = legacy CLIP1 mail; bootstrap = order feed.
        handlers: { activation: () => host.#legacyAlarm(), bootstrap: () => host.#feedAlarm() },
      });
      class OriginalOrder extends StripeOrder { service() { return host.#service(); } }
      this.#order = new OriginalOrder(ctx, env);
    }
    #now() { const n = this.#config.now(); requireValue(Number.isSafeInteger(n) && n > 0); return n; }
    #identity(ref) {
      requireValue(typeof ref === 'string' && ORDER_REF.test(ref) && config(this.#env).scope === this.#cfg.scope);
      const expected = this.#config.orderNamespace.idFromName(`${this.#cfg.accountId}:${this.#cfg.mode}:${ref}`);
      requireValue(this.#ctx.id.toString() === expected.toString());
    }
    async #stored(optional = false) {
      const row = await this.#ctx.storage.get('order');
      if (row === undefined && optional) return null;
      requireValue(row && [Object.prototype, null].includes(Object.getPrototypeOf(row)));
      const d = Object.getOwnPropertyDescriptors(row);
      requireValue(['scope', 'orderRef', 'sessionId'].every(k => d[k] && Object.hasOwn(d[k], 'value'))
        && d.scope.value === this.#cfg.scope && (identifier(d.sessionId.value, 'cs') || (optional && d.sessionId.value === null)));
      this.#identity(d.orderRef.value); return row;
    }
    #scope(row) {
      const c = this.#cfg; requireValue(identifier(row.sessionId, 'cs'));
      return Object.freeze({ accountId: c.accountId, mode: c.mode, orderRef: row.orderRef, sessionId: row.sessionId,
        productId: c.productId, priceId: c.priceId, currency: c.currency, unitAmount: c.unitAmount, taxBehavior: c.taxBehavior });
    }
    #core(scope) {
      return orderService({ env: this.#env, storage: this.#ctx.storage, stripe: this.#config.stripe,
        now: () => this.#now(), deliver: this.#config.deliver, deviceFulfilment: this.#deviceFulfilment,
        schedule: seconds => this.#mux.activation.setAlarm(seconds * 1000),
        ...(scope ? { deviceAuthority: { enabled: true, orderRef: scope.orderRef, sessionId: scope.sessionId } } : {}),
      });
    }
    #getFeed(row) {
      const scope = this.#scope(row), encoded = JSON.stringify(scope);
      if (this.#feed) { requireValue(encoded === this.#feedScope); return this.#feed; }
      const c = this.#config;
      this.#feed = createStripeDeviceFeed({ enabled: true, scope, storage: this.#ctx.storage,
        now: () => this.#now(), retrySeconds: c.retrySeconds, schedule: seconds => this.#mux.bootstrap.setAlarm(seconds * 1000),
        inspectDeviceAuthority: () => this.inspectDeviceAuthority(),
        processPurchase: async pinned => {
          // A pre-mutation wake remains pending if the original issuance switch
          // is paused. It must not turn a failed paid action into device issuance.
          requireValue(this.#env.ISSUANCE_ENABLED === 'true');
          return acknowledgement(await c.directoryNamespace.getByName(c.directoryName).processPurchase(pinned), 'process');
        },
        refreshPurchase: async pinned => acknowledgement(await c.directoryNamespace.getByName(c.directoryName).refreshPurchase(pinned), 'refresh'),
      });
      this.#feedScope = encoded; return this.#feed;
    }
    async #wake(row) {
      const feed = this.#getFeed(row);
      // Prearm BEFORE the feed's durable write. If interrupted before wake(), an
      // empty guarded alarm is harmless; original provider mutation has not run.
      await this.#mux.bootstrap.setAlarm(this.#now() * 1000 + this.#config.alarmRecoveryDelayMilliseconds);
      await feed.wake();
    }
    #service() {
      const core = this.#core(), host = this;
      return { ...core,
        start: ref => { host.#identity(ref); return core.start(ref); },
        paid: async (ref, session) => { const row = await host.#stored();
          requireValue(row.orderRef === ref && row.sessionId === session); await host.#wake(row); return core.paid(ref, session); },
        refund: async (ref, session) => { const row = await host.#stored();
          requireValue(row.orderRef === ref && row.sessionId === session); await host.#wake(row); return core.refund(ref, session); },
        claim: async (ref, token) => {
          // Preserve original invalid-token rejection without allowing a public
          // malformed claim to enqueue internal provisioning work.
          if (TOKEN.test(token ?? '')) {
            const row = await host.#stored(true);
            if (row && identifier(row.sessionId, 'cs') && row.orderRef === ref && !row.blocked && (row.licence || row.fulfilment === 'device-v1') && host.#env.DELIVERY_ENABLED === 'true'
              && await sha256(token) === row.tokenHash) await host.#wake(row);
          }
          return core.claim(ref, token);
        },
        retryDelivery: async ref => { const row = await host.#stored(true);
          if (row && identifier(row.sessionId, 'cs') && row.orderRef === ref && !row.blocked && row.licence) await host.#wake(row);
          return core.retryDelivery(ref); },
        drain: async () => { const row = await host.#stored(true);
          if (row && identifier(row.sessionId, 'cs') && !row.blocked && row.mail?.status === 'pending') await host.#wake(row);
          return core.drain(); },
      };
    }
    fetch(request) { return this.#order.fetch(request); }
    inspectDeviceAuthority(...args) {
      return this.#order.serial(async () => {
        requireValue(args.length === 0); const row = await this.#stored();
        return this.#core(this.#scope(row)).inspectDeviceAuthority();
      });
    }
    setupRecoveryLink(...args) {
      return this.#order.serial(async () => {
        requireValue(args.length === 0); const row = await this.#stored();
        return this.#core(this.#scope(row)).setupRecoveryLink();
      });
    }
    async requestSetupRecovery(...args) {
      requireValue(args.length === 1);
      const input = data(args[0], ['orderRef', 'token', 'requestID']); decode(input.requestID, 16);
      const scope = await this.#order.serial(async () => {
        const row = await this.#stored();
        requireValue(row.fulfilment === 'device-v1' && row.orderRef === input.orderRef
          && typeof input.token === 'string' && TOKEN.test(input.token) && await sha256(input.token) === row.tokenHash);
        try { return await this.#core().authorizeSetupRecovery(input.orderRef, input.token); }
        catch (error) {
          // A recovery request must never enqueue provisioning for a missing
          // reservation. Only a newly observed terminal block needs a feed wake.
          const current = await this.#stored();
          if (current.blocked) await this.#wake(current);
          throw error;
        }
      });
      // Outside original order serial gate: recovery service refreshes this order.
      const value = await this.#config.directoryNamespace.getByName(this.#config.directoryName)
        .requestRecovery(scope, input.requestID);
      let dispose;
      try {
        const d = Object.getOwnPropertyDescriptors(value);
        if (d[Symbol.dispose]) { requireValue(Object.hasOwn(d[Symbol.dispose], 'value') && typeof d[Symbol.dispose].value === 'function'); dispose = d[Symbol.dispose].value; }
        requireValue(Reflect.ownKeys(d).every(k => ['ok','code'].includes(k) || k === Symbol.dispose)
          && d.ok?.value === true && d.code?.value === 'delivery_requested');
        return { ok: true, code: 'delivery_requested' };
      } finally { if (dispose) Reflect.apply(dispose, value, []); }
    }
    async #legacyAlarm() {
      try {
        return await this.#order.serial(async () => {
          await this.#service().drain(); const row = await this.#ctx.storage.get('order');
          if (!row || row.blocked || row.mail?.status !== 'pending') await this.#mux.activation.deleteAlarm();
        });
      } catch { throw Error('stripe_outbox_retry_required'); }
    }
    async #feedAlarm() {
      // The mux already installed a durable dispatch guard. Remove only the
      // consumed logical wake BEFORE draining; never erase a concurrent later wake.
      await this.#mux.bootstrap.deleteAlarm();
      const feed = await this.#order.serial(async () => {
        const row = await this.#stored(true);
        if (!row) { requireValue(await this.#ctx.storage.get(FEED_KEY) === undefined); return null; }
        return this.#getFeed(row);
      });
      // Intentionally outside original serial gate: directory calls inspector back.
      if (feed) await feed.drain();
    }
    alarm(...args) { requireValue(args.length === 0); return this.#mux.alarm(); }
  };
}
