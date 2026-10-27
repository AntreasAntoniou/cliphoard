import test from 'node:test';
import assert from 'node:assert/strict';
import * as edgeModule from '../bootstrap-directory-edge.mjs';
import { createDeviceBootstrapDirectory } from '../bootstrap-directory.mjs';
import { ack, reservation, token, storageFixture } from './bootstrap-directory-fixtures.mjs';

const capture = value => edgeModule.captureDeviceBootstrapDirectoryRPCAcknowledgement(value);
function rpc(value, dispose) {
  return Object.defineProperty({ ...value }, Symbol.dispose, { value: dispose, configurable: true });
}

test('RPC acknowledgement captures only primitive fields and disposes before returning', () => {
  let disposed = 0; const returned = rpc(ack(), () => { disposed++; });
  const result = capture(returned);
  assert.deepEqual(result, ack()); assert(Object.isFrozen(result)); assert.equal(disposed, 1);
  assert.deepEqual(Reflect.ownKeys(result), ['entitlementID', 'provisioningID', 'bindingDigest']);
  returned.bindingDigest = token(32, 99); assert.deepEqual(result, ack());
  assert.equal(capture(null), null); assert.deepEqual(capture(ack()), ack());
});

test('RPC acknowledgement rejects extra metadata, getters, coercion and throwing disposal while cleaning known resources', () => {
  let disposed = 0, touched = 0;
  for (const invalid of [{ ...ack(), extra: 'no' }, { ...ack(), [Symbol('unknown')]: 'no' },
    { ...ack(), bindingDigest: 'bad' }, { ...ack(), entitlementID: new String(ack().entitlementID) }]) {
    const before = disposed;
    assert.throws(() => capture(rpc(invalid, () => { disposed++; })), /directory_rpc_unavailable/);
    assert.equal(disposed, before + 1);
  }
  const getter = rpc(ack(), () => { disposed++; });
  Object.defineProperty(getter, 'bindingDigest', { get() { touched++; return ack().bindingDigest; } });
  const before = disposed;
  assert.throws(() => capture(getter), /directory_rpc_unavailable/); assert.equal(disposed, before + 1);
  const badDispose = { ...ack() };
  Object.defineProperty(badDispose, Symbol.dispose, { get() { touched++; return () => {}; } });
  assert.throws(() => capture(badDispose), /directory_rpc_unavailable/); assert.equal(touched, 0);
  assert.throws(() => capture(rpc(ack(), () => { throw Error('private failure'); })), error =>
    error.message === 'directory_rpc_unavailable');
  assert.throws(() => capture(rpc(ack(), 'not a function')), /directory_rpc_unavailable/);
});

test('RPC transport cleanup cannot turn a conflicting target acknowledgement into routing readiness', async t => {
  const fixture = storageFixture(t); let disposed = 0, digest = ack().bindingDigest;
  try {
    const directory = createDeviceBootstrapDirectory({ enabled: true, storage: fixture.storage,
      provisionTarget: async () => capture(rpc({ ...ack(), bindingDigest: digest }, () => { disposed++; })) });
    const pinned = reservation(), key = { entitlementID: pinned.entitlementID, provisioningID: pinned.provisioningID };
    await directory.reserve(pinned); await directory.provision(key); assert.deepEqual(await directory.lookupReady(pinned.entitlementID), ack());
    digest = token(32, 98); await assert.rejects(directory.provision(key), /directory_conflict/);
    assert.equal(await directory.lookupReady(pinned.entitlementID), null); assert.equal(disposed, 2);
  } finally { /* SQLite fixture cleanup is registered with the test. */ }
});
