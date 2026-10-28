import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { verifyBootstrap } from '../bootstrap-protocol.mjs';
import { syntheticMaterial } from './host-key-consumer-fixtures.mjs';
const require = createRequire('/Users/antreas/Projects/ditto/commerce/package.json');
const { Miniflare, Log, LogLevel } = require('miniflare');
test('factory hosts persist original identity, exact recovery descriptor and payment fences across workerd recreation', { timeout: 45000 }, async () => {
  const disk = await mkdtemp(join(tmpdir(), 'cliphoard-host-workerd-')); let runtime, outbound = 0;
  const options = { modules: true, compatibilityDate: '2026-07-01', cf: false,
    scriptPath: fileURLToPath(new URL('./durable-object-hosts-runtime-harness.mjs', import.meta.url)),
    host: '127.0.0.1', port: 0, log: new Log(LogLevel.NONE),
    durableObjects: { SYNTHETIC_DIRECTORY: { className: 'SyntheticHostDirectory', useSQLite: true },
      SYNTHETIC_TARGET: { className: 'SyntheticHostTarget', useSQLite: true }, SYNTHETIC_ORDER: { className: 'SyntheticHostOrder', useSQLite: true } },
    durableObjectsPersist: disk, outboundService: () => { outbound++; throw Error('Worker outbound forbidden'); } };
  const call = async (action, ok = true) => {
    const response = await runtime.dispatchFetch('https://control.synthetic.invalid', { method: 'POST', body: JSON.stringify({ action }) });
    if (ok) assert.equal(response.status, 200, `${action}: ${await response.clone().text()}`);
    return ok ? response.json() : response;
  };
  const token = n => Buffer.alloc(16, n).toString('base64url');
  const publicPost = (id, auth, body) => runtime.dispatchFetch('https://host.synthetic.invalid/device-licensing/v1/begin', {
    method: 'POST', headers: { 'content-type': 'application/json', 'X-Cliphoard-Entitlement': id, 'X-Synthetic-Authority': auth }, body: JSON.stringify(body) });
  const descriptor = state => JSON.stringify(state.mail[0]).match(/CLIPB1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/)[0];
  try {
    runtime = new Miniflare(options);
    assert.equal((await publicPost(token(1), 'denied', {})).status, 503);
    assert.equal((await publicPost(token(99), 'fixture-only', {})).status, 503);
    const purchase = await call('purchase'); await call('trigger'); const before = await call('inspect');
    assert.equal(before.mail.length, 1); const setup = descriptor(before), material = syntheticMaterial();
    const verified = await verifyBootstrap(setup, { expectedProfileID: 'synthetic-profile', bootstrapKeyID: material.bootstrapSigner.keyID,
      bootstrapPublicKey: material.bootstrapSigner.publicKey, receiptIssuerKeyIDs: [material.receiptSigner.keyID] });
    assert.equal(verified.entitlementID, purchase.entitlementID);
    // Actual routed lifecycle begin creates an activation alarm alongside recovery.
    const begun = await publicPost(token(1), 'fixture-only', { entitlementHandle: verified.activationHandle,
      devicePublicKey: material.receiptSigner.publicKey, requestID: token(42) });
    assert.equal(begun.status, 200, await begun.clone().text());
    await call('recovery'); const pending = await call('inspect');
    assert.deepEqual(pending.alarms.map(row => row.channel), ['activation', 'bootstrap']);
    await runtime.dispose(); runtime = undefined; runtime = new Miniflare(options);
    const recreatedPurchase = await call('purchase'), recreated = await call('inspect');
    assert.equal(recreatedPurchase.bindingDigest, purchase.bindingDigest);
    assert.deepEqual(recreated.reservation, before.reservation); assert.equal(recreated.objectID, before.objectID);
    assert.deepEqual(recreated.bootstrap, before.bootstrap); assert.equal(descriptor(recreated), setup);
    await call('trigger'); const delivered = await call('inspect');
    assert.equal(delivered.mail.length, 3);
    assert.equal(delivered.mail.filter(mail => JSON.stringify(mail).includes(setup)).length, 2);
    await call('block'); assert.equal((await call('purchase', false)).status, 503);
    assert.equal((await call('inspect')).bootstrap[0].status, 'blocked');
    assert.equal(outbound, 0);
  } finally { await runtime?.dispose(); await rm(disk, { recursive: true, force: true }); }
});
