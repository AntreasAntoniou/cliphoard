// Test-only local workerd entry point. No deployment manifest imports this file.
import { createSqliteActivationService } from '../sqlite-service.mjs';
import { syntheticKey } from './fixtures.mjs';
import { randomToken, base64url, decode, tokenDigest, approvalMessage, signReceipt } from '../protocol.mjs';

export class SyntheticSqliteLedger {
  constructor(ctx, env) { this.ctx = ctx; this.env = env; }
  async fetch(request) {
    const input = await request.json(), id = this.env.SYNTHETIC_ENTITLEMENT_ID;
    const authority = async () => ({ id, product: 'pro', status: 'active', revision: 1, ownerEmail: 'owner@example.invalid' });
    const unavailable = async () => { throw new Error('test adapter unavailable'); };
    const common = { storage: this.ctx.storage, entitlementID: id, issuerKeyID: 'synthetic-1',
      challengeTTLSeconds: 600, deliveryLeaseSeconds: 30, clock: () => input.now,
      resolveEntitlement: authority, readEntitlement: authority,
      admission: async () => ({ revision: 1, decision: 'allow' }) };
    if (input.action === 'resume') {
      let delivered;
      const service = createSqliteActivationService({ ...common, issuerPublicKey: input.issuer,
        issueReceipt: unavailable, sealToken: unavailable, openToken: unavailable, deliverApproval: unavailable,
        deliverReceipt: async mail => { delivered = mail; return { accepted: true }; } });
      const result = await service.deliverOne();
      return Response.json({ result, receipt: delivered?.receipt, deliveryID: delivered?.deliveryID, snapshot: service.snapshot() });
    }
    if (input.action !== 'exercise') return new Response(null, { status: 404 });
    const signer = await syntheticKey(), device = await syntheticKey();
    const sealKey = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
    let failInsert = true, approvalMail, receiptMail, signatures = 0;
    const storage = {
      sql: { exec: (query, ...bindings) => {
        if (failInsert && query.includes('INSERT INTO device_licence_outbox')) { failInsert = false; throw new Error('synthetic rollback'); }
        return this.ctx.storage.sql.exec(query, ...bindings);
      } },
      transactionSync: callback => this.ctx.storage.transactionSync(callback), sync: () => this.ctx.storage.sync(),
    };
    const service = createSqliteActivationService({ ...common, storage, issuerPublicKey: signer.publicKey,
      issueReceipt: async fields => { signatures++; return signReceipt(fields, signer.privateKey); },
      sealToken: async (token, aad) => {
        const iv = crypto.getRandomValues(new Uint8Array(12));
        const encrypted = await crypto.subtle.encrypt({ name: 'AES-GCM', iv, additionalData: new TextEncoder().encode(aad) },
          sealKey, new TextEncoder().encode(token));
        return base64url(new Uint8Array([...iv, ...new Uint8Array(encrypted)]));
      },
      openToken: async (sealed, aad) => {
        const bytes = decode(sealed, undefined, 2048);
        return new TextDecoder().decode(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: bytes.slice(0, 12),
          additionalData: new TextEncoder().encode(aad) }, sealKey, bytes.slice(12)));
      },
      deliverApproval: async mail => { approvalMail = mail; return { accepted: true }; },
      deliverReceipt: async mail => { receiptMail = mail; throw new Error('synthetic lost acknowledgement'); },
    });
    const begin = { method: 'POST', entitlementHandle: randomToken(32), requestID: randomToken(16), devicePublicKey: device.publicKey };
    let rollbackRejected = false;
    try { await service.begin(begin); } catch { rollbackRejected = true; }
    const rollbackEmpty = service.snapshot().challenges === 0 && service.snapshot().pending === 0;
    const { challenge } = await service.begin(begin);
    await service.deliverOne();
    const approvalRequestID = randomToken(16);
    const approval = { method: 'POST', challengeID: challenge.challengeID, approvalRequestID,
      approvalToken: approvalMail.token, deviceSignature: base64url(await device.provider.signProof(
        approvalMessage(challenge, await tokenDigest(approvalMail.token), approvalRequestID))) };
    const [first, duplicate] = await Promise.all([service.approve(approval), service.approve(approval)]);
    const delivery = await service.deliverOne();
    return Response.json({ rollbackRejected, rollbackEmpty, duplicateSame: first.receipt === duplicate.receipt,
      signatures, delivery, receipt: first.receipt, deliveryID: receiptMail.deliveryID,
      issuer: signer.publicKey, snapshot: service.snapshot() });
  }
}

export default {
  fetch(request, env) { return env.SYNTHETIC_LEDGER.get(env.SYNTHETIC_LEDGER.idFromName('local-test')).fetch(request); },
};
