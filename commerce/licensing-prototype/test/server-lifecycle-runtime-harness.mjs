// Local synthetic entry point only. No shipping manifest references this file.
import { createDeviceLicenceServerLifecycle } from '../server-lifecycle.mjs';
import { syntheticKey } from './fixtures.mjs';
import { randomToken, base64url, approvalMessage, tokenDigest, signReceipt } from '../protocol.mjs';

const origin = 'https://synthetic.invalid';
const scope = Object.freeze({ accountId: 'acct_Synthetic', mode: 'test',
  orderRef: '00000000-0000-4000-8000-000000000001', sessionId: 'cs_test_Synthetic',
  productId: 'prod_Synthetic', priceId: 'price_Synthetic', currency: 'gbp', unitAmount: 1000, taxBehavior: 'inclusive' });

export class SyntheticLifecycle {
  constructor(ctx, env) { this.ctx = ctx; this.env = env; }
  increment(field) {
    this.ctx.storage.sql.exec(`UPDATE synthetic_lifecycle_evidence SET ${field}=${field}+1 WHERE singleton=1`);
  }
  async setup(issuer) {
    if (this.lifecycle) return;
    const native = this.ctx.storage, fixture = await native.get('synthetic-fixture');
    if (!fixture) throw Error('synthetic fixture missing');
    native.sql.exec(`CREATE TABLE IF NOT EXISTS synthetic_lifecycle_evidence
      (singleton INTEGER PRIMARY KEY, authority_reads INTEGER, admission_reads INTEGER,
       signatures INTEGER, approval_sends INTEGER, receipt_sends INTEGER, receipt_matches INTEGER,
       alarms INTEGER, pre_alarm_null INTEGER, errors INTEGER)`);
    native.sql.exec('INSERT OR IGNORE INTO synthetic_lifecycle_evidence VALUES(1,0,0,0,0,0,0,0,0,0)');
    const readDecision = async () => ({ revision: 1, decision: 'allow' });
    const storage = { sql: { exec: (query, ...args) => native.sql.exec(query, ...args) },
      transactionSync: callback => native.transactionSync(callback), sync: () => native.sync() };
    const alarmStorage = { getAlarm: () => native.getAlarm(), setAlarm: time => native.setAlarm(time),
      deleteAlarm: () => native.deleteAlarm(), sync: () => native.sync() };
    this.lifecycle = createDeviceLicenceServerLifecycle({ enabled: true, storage,
      binding: { entitlementID: this.env.SYNTHETIC_ENTITLEMENT_ID,
        entitlementHandleDigest: fixture.handleDigest, ...scope },
      inspectDeviceAuthority: async () => {
        this.increment('authority_reads'); const state = await native.get('synthetic-purchase-state');
        return { ...scope, state, ownerEmail: state === 'active' ? 'buyer@example.invalid' : null };
      },
      issuer: { issuerKeyID: 'synthetic-runtime', issuerPublicKey: fixture.issuerPublicKey,
        sign: async fields => {
          if (!issuer) throw Error('synthetic private issuer unavailable after recreation');
          this.increment('signatures'); return signReceipt(fields, issuer.privateKey);
        } },
      // Deliberately transparent test custody. No real sealing key or provider.
      tokenCustody: { sealToken: async token => `synthetic.${token}`,
        openToken: async sealed => {
          if (!sealed.startsWith('synthetic.')) throw Error('synthetic envelope invalid');
          return sealed.slice('synthetic.'.length);
        } },
      admission: { evaluate: readDecision, readCurrent: async () => {
        this.increment('admission_reads');
        return { entitlementID: this.env.SYNTHETIC_ENTITLEMENT_ID, ...await readDecision() };
      } },
      mail: { from: 'support@example.invalid', replyTo: 'support@example.invalid', timeoutMilliseconds: 1000,
        send: async message => {
          if (message.subject === 'Approve this Mac for Cliphoard Pro') {
            this.increment('approval_sends');
            await native.put('synthetic-token', message.text.match(/Approval code:\n([A-Za-z0-9_-]{43})\n/)[1]);
          } else {
            this.increment('receipt_sends');
            if (message.text.includes(await native.get('synthetic-receipt'))) this.increment('receipt_matches');
          }
          return { messageId: 'synthetic-no-provider' };
        } },
      alarmStorage, clocks: { epochMilliseconds: () => Date.now(), monotonicMilliseconds: () => performance.now() },
      limits: { challengeTTLSeconds: 600, deliveryLeaseSeconds: 30 },
      operational: { maximumAttemptsPerInvocation: 2, maxPendingOperations: 4, invocationBudgetMilliseconds: 1000,
        prearmDelayMilliseconds: 60000, retryDelayMilliseconds: 7000, continuationDelayMilliseconds: 60000 },
      http: { origin, bodyTimeoutMs: 500 },
    });
  }
  async post(route, body) {
    const response = await this.lifecycle.handle(new Request(`${origin}/device-licensing/v1/${route}`, {
      method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
    }));
    if (response.status !== 200) throw Error('synthetic command rejected');
    return response.json();
  }
  async alarm() {
    await this.setup(); this.increment('alarms');
    if (await this.ctx.storage.getAlarm() === null) this.increment('pre_alarm_null');
    try { await this.lifecycle.alarm(); }
    catch { this.increment('errors'); throw Error('synthetic lifecycle alarm rejected'); }
  }
  async status() {
    const sql = this.ctx.storage.sql;
    const pending = sql.exec("SELECT count(*) AS n FROM device_licence_outbox WHERE status IN ('pending','leased')").one().n;
    const cancelled = sql.exec("SELECT count(*) AS n FROM device_licence_outbox WHERE status='cancelled'").one().n;
    return Response.json({ alarm: await this.ctx.storage.getAlarm(), pending, cancelled,
      status: sql.exec('SELECT status FROM device_licence_meta').one().status,
      evidence: sql.exec('SELECT * FROM synthetic_lifecycle_evidence').one() });
  }
  async fetch(request) {
    const { action } = await request.json(), native = this.ctx.storage;
    if (action === 'prepare') {
      const issuer = await syntheticKey(), device = await syntheticKey(), handle = randomToken(32);
      await native.put('synthetic-fixture', { handle, handleDigest: await tokenDigest(handle), issuerPublicKey: issuer.publicKey });
      await native.put('synthetic-purchase-state', 'active'); await this.setup(issuer);
      const { challenge } = await this.post('begin', { entitlementHandle: handle,
        devicePublicKey: device.publicKey, requestID: randomToken(16) });
      await this.lifecycle.alarm();
      const approvalToken = await native.get('synthetic-token'), approvalRequestID = randomToken(16);
      const issued = await this.post('approve', { challengeID: challenge.challengeID, approvalToken, approvalRequestID,
        deviceSignature: base64url(await device.provider.signProof(
          approvalMessage(challenge, await tokenDigest(approvalToken), approvalRequestID))) });
      await native.put('synthetic-receipt', issued.receipt);
      return this.status();
    }
    await this.setup();
    if (action === 'recover') await this.lifecycle.recover();
    if (action === 'trigger') await native.setAlarm(Date.now() + 20);
    if (action === 'queue-blocked') {
      const fixture = await native.get('synthetic-fixture'), device = await syntheticKey();
      await this.post('begin', { entitlementHandle: fixture.handle, devicePublicKey: device.publicKey, requestID: randomToken(16) });
      // Change only the fake provider fact. The reconstructed alarm must refresh
      // it; this action deliberately does not publish a ledger observation.
      await native.put('synthetic-purchase-state', 'blocked');
    }
    return this.status();
  }
}
export default {
  fetch(request, env) {
    return env.SYNTHETIC_LIFECYCLE.get(env.SYNTHETIC_LIFECYCLE.idFromName('local-lifecycle-test')).fetch(request);
  },
};
