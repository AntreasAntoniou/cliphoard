// Local synthetic test entry point only; no deployment manifest references it.
import { createSqliteActivationService } from '../sqlite-service.mjs';
import { createNativeMailDelivery } from '../native-mail.mjs';
import { createDeliveryRunner } from '../delivery-runner.mjs';
import { syntheticKey } from './fixtures.mjs';
import { randomToken, base64url, decode, approvalMessage, tokenDigest, signReceipt } from '../protocol.mjs';

export class SyntheticDeliveryLedger {
  constructor(ctx, env) { this.ctx = ctx; this.env = env; }
  async setup(synthetic) {
    if (this.runner) return;
    const { storage } = this.ctx, id = this.env.SYNTHETIC_ENTITLEMENT_ID;
    const publicKey = synthetic?.issuer.publicKey ?? await storage.get('synthetic-public-issuer');
    if (!publicKey) throw new Error('synthetic state missing');
    storage.sql.exec(`CREATE TABLE IF NOT EXISTS synthetic_delivery_evidence
      (singleton INTEGER PRIMARY KEY, alarms INTEGER, pre_alarm_null INTEGER, receipt_sends INTEGER)`);
    storage.sql.exec('INSERT OR IGNORE INTO synthetic_delivery_evidence VALUES(1,0,0,0)');
    const unavailable = async () => { throw new Error('synthetic key unavailable after recreation'); };
    const fact = () => ({ id, product: 'pro', revision: 1, status: 'active', ownerEmail: 'owner@example.invalid' });
    const mail = createNativeMailDelivery({ enabled: true, entitlementID: id,
      trustedIssuers: new Map([['synthetic-mail', publicKey]]), from: 'support@example.invalid',
      replyTo: 'support@example.invalid', timeoutMilliseconds: 1000,
      send: async message => {
        if (message.subject === 'Your Mac approval for Cliphoard Pro')
          storage.sql.exec('UPDATE synthetic_delivery_evidence SET receipt_sends=receipt_sends+1 WHERE singleton=1');
        return { messageId: 'synthetic-local-acceptance' };
      } });
    this.service = createSqliteActivationService({ storage, entitlementID: id,
      issuerKeyID: 'synthetic-mail', issuerPublicKey: publicKey,
      challengeTTLSeconds: 600, deliveryLeaseSeconds: 30, clock: () => Math.floor(Date.now() / 1000),
      resolveEntitlement: async () => fact(), readEntitlement: async () => fact(),
      readAuthorityFence: () => ({ id, revision: 1, status: 'active' }),
      admission: async () => ({ revision: 1, decision: 'allow' }),
      issueReceipt: synthetic ? fields => signReceipt(fields, synthetic.issuer.privateKey) : unavailable,
      sealToken: synthetic ? async (token, aad) => {
        const iv = crypto.getRandomValues(new Uint8Array(12));
        const encrypted = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv,
          additionalData: new TextEncoder().encode(aad) }, synthetic.sealKey, new TextEncoder().encode(token)));
        return base64url(new Uint8Array([...iv, ...encrypted]));
      } : unavailable,
      openToken: synthetic ? async (sealed, aad) => {
        const bytes = decode(sealed, undefined, 2048);
        return new TextDecoder().decode(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: bytes.slice(0, 12),
          additionalData: new TextEncoder().encode(aad) }, synthetic.sealKey, bytes.slice(12)));
      } : unavailable,
      deliverApproval: context => { this.approval = context; return mail.deliverApproval(context); },
      deliverReceipt: context => mail.deliverReceipt(context),
    });
    this.runner = createDeliveryRunner({ enabled: true,
      makeService: () => ({ ...this.service, approve: async input => {
        const value = await this.service.approve(input);
        if (this.loseAcknowledgement) throw new Error('synthetic post-commit interruption');
        return value;
      } }), mail, clockMilliseconds: () => Date.now(), monotonicMilliseconds: () => performance.now(),
      alarmStorage: { getAlarm: () => storage.getAlarm(), setAlarm: time => storage.setAlarm(time),
        deleteAlarm: () => storage.deleteAlarm(), sync: () => storage.sync() },
      operational: { maximumAttemptsPerInvocation: 1, maxPendingOperations: 4, invocationBudgetMilliseconds: 2000,
        prearmDelayMilliseconds: 60000, retryDelayMilliseconds: 60000, continuationDelayMilliseconds: 60000 },
    });
  }
  async alarm() {
    await this.setup();
    const wasNull = await this.ctx.storage.getAlarm() === null;
    this.ctx.storage.sql.exec('UPDATE synthetic_delivery_evidence SET alarms=alarms+1,pre_alarm_null=? WHERE singleton=1', Number(wasNull));
    await this.runner.alarm();
  }
  async fetch(request) {
    const { action } = await request.json();
    if (action === 'prepare') {
      const issuer = await syntheticKey(), device = await syntheticKey();
      const sealKey = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
      await this.ctx.storage.put('synthetic-public-issuer', issuer.publicKey);
      await this.setup({ issuer, sealKey });
      const { challenge } = await this.runner.begin({ method: 'POST', entitlementHandle: randomToken(32),
        requestID: randomToken(16), devicePublicKey: device.publicKey });
      await this.runner.alarm();
      const approvalRequestID = randomToken(16), token = this.approval.token;
      this.loseAcknowledgement = true;
      let interrupted = false;
      try { await this.runner.approve({ method: 'POST', challengeID: challenge.challengeID, approvalToken: token,
        approvalRequestID, deviceSignature: base64url(await device.provider.signProof(
          approvalMessage(challenge, await tokenDigest(token), approvalRequestID))) }); }
      catch { interrupted = true; }
      this.loseAcknowledgement = false;
      return Response.json({ interrupted, alarm: await this.ctx.storage.getAlarm(), snapshot: this.service.snapshot() });
    }
    await this.setup();
    if (action === 'recover') await this.runner.recover();
    if (action === 'trigger') await this.ctx.storage.setAlarm(Date.now() + 20);
    return Response.json({ alarm: await this.ctx.storage.getAlarm(), snapshot: this.service.snapshot(),
      evidence: this.ctx.storage.sql.exec('SELECT * FROM synthetic_delivery_evidence').one() });
  }
}
export default {
  fetch(request, env) {
    return env.SYNTHETIC_DELIVERY.get(env.SYNTHETIC_DELIVERY.idFromName('local-delivery-test')).fetch(request);
  },
};
