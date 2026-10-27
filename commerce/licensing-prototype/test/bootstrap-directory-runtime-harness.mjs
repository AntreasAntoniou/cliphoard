// Synthetic local workerd composition only. No shipping manifest references this
// module. Control RPCs are reachable only through the separate fixture host.
import { DurableObject } from 'cloudflare:workers';
import { createDeviceBootstrapDirectory } from '../bootstrap-directory.mjs';
import { createDeviceBootstrapDirectoryEdge, captureDeviceBootstrapDirectoryRPCAcknowledgement } from '../bootstrap-directory-edge.mjs';
import { createDeviceBootstrapService } from '../bootstrap-service.mjs';
import { createDeviceBootstrapMail } from '../bootstrap-mail.mjs';
import { createDeviceBootstrapSealer } from '../bootstrap-custody.mjs';
import { createDeviceLicenceAlarmMultiplexer } from '../bootstrap-alarm.mjs';
import { createDeviceLicenceRouteTarget, createDeviceLicencePublicRouter } from '../public-router.mjs';
import { base64url, decode, signReceipt } from '../protocol.mjs';

const origin = 'https://directory.synthetic.invalid';
const controlOrigin = 'https://control.synthetic.invalid';
const token = (bytes, value) => base64url(new Uint8Array(bytes).fill(value));
const reservation = index => ({ entitlementID: token(16, index), provisioningID: token(16, index + 20),
  scope: { accountId: 'acct_Directory', mode: 'test', orderRef: `00000000-0000-4000-8000-${String(index).padStart(12, '0')}`,
    sessionId: `cs_test_Directory${index}`, productId: 'prod_Directory', priceId: 'price_Directory',
    currency: 'gbp', unitAmount: 1000, taxBehavior: 'inclusive' } });
const targetName = id => `synthetic-entitlement-v1:${id}`;
const directoryStub = env => env.SYNTHETIC_DIRECTORY.getByName('synthetic-directory-v1');
const targetStub = (env, id) => env.SYNTHETIC_TARGET.getByName(targetName(id));
function storageAdapter(native) {
  return { sql: { exec: (query, ...values) => native.sql.exec(query, ...values) },
    transactionSync: callback => native.transactionSync(callback), sync: () => native.sync() };
}
function physicalAdapter(native) {
  return { getAlarm: () => native.getAlarm(), setAlarm: value => native.setAlarm(value),
    deleteAlarm: () => native.deleteAlarm(), sync: () => native.sync() };
}
const unavailable = () => Response.json({ ok: false, code: 'temporarily_unavailable' },
  { status: 503, headers: { 'cache-control': 'no-store', 'referrer-policy': 'no-referrer' } });

export class SyntheticBootstrapDirectory extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.directory = createDeviceBootstrapDirectory({ enabled: true, storage: storageAdapter(ctx.storage),
      provisionTarget: async pinned => {
        let result;
        try { result = captureDeviceBootstrapDirectoryRPCAcknowledgement(await targetStub(env, pinned.entitlementID).provision(pinned)); }
        catch (error) {
          await ctx.storage.put('synthetic-target-failure', { name: error.name, message: error.message, stack: error.stack });
          throw error;
        }
        await ctx.storage.put('synthetic-target-ack-shape', { json: JSON.stringify(result), keys: Reflect.ownKeys(result).map(String),
          plain: Object.getPrototypeOf(result) === Object.prototype, nullPrototype: Object.getPrototypeOf(result) === null });
        if (await ctx.storage.get('synthetic-lose-ack')) {
          await ctx.storage.delete('synthetic-lose-ack');
          throw Error('synthetic lost acknowledgement after target durable initialization');
        }
        return result;
      } });
  }
  reserve(value) { return this.directory.reserve(value); }
  provision(value) { return this.directory.provision(value); }
  lookupReady(id) { return this.directory.lookupReady(id); }
  lookupReservation(scope) { return this.directory.lookupReservation(scope); }
  async loseNextAck() { await this.ctx.storage.put('synthetic-lose-ack', true); }
  async state() {
    const native = this.ctx.storage.sql;
    const exists = native.exec("SELECT name FROM sqlite_master WHERE type='table' AND name='device_bootstrap_directory'").toArray();
    return { ackShape: await this.ctx.storage.get('synthetic-target-ack-shape') ?? null, targetFailure: await this.ctx.storage.get('synthetic-target-failure') ?? null, rows: exists.length ? native.exec('SELECT entitlement_id,provisioning_id,phase,binding_digest FROM device_bootstrap_directory ORDER BY entitlement_id').toArray() : [] };
  }
}

