import test from 'node:test';
import assert from 'node:assert/strict';
import { createNativeMailDelivery } from '../native-mail.mjs';
import { syntheticKey } from './fixtures.mjs';
import { gate } from './delivery-fixtures.mjs';
import { canonicalDevice, randomToken, signReceipt } from '../protocol.mjs';

function timers() {
  const jobs = new Map(); let next = 0;
  return { setTimer: callback => { const id = ++next; jobs.set(id, callback); return id; },
    clearTimer: id => jobs.delete(id), fire() { for (const callback of [...jobs.values()]) callback(); } };
}
async function fixture() {
  const issuer = await syntheticKey(), device = await syntheticKey();
  const id = randomToken(16), challengeID = randomToken(16), sent = [], clock = timers();
  let authorizations = 0;
  const context = { to: 'owner@example.invalid', deliveryID: `${challengeID}.approval`, challengeID,
    entitlementID: id, entitlementRevision: 1, deviceKeyHash: (await canonicalDevice(device.publicKey)).hash,
    authorizeDispatch: () => { authorizations++; } };
  const options = { enabled: true, entitlementID: id, trustedIssuers: new Map([['synthetic-mail', issuer.publicKey]]),
    from: 'support@example.invalid', replyTo: 'support@example.invalid', timeoutMilliseconds: 100,
    send: async message => { sent.push(message); return { messageId: 'synthetic-message' }; },
    setTimer: clock.setTimer, clearTimer: clock.clearTimer };
  const approval = { ...context, token: randomToken(32), expiresAt: 1767323645 };
  const receipt = async (changes = {}) => ({ ...context, deliveryID: `${challengeID}.receipt`,
    receipt: await signReceipt({ issuerKeyID: 'synthetic-mail', entitlementID: id, deviceKeyHash: context.deviceKeyHash,
      receiptID: randomToken(16), issuedAt: 1767323045, ...changes }, issuer.privateKey) });
  return { issuer, options, approval, receipt, sent, clock, get authorizations() { return authorizations; } };
}

test('default off does not inspect dependencies or inputs', async () => {
  let reads = 0;
  const mail = createNativeMailDelivery({ get send() { reads++; throw new Error('private'); } });
  const hostile = new Proxy({}, { ownKeys() { reads++; throw new Error('private'); } });
  await assert.rejects(mail.deliverApproval(hostile), { code: 'delivery_disabled' });
  await assert.rejects(mail.deliverReceipt(hostile), { code: 'delivery_disabled' });
  assert.equal(mail.hasUnsettledSend(), false); assert.equal(reads, 0);
});

test('approval and receipt use one structured recipient and exact deterministic private content', async () => {
  const f = await fixture(), mail = createNativeMailDelivery(f.options), receipt = await f.receipt();
  assert.deepEqual(await mail.deliverApproval(f.approval), { accepted: true });
  await mail.deliverApproval(f.approval); await mail.deliverReceipt(receipt);
  assert.deepEqual(f.sent[0], f.sent[1]);
  assert.deepEqual(Object.keys(f.sent[0]).sort(), ['from','to','replyTo','subject','text'].sort());
  assert.equal(f.sent[0].to, f.approval.to); assert.equal(f.sent[0].text.includes(f.approval.token), true);
  assert.equal(f.sent[2].text.includes(receipt.receipt), true);
  assert.equal(f.sent[0].text.includes('https://'), false);
  for (const mail of f.sent) {
    assert.equal(mail.text.includes(f.approval.entitlementID), false);
    assert.equal(mail.subject.includes(f.approval.token), false);
  }
  assert.equal(f.authorizations, 3);
});

test('recipient injection, wrong scope, malformed IDs, extras and accessors cause no provider call', async () => {
  const f = await fixture(), mail = createNativeMailDelivery(f.options); let reads = 0;
  for (const input of [
    { ...f.approval, to: 'owner@example.invalid\r\nBcc: other@example.invalid' },
    { ...f.approval, to: ['owner@example.invalid'] },
    { ...f.approval, entitlementID: randomToken(16) },
    { ...f.approval, entitlementRevision: 0 },
    { ...f.approval, deliveryID: `${randomToken(16)}.approval` },
    { ...f.approval, token: f.approval.token + '=' },
    { ...f.approval, expiresAt: 0 },
    { ...f.approval, bcc: 'other@example.invalid' },
    { ...f.approval, get to() { reads++; return 'owner@example.invalid'; } },
  ]) await assert.rejects(mail.deliverApproval(input), { code: 'delivery_rejected' });
  assert.equal(reads, 0); assert.equal(f.sent.length, 0); assert.equal(f.authorizations, 0);
});

