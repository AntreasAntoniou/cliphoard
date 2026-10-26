import test from 'node:test';
import assert from 'node:assert/strict';
import { randomToken, verifyOffline, base64url, tokenDigest, approvalMessage } from '../protocol.mjs';
import { fixture, syntheticKey } from './fixtures.mjs';
import { emptyActivationState, reduceActivation } from '../activation-state.mjs';
const rejectsCode = (action, code) => assert.rejects(action, error => error.code === code);

test('verified purchaser receives private email token; begin returns bound public challenge only', async () => {
  const f = await fixture(); const { challenge } = await f.start();
  assert.equal(f.mails.length, 1); assert.equal(f.mails[0].to, 'owner@example.invalid');
  assert.equal(challenge.entitlementID, f.id); assert.equal(challenge.devicePublicKey, f.device.publicKey);
  assert.equal(challenge.expiresAt, f.mutable.now + 600);
  assert.ok(!JSON.stringify(challenge).includes(f.mails[0].token));
  const issued = await f.service.approve(await f.approval(challenge));
  assert.equal(issued.code, 'issued');
  assert.equal((await verifyOffline(issued.receipt, f.device.provider, f.trust)).entitlementID, f.id);
  assert.deepEqual(f.service.snapshot(), { revision: 2, pending: 0, issued: 1 });
  for (const event of f.admissions) assert.deepEqual(Object.keys(event).sort(), ['deviceKeyHash', 'entitlementID', 'now', 'phase']);
});

test('mail scanner GET/HEAD cannot approve or consume a token', async () => {
  const f = await fixture(); const { challenge } = await f.start(); const approval = await f.approval(challenge);
  const before = f.service.snapshot();
  for (const method of ['GET', 'HEAD']) {
    assert.equal(f.service.preview({ method }).code, 'confirmation_required');
    await rejectsCode(() => f.service.approve({ ...approval, method }), 'method_not_allowed');
  }
  assert.deepEqual(f.service.snapshot(), before);
  assert.equal((await f.service.approve(approval)).code, 'issued');
});

test('token alone, device possession alone, different key and swapped challenge are rejected', async () => {
  const f = await fixture(); const { challenge } = await f.start();
  const wrongToken = await f.approval(challenge, f.device, randomToken(32));
  await rejectsCode(() => f.service.approve(wrongToken), 'approval_rejected');
  const wrongKey = await f.approval(challenge, await syntheticKey());
  await rejectsCode(() => f.service.approve(wrongKey), 'approval_rejected');
  const missingProof = { ...await f.approval(challenge), deviceSignature: base64url(new Uint8Array(64)) };
  await rejectsCode(() => f.service.approve(missingProof), 'approval_rejected');
  const second = (await f.start()).challenge;
  const swapped = { ...await f.approval(challenge), challengeID: second.challengeID };
  await rejectsCode(() => f.service.approve(swapped), 'approval_rejected');
  assert.equal(f.service.snapshot().issued, 0); assert.equal(f.signatures(), 0);
});

test('proof binds purpose, exact version, expiry, entitlement, nonce, public key and approval request', async () => {
  const f = await fixture(); const { challenge } = await f.start();
  const input = await f.approval(challenge);
  for (const [field, value] of [['entitlementID', randomToken(16)], ['nonce', randomToken(32)],
    ['expiresAt', challenge.expiresAt + 1], ['deviceKeyHash', randomToken(32)], ['devicePublicKey', (await syntheticKey()).publicKey]]) {
    const changed = { ...challenge, [field]: value };
    const signed = await f.device.provider.signProof(approvalMessage(changed, await tokenDigest(input.approvalToken), input.approvalRequestID));
    await rejectsCode(() => f.service.approve({ ...input, deviceSignature: base64url(signed) }), 'approval_rejected');
  }
  for (const changed of [{ ...challenge, version: 2 }, { ...challenge, purpose: 'other' }, { ...challenge, extra: 1 }]) {
    assert.throws(() => approvalMessage(changed, randomToken(32), randomToken(16)));
  }
  await rejectsCode(() => f.service.approve({ ...input, approvalRequestID: randomToken(16) }), 'approval_rejected');
});

test('single-use approval permits same semantic request retry but rejects replay under new request ID', async () => {
  const f = await fixture(); const { challenge } = await f.start(); const approval = await f.approval(challenge);
  const first = await f.service.approve(approval);
  const repeated = await f.service.approve(approval);
  assert.equal(repeated.code, 'already_issued'); assert.equal(first.receipt, repeated.receipt);
  await rejectsCode(async () => f.service.approve(await f.approval(challenge)), 'challenge_consumed');
  assert.equal(f.signatures(), 1); assert.equal(f.service.snapshot().issued, 1);
});

test('pending expiry is exact; backward time and expiry during signing fail closed', async () => {
  for (const caseName of ['boundary', 'backward', 'during-signing']) {
    const f = await fixture(); const { challenge } = await f.start(); const input = await f.approval(challenge);
    if (caseName === 'boundary') f.mutable.now = challenge.expiresAt;
    if (caseName === 'backward') f.mutable.now--;
    if (caseName === 'during-signing') f.mutable.duringSigning = () => { f.mutable.now = challenge.expiresAt; };
    await rejectsCode(() => f.service.approve(input), 'challenge_expired');
    assert.equal(f.service.snapshot().issued, 0);
  }
});