export class SyntheticBootstrapTarget extends DurableObject {
  constructor(ctx, env) { super(ctx, env); }
  async increment(name) {
    const native = this.ctx.storage;
    await native.put(`synthetic-count-${name}`, (await native.get(`synthetic-count-${name}`) ?? 0) + 1);
  }
  async capture(name, value) {
    const native = this.ctx.storage, messages = await native.get(`synthetic-${name}`) ?? [];
    messages.push(value); await native.put(`synthetic-${name}`, messages);
  }
  async open(pinned) {
    if (this.ctx.id.toString() !== this.env.SYNTHETIC_TARGET.idFromName(targetName(pinned.entitlementID)).toString())
      throw Error('synthetic target address mismatch');
    if (this.pinned && JSON.stringify(this.pinned) !== JSON.stringify(pinned)) throw Error('synthetic target binding conflict');
    if (!this.initializing) {
      this.pinned = pinned;
      this.initializing = this.initialize(pinned).catch(error => { this.initializing = undefined; throw error; });
    }
    await this.initializing;
  }
  async initialize(pinned) {
    const native = this.ctx.storage, storage = storageAdapter(native), fixture = JSON.parse(this.env.SYNTHETIC_IDENTITIES);
    const old = await native.get('synthetic-reservation');
    if (old && JSON.stringify(old) !== JSON.stringify(pinned)) throw Error('synthetic persisted scope conflict');
    if (await native.get('synthetic-purchase-state') === undefined) await native.put('synthetic-purchase-state', 'active');
    // These exact synthetic bytes/JWKs are injected once by the Node harness and
    // reused after workerd recreation. Recovery never generates replacement keys.
    const custodyKey = await crypto.subtle.importKey('raw', decode(fixture.custodyBytes, 32), 'AES-GCM', false, ['encrypt', 'decrypt']);
    const bootstrapKey = await crypto.subtle.importKey('jwk', fixture.bootstrapPrivateJWK,
      { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
    const receiptKey = await crypto.subtle.importKey('jwk', fixture.receiptPrivateJWK,
      { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
    const seal = createDeviceBootstrapSealer({ enabled: true, keyID: 'synthetic-custody', key: custodyKey });
    this.mux = createDeviceLicenceAlarmMultiplexer({ enabled: true, storage, physicalAlarm: physicalAdapter(native),
      clockMilliseconds: () => Date.now(), recoveryDelayMilliseconds: 60000,
      handlers: { activation: () => this.target.alarm(), bootstrap: () => this.bootstrap.alarm() } });
    const inspect = async () => {
      await this.increment('authority'); const state = await native.get('synthetic-purchase-state');
      return { ...pinned.scope, state, ownerEmail: state === 'active' ? `purchaser${pinned.scope.orderRef.slice(-1)}@example.invalid` : null };
    };
    const trust = { expectedProfileID: 'synthetic-profile', bootstrapKeyID: 'synthetic-bootstrap',
      bootstrapPublicKey: fixture.bootstrapPublicKey, receiptIssuerKeyIDs: ['synthetic-receipt'] };
    const delivery = createDeviceBootstrapMail({ enabled: true, entitlementID: pinned.entitlementID, trust,
      from: 'support@example.invalid', replyTo: 'support@example.invalid', timeoutMilliseconds: 2000,
      send: async value => { await this.capture('bootstrap-mail', value); return { messageId: 'synthetic-bootstrap-accepted' }; } });
    this.bootstrap = createDeviceBootstrapService({ enabled: true, storage, reservation: pinned,
      selection: { profileID: trust.expectedProfileID, bootstrapKeyID: trust.bootstrapKeyID,
        bootstrapPublicKey: fixture.bootstrapPublicKey, receiptIssuerKeyID: 'synthetic-receipt', receiptIssuerPublicKey: fixture.receiptPublicKey },
      signer: { sign: async payload => { await this.increment('bootstrap-signatures');
        return new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, bootstrapKey, payload)); } },
      custody: { keyID: 'synthetic-custody', seal: seal.seal, open: seal.open }, inspectDeviceAuthority: inspect,
      delivery, alarmStorage: this.mux.bootstrap,
      clocks: { epochMilliseconds: () => Date.now(), monotonicMilliseconds: () => performance.now() },
      operational: { maxPendingOperations: 4, maximumAttemptsPerInvocation: 2, invocationBudgetMilliseconds: 1000,
        prearmDelayMilliseconds: 60000, retryDelayMilliseconds: 60000, continuationDelayMilliseconds: 60000, deliveryLeaseSeconds: 30 } });
    this.ack = await this.bootstrap.provision();
    const binding = this.bootstrap.readActivationBinding();
    const admission = async () => ({ revision: 1, decision: 'allow' });
    this.target = createDeviceLicenceRouteTarget({ enabled: true, lifecycle: { enabled: true, storage, binding,
      inspectDeviceAuthority: inspect,
      issuer: { issuerKeyID: 'synthetic-receipt', issuerPublicKey: fixture.receiptPublicKey,
        sign: async fields => { await this.increment('receipt-signatures'); return signReceipt(fields, receiptKey); } },
      tokenCustody: { sealToken: (value, aad) => seal.seal(value, `synthetic-activation\n${aad}`),
        openToken: (value, aad) => seal.open(value, `synthetic-activation\n${aad}`) },
      admission: { evaluate: admission, readCurrent: async () => ({ entitlementID: pinned.entitlementID, ...await admission() }) },
      mail: { from: 'support@example.invalid', replyTo: 'support@example.invalid', timeoutMilliseconds: 2000,
        send: async message => { await this.capture('activation-mail', message); return { messageId: 'synthetic-activation-accepted' }; } },
      alarmStorage: this.mux.activation,
      clocks: { epochMilliseconds: () => Date.now(), monotonicMilliseconds: () => performance.now() },
      limits: { challengeTTLSeconds: 600, deliveryLeaseSeconds: 30 },
      operational: { maximumAttemptsPerInvocation: 2, maxPendingOperations: 4, invocationBudgetMilliseconds: 1000,
        prearmDelayMilliseconds: 60000, retryDelayMilliseconds: 60000, continuationDelayMilliseconds: 60000 },
      http: { origin, bodyTimeoutMs: 1000 } } });
    this.router = createDeviceLicencePublicRouter({ enabled: true, origin, maxConcurrentRequests: 4,
      lookupTarget: id => id === pinned.entitlementID ? this.target : null });
    await native.put('synthetic-reservation', pinned); await native.sync();
  }
  async existing() {
    const pinned = await this.ctx.storage.get('synthetic-reservation');
    if (!pinned) throw Error('synthetic target not provisioned');
    await this.open(pinned);
  }
  async provision(pinned) { await this.open(pinned); return this.bootstrap.provision(); }
  async requestIssue() { await this.existing(); return this.bootstrap.requestIssue(); }
  async requestRecovery(requestID) { await this.existing(); return this.bootstrap.requestRecovery({ requestID }); }
  async trigger(channels) {
    await this.existing(); const when = Date.now() + 25;
    for (const name of channels) await this.mux[name].setAlarm(when);
    return { when };
  }
  async block() {
    await this.existing(); await this.ctx.storage.put('synthetic-purchase-state', 'blocked');
    return this.bootstrap.refreshAuthority();
  }
  async alarm() { await this.existing(); await this.increment('alarms'); return this.mux.alarm(); }
  async inspect() {
    await this.existing(); const native = this.ctx.storage;
    const one = table => native.sql.exec("SELECT name FROM sqlite_master WHERE type='table' AND name=?", table).toArray().length;
    return { ack: this.ack, objectID: this.ctx.id.toString(), binding: this.bootstrap.readActivationBinding(),
      bootstrap: this.bootstrap.snapshot(), bootstrapSignatures: await native.get('synthetic-count-bootstrap-signatures') ?? 0,
      receiptSignatures: await native.get('synthetic-count-receipt-signatures') ?? 0,
      alarms: await native.get('synthetic-count-alarms') ?? 0, physicalAlarm: await native.getAlarm(),
      bootstrapMail: await native.get('synthetic-bootstrap-mail') ?? [], activationMail: await native.get('synthetic-activation-mail') ?? [],
      logicalAlarms: native.sql.exec('SELECT * FROM device_licence_alarm_channels ORDER BY channel').toArray(),
      authorityStatus: native.sql.exec('SELECT status FROM device_licence_stripe_authority').one().status,
      activationStatus: one('device_licence_meta') ? native.sql.exec('SELECT status FROM device_licence_meta').one().status : null,
      challenges: one('device_licence_challenges') ? native.sql.exec('SELECT count(*) AS n FROM device_licence_challenges').one().n : 0 };
  }
  async fetch(request) {
    const pinned = await this.ctx.storage.get('synthetic-reservation');
    if (!pinned || request.headers.get('X-Cliphoard-Entitlement') !== pinned.entitlementID) return unavailable();
    await this.open(pinned); return this.router.handle(request);
  }
}

let forwarded = 0;
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.origin === controlOrigin) {
      // Fixed synthetic controls, outside the public origin. No raw reservation,
      // recipient, key, selection or provider state is accepted from HTTP input.
      const body = await request.json(), index = body.index;
      if (![1, 2].includes(index)) throw Error('synthetic index required');
      const pinned = reservation(index), directory = directoryStub(env), target = targetStub(env, pinned.entitlementID);
      let result;
      switch (body.action) {
        case 'reserve': result = await directory.reserve(pinned); break;
        case 'provision': result = await directory.provision({ entitlementID: pinned.entitlementID, provisioningID: pinned.provisioningID }); break;
        case 'lose-ack': await directory.loseNextAck(); result = { ok: true }; break;
        case 'directory': result = await directory.state(); break;
        case 'issue': result = await target.requestIssue(); break;
        case 'recovery': result = await target.requestRecovery(token(16, index + 60)); break;
        case 'trigger-bootstrap': result = await target.trigger(['bootstrap']); break;
        case 'trigger-both': result = await target.trigger(['activation', 'bootstrap']); break;
        case 'inspect': result = await target.inspect(); break;
        case 'block': result = await target.block(); break;
        case 'metrics': result = { forwarded }; break;
        default: throw Error('synthetic action rejected');
      }
      return Response.json(result);
    }
    const edge = createDeviceBootstrapDirectoryEdge({ enabled: true, origin, maxConcurrentRequests: 4,
      lookupReady: async id => captureDeviceBootstrapDirectoryRPCAcknowledgement(await directoryStub(env).lookupReady(id)),
      forward: (ready, original) => { forwarded++; return targetStub(env, ready.entitlementID).fetch(original); } });
    return edge.handle(request);
  },
};
