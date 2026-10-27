import test from 'node:test';
import assert from 'node:assert/strict';
import { createDeviceBootstrapDirectory } from '../bootstrap-directory.mjs';
import { ack, deferred, reservation, scope, storageFixture, tick, token } from './bootstrap-directory-fixtures.mjs';

test('disabled directory is inert and enabled capture rejects getters without invocation', async () => {
  let touched = 0;
  const dangerous = { get storage() { touched++; throw Error('private'); }, get provisionTarget() { touched++; throw Error('private'); } };
  for (const options of [dangerous, { enabled: false, ...Object.getOwnPropertyDescriptors({}) }, Object.create({ enabled: true })]) {
    const value = createDeviceBootstrapDirectory(options);
    await assert.rejects(value.reserve(reservation()), /directory_disabled/);
    await assert.rejects(value.lookupReady(reservation().entitlementID), /directory_disabled/);
  }
  assert.equal(touched, 0);
  const options = { enabled: true, provisionTarget() {} };
  Object.defineProperty(options, 'storage', { enumerable: true, get() { touched++; throw Error('private'); } });
  assert.throws(() => createDeviceBootstrapDirectory(options), /directory_configuration/);
  assert.equal(touched, 0);
});

test('exact reservation persists pending; lookup-only misses create no tables or targets', async t => {
  const { db, storage, state } = storageFixture(t); let targets = 0;
  const directory = createDeviceBootstrapDirectory({ enabled: true, storage, provisionTarget: async r => { targets++; return ack(r); } });
  assert.equal(state.sql, 0);
  assert.equal(await directory.lookupReady(reservation().entitlementID), null);
  assert.deepEqual(db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all(), []);
  assert.deepEqual(await directory.reserve(reservation()), reservation());
  assert.deepEqual(await directory.reserve(reservation()), reservation());
  assert.deepEqual(await directory.lookupReservation(scope()), reservation());
  assert.equal(await directory.lookupReady(reservation().entitlementID), null);
  assert.equal(targets, 0);
  assert.equal(db.prepare('SELECT count(*) AS n FROM device_bootstrap_directory').get().n, 1);
});

test('scope, entitlement, session and provisioning collisions never overwrite reservations', async t => {
  const { db, storage } = storageFixture(t);
  const directory = createDeviceBootstrapDirectory({ enabled: true, storage, provisionTarget: async r => ack(r) });
  const first = reservation(); await directory.reserve(first);
  const collisions = [
    { ...first, scope: { ...first.scope, unitAmount: 2000 } },
    { ...reservation(2), entitlementID: first.entitlementID },
    { ...reservation(2), provisioningID: first.provisioningID },
    { ...reservation(2), scope: { ...scope(2), orderRef: first.scope.orderRef } },
    { ...reservation(2), scope: { ...scope(2), sessionId: first.scope.sessionId } },
  ];
  for (const value of collisions) await assert.rejects(directory.reserve(value), /directory_conflict/);
  assert.deepEqual(await directory.lookupReservation(first.scope), first);
  assert.equal(db.prepare('SELECT count(*) AS n FROM device_bootstrap_directory').get().n, 1);
  await directory.reserve(reservation(2));
  assert.equal(db.prepare('SELECT count(*) AS n FROM device_bootstrap_directory').get().n, 2);
});

test('provision requires an existing exact reservation and captures dependencies immutably', async t => {
  const { storage } = storageFixture(t); const calls = [];
  const options = { enabled: true, storage, provisionTarget: async r => { calls.push(r); return ack(r); } };
  const directory = createDeviceBootstrapDirectory(options);
  options.provisionTarget = () => { throw Error('replacement'); };
  await assert.rejects(directory.provision({ entitlementID: reservation().entitlementID, provisioningID: reservation().provisioningID }), /directory_missing/);
  assert.equal(calls.length, 0);
  const mutable = structuredClone(reservation()); await directory.reserve(mutable); mutable.scope.unitAmount = 999;
  const value = await directory.provision({ entitlementID: reservation().entitlementID, provisioningID: reservation().provisioningID });
  assert.deepEqual(value, ack()); assert.deepEqual(calls, [reservation()]);
  assert(Object.isFrozen(calls[0]) && Object.isFrozen(calls[0].scope));
  assert.deepEqual(await directory.lookupReady(reservation().entitlementID), ack());
});

