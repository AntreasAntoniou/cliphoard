import { base64url, randomToken, tokenDigest, approvalMessage, signReceipt, canonicalDevice } from '../protocol.mjs';
import { createInMemoryActivationService } from '../in-memory-service.mjs';

// Every signer/device is newly generated in memory. No fixture private key is serialized.
export async function syntheticKey() {
  const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign', 'verify']);
  const publicKey = base64url(await crypto.subtle.exportKey('raw', pair.publicKey));
  return { publicKey, privateKey: pair.privateKey,
    provider: { publicKey: async () => publicKey,
      signProof: async bytes => new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, pair.privateKey, bytes)) } };
}
export async function fixture() {
  const signer = await syntheticKey();
  const device = await syntheticKey();
  const mutable = { now: 1767323045, status: 'active', revision: 1, held: false,
    deliveryFailure: false, authorityFailure: false, signerFailure: false, duringSigning: undefined };
  const id = randomToken(16); const handle = randomToken(32); const mails = []; const admissions = [];
  let signatures = 0;
  const entitlement = () => {
    if (mutable.authorityFailure) throw new Error('synthetic authority outage');
    return { id, revision: mutable.revision, product: 'pro', status: mutable.status, ownerEmail: 'owner@example.invalid' };
  };
  const service = createInMemoryActivationService({ issuerKeyID: 'synthetic-1', issuerPublicKey: signer.publicKey,
    issueReceipt: async fields => {
      if (mutable.signerFailure) throw new Error('synthetic signer outage');
      signatures++;
      const receipt = await signReceipt(fields, signer.privateKey);
      await mutable.duringSigning?.();
      return receipt;
    },
    resolveEntitlement: async candidate => candidate === handle ? entitlement() : undefined,
    readEntitlement: async candidate => candidate === id ? entitlement() : undefined,
    deliverApproval: async mail => { if (mutable.deliveryFailure) throw new Error('synthetic delivery outage'); mails.push(mail); },
    admission: async event => { admissions.push(event); return mutable.held ? 'hold' : 'allow'; },
    clock: () => mutable.now, challengeTTLSeconds: 600,
  });
  const start = async (requestID = randomToken(16), withDevice = device) => service.begin({
    method: 'POST', entitlementHandle: handle, devicePublicKey: withDevice.publicKey, requestID });
  const approval = async (challenge, withDevice = device, token = mails.find(mail => mail.challengeID === challenge.challengeID)?.token,
    approvalRequestID = randomToken(16)) => ({ method: 'POST', challengeID: challenge.challengeID, approvalToken: token,
    approvalRequestID, deviceSignature: base64url(await withDevice.provider.signProof(
      approvalMessage(challenge, await tokenDigest(token), approvalRequestID))) });
  return { signer, device, mutable, id, handle, mails, admissions, service, start, approval,
    signatures: () => signatures, trust: new Map([['synthetic-1', signer.publicKey]]) };
}
export async function receiptFixture() {
  const signer = await syntheticKey(); const device = await syntheticKey();
  const fields = { issuerKeyID: 'synthetic-1', entitlementID: randomToken(16),
    deviceKeyHash: (await canonicalDevice(device.publicKey)).hash, receiptID: randomToken(16), issuedAt: 1767323045 };
  return { signer, device, fields, receipt: await signReceipt(fields, signer.privateKey), trust: new Map([['synthetic-1', signer.publicKey]]) };
}