test('receipt signature, issuer, device, entitlement and strict protocol are verified before sending', async () => {
  const f = await fixture(), mail = createNativeMailDelivery(f.options), valid = await f.receipt();
  const changed = valid.receipt.slice(0, -1) + (valid.receipt.endsWith('A') ? 'B' : 'A');
  for (const input of [await f.receipt({ entitlementID: randomToken(16) }),
    await f.receipt({ deviceKeyHash: randomToken(32) }), await f.receipt({ issuerKeyID: 'unknown' }),
    { ...valid, receipt: changed }, { ...valid, receipt: valid.receipt.replace('CLIPD1.', 'CLIP1-') },
    { ...valid, receipt: 'x'.repeat(1025) }]) {
    await assert.rejects(mail.deliverReceipt(input), { code: 'delivery_unavailable' });
  }
  assert.equal(f.sent.length, 0); assert.equal(f.authorizations, 0);
});

test('late authority/lease denial and asynchronous grant never reach native send', async () => {
  const f = await fixture(), receipt = await f.receipt(), mail = createNativeMailDelivery(f.options);
  let checks = 0;
  await assert.rejects(mail.deliverReceipt({ ...receipt, authorizeDispatch() {
    checks++; throw new Error('private@example.invalid token');
  } }), { code: 'delivery_unavailable', message: 'delivery_unavailable' });
  await assert.rejects(mail.deliverApproval({ ...f.approval, authorizeDispatch: () => Promise.resolve() }),
    { code: 'delivery_unavailable' });
  assert.equal(checks, 1); assert.equal(f.sent.length, 0);
});

test('native result is strict and provider exceptions cannot escape in errors', async () => {
  const f = await fixture(); let reads = 0;
  const responses = [null, { messageId: '' }, { messageId: 'x'.repeat(256) },
    { messageId: 'ok', other: 'private' }, { success: true },
    { get messageId() { reads++; throw new Error('private'); } }, { messageId: 'bad\nheader' }];
  for (const response of responses) {
    const mail = createNativeMailDelivery({ ...f.options, send: async () => response });
    await assert.rejects(mail.deliverApproval(f.approval), { code: 'delivery_unavailable', message: 'delivery_unavailable' });
  }
  const mail = createNativeMailDelivery({ ...f.options, send: async () => { throw new Error('private@example.invalid bearer-token'); } });
  await assert.rejects(mail.deliverApproval(f.approval), { code: 'delivery_unavailable', message: 'delivery_unavailable' });
  assert.equal(reads, 0);
});

test('deadline retains busy slot until underlying send settles; concurrent and later calls do not overlap', async () => {
  const f = await fixture(), pending = gate(), entered = gate(); let sends = 0;
  const mail = createNativeMailDelivery({ ...f.options, send: () => { sends++; entered.resolve(); return pending.promise; } });
  const first = mail.deliverApproval(f.approval);
  await entered.promise;
  await assert.rejects(mail.deliverApproval(f.approval), { code: 'delivery_busy' });
  f.clock.fire();
  await assert.rejects(first, { code: 'delivery_timeout' });
  assert.equal(mail.hasUnsettledSend(), true);
  for (let i = 0; i < 5; i++) await assert.rejects(mail.deliverApproval(f.approval), { code: 'delivery_busy' });
  assert.equal(sends, 1);
  pending.resolve({ messageId: 'accepted-after-timeout' });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(mail.hasUnsettledSend(), false);
  await mail.deliverApproval(f.approval);
  assert.equal(sends, 2);
});

test('configuration snapshots issuer trust and rejects unsafe senders', async () => {
  const f = await fixture(), mail = createNativeMailDelivery(f.options), receipt = await f.receipt();
  f.options.trustedIssuers.clear();
  await mail.deliverReceipt(receipt);
  assert.throws(() => createNativeMailDelivery({ ...f.options, from: 'ok@example.invalid\nother' }),
    { code: 'delivery_configuration' });
});
