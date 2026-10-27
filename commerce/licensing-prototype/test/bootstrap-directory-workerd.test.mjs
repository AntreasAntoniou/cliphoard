import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { approvalMessage, base64url, tokenDigest, verifyReceiptSignature } from '../protocol.mjs';
import { verifyBootstrap } from '../bootstrap-protocol.mjs';
import { origin, reservation, token } from './bootstrap-directory-fixtures.mjs';

const require = createRequire('/Users/antreas/Projects/ditto/commerce/package.json');
const { Miniflare, Log, LogLevel } = require('miniflare');
const sha = value => createHash('sha256').update(value).digest('hex');
async function identity() {
  const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  return { publicKey: base64url(new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey))),
    privateJWK: await crypto.subtle.exportKey('jwk', pair.privateKey), privateKey: pair.privateKey };
}

test('actual SQLite DO directory and two target lifecycles survive lost acknowledgement and recreation with fixed identities', { timeout: 45000 }, async t => {
  const disk = await mkdtemp(join(tmpdir(), 'cliphoard-directory-workerd-'));
  const bootstrap = await identity(), receipt = await identity(), device = await identity();
  const fixture = JSON.stringify({ bootstrapPrivateJWK: bootstrap.privateJWK, bootstrapPublicKey: bootstrap.publicKey,
    receiptPrivateJWK: receipt.privateJWK, receiptPublicKey: receipt.publicKey,
    custodyBytes: base64url(crypto.getRandomValues(new Uint8Array(32))) });
  const fixtureHash = sha(fixture); let runtime, outbound = 0;
  const options = { modules: true, compatibilityDate: '2026-07-01', cf: false,
    scriptPath: fileURLToPath(new URL('./bootstrap-directory-runtime-harness.mjs', import.meta.url)),
    host: '127.0.0.1', port: 0, log: new Log(LogLevel.NONE),
    durableObjects: { SYNTHETIC_DIRECTORY: { className: 'SyntheticBootstrapDirectory', useSQLite: true },
      SYNTHETIC_TARGET: { className: 'SyntheticBootstrapTarget', useSQLite: true } },
    durableObjectsPersist: disk, bindings: { SYNTHETIC_IDENTITIES: fixture },
    outboundService: () => { outbound++; throw Error('synthetic Worker outbound forbidden'); } };
  const call = async (action, index = 1, expectOK = true) => {
    const response = await runtime.dispatchFetch('https://control.synthetic.invalid/fixture', {
      method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ action, index }) });
    if (expectOK && response.status !== 200 && action !== 'directory') t.diagnostic(JSON.stringify(await call('directory')));
    if (expectOK) assert.equal(response.status, 200, `${action}: ${await response.clone().text()}`);
    return expectOK ? response.json() : response;
  };
  const post = async (id, operation, body) => runtime.dispatchFetch(`${origin}/device-licensing/v1/${operation}`, {
    method: 'POST', headers: { 'content-type': 'application/json', 'X-Cliphoard-Entitlement': id }, body: JSON.stringify(body) });
  const waitFor = async (index, predicate) => {
    const until = Date.now() + 6000; let value;
    do { await new Promise(resolve => setTimeout(resolve, 25)); value = await call('inspect', index); }
    while (!predicate(value) && Date.now() < until);
    assert(predicate(value), 'synthetic alarm work did not settle within bound'); return value;
  };
  const descriptor = inspected => inspected.bootstrapMail[0].message.text.match(/CLIPB1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/)[0];
  const trust = { expectedProfileID: 'synthetic-profile', bootstrapKeyID: 'synthetic-bootstrap',
    bootstrapPublicKey: bootstrap.publicKey, receiptIssuerKeyIDs: ['synthetic-receipt'] };
  try {
    runtime = new Miniflare(options);
    const absent = await post(token(16, 99), 'begin', { ignored: true }); assert.equal(absent.status, 503);
    assert.deepEqual((await call('directory')).rows, []); assert.equal((await call('metrics')).forwarded, 0);
    await call('reserve', 1); await call('reserve', 2);
    await call('lose-ack'); const lost = await call('provision', 1, false); assert.notEqual(lost.status, 200);
    assert.equal((await call('directory')).rows.find(r => r.entitlement_id === reservation(1).entitlementID).phase, 'pending');
    const pending = await post(reservation(1).entitlementID, 'begin', { ignored: true }); assert.equal(pending.status, 503);
    assert.equal((await call('metrics')).forwarded, 0);
    const firstTarget = await call('inspect', 1); assert.equal(firstTarget.bootstrap.allocated, 1); assert.equal(firstTarget.bootstrapSignatures, 0);
    const ready = [await call('provision', 1), await call('provision', 2)]; assert.deepEqual(ready[0], firstTarget.ack);
    for (const index of [1, 2]) { await call('issue', index); await call('trigger-bootstrap', index); }
    const mailed = await Promise.all([1, 2].map(index => waitFor(index, state => state.bootstrap.accepted === 1)));
    const descriptors = mailed.map(descriptor);
    const fields = await Promise.all(descriptors.map(value => verifyBootstrap(value, trust)));
    assert.notEqual(mailed[0].objectID, mailed[1].objectID);
    for (let i = 0; i < 2; i++) {
      assert.equal(fields[i].entitlementID, reservation(i + 1).entitlementID);
      assert.equal(mailed[i].bootstrapSignatures, 1); assert.equal(mailed[i].bootstrapMail.length, 1);
      assert.equal(mailed[i].binding.entitlementHandleDigest, await tokenDigest(fields[i].activationHandle));
    }
    const beginBodies = fields.map((value, i) => ({ entitlementHandle: value.activationHandle,
      devicePublicKey: device.publicKey, requestID: token(16, 40 + i) }));
    const challenges = [];
    for (const index of [1, 2]) {
      const response = await post(reservation(index).entitlementID, 'begin', beginBodies[index - 1]);
      assert.equal(response.status, 200); challenges.push((await response.json()).challenge);
      await call('recovery', index);
    }
    const before = await Promise.all([1, 2].map(index => call('inspect', index)));
    for (const state of before) {
      assert.equal(state.bootstrap.pending, 1); assert.equal(state.challenges, 1);
      assert.deepEqual(state.logicalAlarms.map(row => row.channel), ['activation', 'bootstrap']);
      assert(state.physicalAlarm > Date.now());
    }
    await runtime.dispose(); runtime = undefined; assert.equal(sha(options.bindings.SYNTHETIC_IDENTITIES), fixtureHash);
    runtime = new Miniflare(options);
    const recreated = await Promise.all([1, 2].map(index => call('inspect', index)));
    for (let i = 0; i < 2; i++) {
      assert.deepEqual(recreated[i].ack, ready[i]); assert.deepEqual(recreated[i].binding, before[i].binding);
      assert.equal(recreated[i].objectID, before[i].objectID); assert.equal(recreated[i].bootstrapSignatures, 1);
      assert.equal(descriptor(recreated[i]), descriptors[i]);
    }
    for (const index of [1, 2]) await call('trigger-both', index);
    const recovered = await Promise.all([1, 2].map(index => waitFor(index,
      state => state.bootstrap.accepted === 2 && state.activationMail.some(m => m.subject === 'Approve this Mac for Cliphoard Pro'))));
    const approvals = [];
    for (let i = 0; i < 2; i++) {
      assert.equal(recovered[i].bootstrapSignatures, 1); assert.equal(recovered[i].bootstrapMail.length, 2);
      assert.equal(recovered[i].bootstrapMail[1].message.text, recovered[i].bootstrapMail[0].message.text);
      const approvalToken = recovered[i].activationMail.find(m => m.subject === 'Approve this Mac for Cliphoard Pro').text.match(/Approval code:\n([A-Za-z0-9_-]{43})\n/)[1];
      const approvalRequestID = token(16, 50 + i);
      approvals.push({ challengeID: challenges[i].challengeID, approvalToken, approvalRequestID,
        deviceSignature: base64url(new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, device.privateKey,
          approvalMessage(challenges[i], await tokenDigest(approvalToken), approvalRequestID)))) });
    }
    const wrong = await post(reservation(2).entitlementID, 'approve', approvals[0]); assert.notEqual(wrong.status, 200);
    assert.equal((await call('inspect', 2)).receiptSignatures, 0);
    const receipts = [];
    for (let i = 0; i < 2; i++) {
      const response = await post(reservation(i + 1).entitlementID, 'approve', approvals[i]); assert.equal(response.status, 200);
      const value = (await response.json()).receipt; receipts.push(value);
      const verified = await verifyReceiptSignature(value, new Map([['synthetic-receipt', receipt.publicKey]]));
      assert.equal(verified.fields.entitlementID, reservation(i + 1).entitlementID);
    }
    await call('block', 1); const blocked = await call('inspect', 1);
    assert.equal(blocked.authorityStatus, 'blocked'); assert.equal(blocked.bootstrap.blocked, 1);
    assert.equal((await call('directory')).rows.find(r => r.entitlement_id === reservation(1).entitlementID).phase, 'ready');
    const denied = await post(reservation(1).entitlementID, 'approve', approvals[0]); assert.notEqual(denied.status, 200);
    assert.equal((await call('inspect', 1)).receiptSignatures, 1);
    assert.equal(outbound, 0); assert.equal(sha(options.bindings.SYNTHETIC_IDENTITIES), fixtureHash);
    t.diagnostic(JSON.stringify({ directoryObjects: 1, entitlementObjects: 2, sameIdentityFixtureAcrossRecreation: true,
      fixtureSHA256: fixtureHash, readyAckDigests: ready.map(v => v.bindingDigest),
      descriptorSHA256: descriptors.map(sha), receiptSHA256: receipts.map(sha),
      lostAcknowledgementRecovered: true, bothLogicalAlarmHandlersObserved: true,
      readyDirectoryDidNotGrantBlockedPurchase: true, workerOutboundCalls: outbound, cf: false }));
  } finally { await runtime?.dispose(); await rm(disk, { recursive: true, force: true }); }
});