test('refund/dispute blocks new challenge and pending approval without revoking an old offline receipt', async () => {
  for (const status of ['refunded', 'disputed', 'unknown']) {
    const f = await fixture(); const first = (await f.start()).challenge;
    const receipt = (await f.service.approve(await f.approval(first))).receipt;
    const pending = (await f.start()).challenge; const approval = await f.approval(pending);
    f.mutable.status = status;
    await rejectsCode(() => f.start(), 'entitlement_ineligible');
    await rejectsCode(() => f.service.approve(approval), 'entitlement_ineligible');
    assert.equal((await verifyOffline(receipt, f.device.provider, f.trust)).entitlementID, f.id);
    assert.equal(f.service.snapshot().issued, 1);
  }
});

test('refund or entitlement revision change during signing wins before receipt commit', async () => {
  for (const mutation of [f => { f.mutable.status = 'refunded'; }, f => { f.mutable.revision++; }]) {
    const f = await fixture(); const { challenge } = await f.start();
    f.mutable.duringSigning = () => mutation(f);
    await rejectsCode(async () => f.service.approve(await f.approval(challenge)), 'entitlement_ineligible');
    assert.equal(f.service.snapshot().issued, 0);
  }
});

test('admission holds pause only new approvals; no fixed device count is imposed', async () => {
  const f = await fixture(); const { challenge } = await f.start(); const approval = await f.approval(challenge);
  f.mutable.held = true;
  await rejectsCode(() => f.start(), 'held_for_review');
  await rejectsCode(() => f.service.approve(approval), 'held_for_review');
  f.mutable.held = false;
  const receipt = (await f.service.approve(approval)).receipt;
  for (let index = 0; index < 12; index++) {
    const device = await syntheticKey(); const next = (await f.start(randomToken(16), device)).challenge;
    assert.equal((await f.service.approve(await f.approval(next, device))).code, 'issued');
  }
  f.mutable.held = true;
  assert.equal((await verifyOffline(receipt, f.device.provider, f.trust)).entitlementID, f.id);
  assert.equal(f.service.snapshot().issued, 13);
});

test('concurrent duplicate begin/approve creates one challenge, email, signature and receipt', async () => {
  const f = await fixture(); const requestID = randomToken(16);
  const starts = await Promise.all(Array.from({ length: 8 }, () => f.start(requestID)));
  for (const result of starts) assert.deepEqual(result, starts[0]);
  assert.equal(f.mails.length, 1); assert.equal(f.service.snapshot().pending, 1);
  await rejectsCode(async () => f.start(requestID, await syntheticKey()), 'idempotency_conflict');
  const approval = await f.approval(starts[0].challenge);
  const results = await Promise.all(Array.from({ length: 8 }, () => f.service.approve(approval)));
  assert.equal(results.filter(result => result.code === 'issued').length, 1);
  assert.equal(new Set(results.map(result => result.receipt)).size, 1);
  assert.equal(f.signatures(), 1);
});

test('concurrent different approval request IDs consume once', async () => {
  const f = await fixture(); const { challenge } = await f.start();
  const requests = await Promise.all(Array.from({ length: 6 }, () => f.approval(challenge)));
  const outcomes = await Promise.allSettled(requests.map(input => f.service.approve(input)));
  assert.equal(outcomes.filter(result => result.status === 'fulfilled').length, 1);
  for (const result of outcomes.filter(result => result.status === 'rejected')) assert.equal(result.reason.code, 'challenge_consumed');
  assert.equal(f.signatures(), 1);
});

test('authority/signer outage does not consume pending approval and permits retry', async () => {
  for (const failure of ['authorityFailure', 'signerFailure']) {
    const f = await fixture(); const { challenge } = await f.start(); const approval = await f.approval(challenge);
    f.mutable[failure] = true;
    await assert.rejects(() => f.service.approve(approval));
    assert.equal(f.service.snapshot().issued, 0);
    f.mutable[failure] = false;
    assert.equal((await f.service.approve(approval)).code, 'issued');
  }
});

test('delivery failure is reported honestly and has no automatic duplicate email or activation', async () => {
  const f = await fixture(); const requestID = randomToken(16); f.mutable.deliveryFailure = true;
  await rejectsCode(() => f.start(requestID), 'delivery_unavailable');
  assert.equal(f.mails.length, 0); assert.equal(f.service.snapshot().issued, 0);
  await f.start(requestID); // no resend; production needs a transactional outbox
  assert.equal(f.mails.length, 0);
  f.mutable.deliveryFailure = false;
  await f.start(); assert.equal(f.mails.length, 1);
});

test('malformed oversized commands and caller-supplied entitlement/approval facts fail', async () => {
  const f = await fixture();
  await assert.rejects(() => f.service.begin({ method: 'POST', entitlementHandle: f.handle,
    devicePublicKey: f.device.publicKey, requestID: randomToken(16), entitlement: { status: 'active' } }));
  await assert.rejects(() => f.service.begin({ method: 'POST', entitlementHandle: 'A'.repeat(8192),
    devicePublicKey: f.device.publicKey, requestID: randomToken(16) }));
  const { challenge } = await f.start(); const input = await f.approval(challenge);
  for (const changed of [{ ...input, tokenMatches: true }, { ...input, deviceSignature: 'A'.repeat(8192) },
    { ...input, approvalToken: input.approvalToken + '=' }, { ...input, challengeID: '__proto__' }]) {
    await assert.rejects(() => f.service.approve(changed));
  }
  assert.equal(f.service.snapshot().issued, 0);
});

test('pure reducer is deterministic and rejects stale revision without mutating prior state', () => {
  const state = Object.freeze(emptyActivationState());
  assert.equal(reduceActivation(state, { type: 'preview', method: 'GET' }).state, state);
  const event = { type: 'approve', expectedRevision: 2, method: 'POST' };
  const first = reduceActivation(state, event); const second = reduceActivation(state, event);
  assert.deepEqual(first, second); assert.equal(first.state, state); assert.equal(first.result.code, 'revision_conflict');
});