test('target lost acknowledgement preserves pending and retries the same durable reservation', async t => {
  const { storage } = storageFixture(t); const calls = []; let first = true;
  const directory = createDeviceBootstrapDirectory({ enabled: true, storage, provisionTarget: async r => {
    calls.push(r); if (first) { first = false; throw Error('private response lost after target commit'); } return ack(r);
  } });
  await directory.reserve(reservation());
  const key = { entitlementID: reservation().entitlementID, provisioningID: reservation().provisioningID };
  await assert.rejects(directory.provision(key), /directory_unavailable/);
  assert.equal(await directory.lookupReady(key.entitlementID), null);
  assert.deepEqual(await directory.provision(key), ack());
  assert.deepEqual(calls, [reservation(), reservation()]);
});

test('ready digest is stable and a later target disagreement permanently stops routing', async t => {
  const { storage } = storageFixture(t); let digest = 80;
  const directory = createDeviceBootstrapDirectory({ enabled: true, storage, provisionTarget: async r => ack(r, digest) });
  const r = reservation(), key = { entitlementID: r.entitlementID, provisioningID: r.provisioningID };
  await directory.reserve(r); assert.deepEqual(await directory.provision(key), ack());
  assert.deepEqual(await directory.provision(key), ack());
  digest = 81; await assert.rejects(directory.provision(key), /directory_conflict/);
  assert.equal(await directory.lookupReady(r.entitlementID), null);
  assert.deepEqual(await directory.lookupReservation(r.scope), r);
  digest = 80; await assert.rejects(directory.provision(key), /directory_conflict/);
});

test('concurrent duplicate provisioning cannot replace the first committed digest', async t => {
  const { storage } = storageFixture(t); const gates = [deferred(), deferred()]; let calls = 0;
  const directory = createDeviceBootstrapDirectory({ enabled: true, storage, provisionTarget: async () => gates[calls++].promise });
  const r = reservation(), key = { entitlementID: r.entitlementID, provisioningID: r.provisioningID };
  await directory.reserve(r);
  const one = directory.provision(key), two = directory.provision(key); await tick();
  gates[0].resolve(ack()); assert.deepEqual(await one, ack());
  gates[1].resolve(ack(r, 82)); await assert.rejects(two, /directory_conflict/);
  assert.equal(await directory.lookupReady(r.entitlementID), null);
});

test('no ready result escapes a pending durability barrier', async t => {
  const { db, storage, state } = storageFixture(t); const gate = deferred();
  const directory = createDeviceBootstrapDirectory({ enabled: true, storage, provisionTarget: async r => {
    state.syncGate = gate.promise; return ack(r);
  } });
  const r = reservation(); await directory.reserve(r);
  let provisionDone = false, lookupDone = false;
  const provision = directory.provision({ entitlementID: r.entitlementID, provisioningID: r.provisioningID }).then(v => { provisionDone = true; return v; });
  await tick(); assert.equal(db.prepare('SELECT phase FROM device_bootstrap_directory').get().phase, 'ready');
  const lookup = directory.lookupReady(r.entitlementID).then(v => { lookupDone = true; return v; });
  await tick(); assert.equal(provisionDone, false); assert.equal(lookupDone, false);
  gate.resolve(); assert.deepEqual(await provision, ack()); assert.deepEqual(await lookup, ack());
});

test('malformed trusted inputs, acknowledgement getters and corruption fail closed', async t => {
  const { db, storage } = storageFixture(t); let touched = 0;
  const badAck = { entitlementID: reservation().entitlementID, provisioningID: reservation().provisioningID };
  Object.defineProperty(badAck, 'bindingDigest', { enumerable: true, get() { touched++; return token(32, 1); } });
  const directory = createDeviceBootstrapDirectory({ enabled: true, storage, provisionTarget: async () => badAck });
  for (const value of [{ ...reservation(), extra: true }, { ...reservation(), entitlementID: 'not-canonical' },
    { ...reservation(), scope: { ...scope(), mode: 'other' } }, { ...reservation(), scope: { ...scope(), unitAmount: 0 } }])
    await assert.rejects(directory.reserve(value), /directory_invalid/);
  await directory.reserve(reservation());
  await assert.rejects(directory.provision({ entitlementID: reservation().entitlementID, provisioningID: reservation().provisioningID }), /directory_unavailable/);
  assert.equal(touched, 0); assert.equal(await directory.lookupReady(reservation().entitlementID), null);
  db.prepare("UPDATE device_bootstrap_directory SET reservation_json='{}'").run();
  await assert.rejects(directory.lookupReady(reservation().entitlementID), /directory_storage/);
});
