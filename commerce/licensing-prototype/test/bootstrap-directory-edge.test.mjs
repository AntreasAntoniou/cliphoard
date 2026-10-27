import test from 'node:test';
import assert from 'node:assert/strict';
import { createDeviceBootstrapDirectoryEdge } from '../bootstrap-directory-edge.mjs';
import { ack, deferred, origin, request, reservation, tick, token } from './bootstrap-directory-fixtures.mjs';

test('disabled edge reads no dependency and enabled configuration captures plain capabilities', async () => {
  let touched = 0; const options = {};
  for (const name of ['origin', 'maxConcurrentRequests', 'lookupReady', 'forward'])
    Object.defineProperty(options, name, { enumerable: true, get() { touched++; throw Error('private'); } });
  assert.equal((await createDeviceBootstrapDirectoryEdge(options).handle(request())).status, 404);
  assert.equal(touched, 0);
  Object.defineProperty(options, 'enabled', { value: true, enumerable: true });
  assert.throws(() => createDeviceBootstrapDirectoryEdge(options), /directory_edge_configuration/);
  assert.equal(touched, 0);
  for (const invalid of [{ origin: new URL(origin) }, { maxConcurrentRequests: 0 }, { maxConcurrentRequests: undefined }])
    assert.throws(() => createDeviceBootstrapDirectoryEdge({ enabled: true, origin, maxConcurrentRequests: 2, lookupReady() {}, forward() {}, ...invalid }), /directory_edge_configuration/);
});

test('invalid public requests and inert confirmation never touch directory or namespace', async () => {
  let lookups = 0, forwards = 0;
  const edge = createDeviceBootstrapDirectoryEdge({ enabled: true, origin, maxConcurrentRequests: 2,
    lookupReady: () => { lookups++; }, forward: () => { forwards++; } });
  const invalid = [
    request('bad'), request(`${reservation().entitlementID},${reservation().entitlementID}`), request(undefined, 'other'),
    request(undefined, 'begin', { method: 'GET', body: undefined }),
    request(undefined, 'begin', { headers: { 'content-type': 'text/plain', 'X-Cliphoard-Entitlement': reservation().entitlementID } }),
    request(undefined, 'begin', { headers: { 'content-type': 'application/json', 'content-length': '0', 'X-Cliphoard-Entitlement': reservation().entitlementID } }),
    request(undefined, 'begin', { headers: { 'content-type': 'application/json', origin: 'https://foreign.invalid', 'X-Cliphoard-Entitlement': reservation().entitlementID } }),
    new Request(`${origin}/device-licensing/v1/begin?secret=value`, { method: 'POST', body: '{}' }),
    new Request('https://foreign.invalid/device-licensing/v1/begin', { method: 'POST', body: '{}' }),
    request(undefined, 'begin', { body: undefined }),
  ];
  const aborted = new AbortController(); aborted.abort(); invalid.push(request(undefined, 'begin', { signal: aborted.signal }));
  const consumed = request(); await consumed.text(); invalid.push(consumed);
  for (const value of invalid) assert.notEqual((await edge.handle(value)).status, 200);
  for (const method of ['GET', 'HEAD']) {
    const response = await edge.handle(new Request(`${origin}/device-licensing/v1/confirmation`, { method }));
    assert.equal(response.status, 200); if (method === 'HEAD') assert.equal(await response.text(), '');
  }
  assert.equal(lookups, 0); assert.equal(forwards, 0);
});

test('missing, pending, malformed or wrong-locator records never reach target namespace', async () => {
  let forwards = 0, record = null;
  const edge = createDeviceBootstrapDirectoryEdge({ enabled: true, origin, maxConcurrentRequests: 2,
    lookupReady: () => record, forward: () => { forwards++; return new Response('private'); } });
  for (const value of [null, undefined, {}, reservation(), { ...ack(), extra: true },
    { ...ack(), entitlementID: reservation(2).entitlementID }, { ...ack(), bindingDigest: 'bad' }]) {
    record = value; const response = await edge.handle(request());
    assert.equal(response.status, 503); assert.doesNotMatch(await response.text(), /private/);
  }
  assert.equal(forwards, 0);
});

test('ready route passes the exact original request and captures immutable acknowledgement', async () => {
  const original = request(); const mutable = { ...ack() }; let observed;
  const options = { enabled: true, origin, maxConcurrentRequests: 2, lookupReady: () => mutable,
    forward: async (ready, value) => { observed = ready; assert.equal(value, original);
      assert.equal(await value.text(), '{"opaque":"original-body"}'); return new Response('{"ok":true}', { status: 200 }); } };
  const edge = createDeviceBootstrapDirectoryEdge(options); options.forward = () => { throw Error('replacement'); };
  assert.equal((await edge.handle(original)).status, 200);
  assert.deepEqual(observed, ack()); assert(Object.isFrozen(observed)); mutable.bindingDigest = token(32, 99);
  assert.deepEqual(observed, ack());
});

test('aborted unsettled lookup retains capacity and never forwards after lookup settles', async () => {
  const gate = deferred(), controller = new AbortController(); let forwards = 0, calls = 0;
  const edge = createDeviceBootstrapDirectoryEdge({ enabled: true, origin, maxConcurrentRequests: 1,
    lookupReady: async () => { calls++; return gate.promise; }, forward: () => { forwards++; return new Response('{}'); } });
  const first = edge.handle(request(undefined, 'begin', { signal: controller.signal })); await tick(); controller.abort();
  assert.equal((await edge.handle(request())).status, 503); assert.equal(calls, 1);
  gate.resolve(ack()); assert.equal((await first).status, 400); assert.equal(forwards, 0);
});

test('dispatched forwarding retains capacity until settlement and sanitizes failures', async () => {
  const gate = deferred(), controller = new AbortController(); let calls = 0;
  const edge = createDeviceBootstrapDirectoryEdge({ enabled: true, origin, maxConcurrentRequests: 1,
    lookupReady: () => ack(), forward: async () => { calls++; await gate.promise; throw Error('private provider detail'); } });
  const first = edge.handle(request(undefined, 'begin', { signal: controller.signal })); await tick(); controller.abort();
  assert.equal((await edge.handle(request())).status, 503); assert.equal(calls, 1);
  gate.resolve(); const failed = await first; assert.equal(failed.status, 503);
  assert.doesNotMatch(await failed.text(), /private|provider/); assert.equal(failed.headers.get('cache-control'), 'no-store');
});

test('ready-record getters are rejected without invocation', async () => {
  let touched = 0, forwards = 0; const value = { entitlementID: ack().entitlementID, provisioningID: ack().provisioningID };
  Object.defineProperty(value, 'bindingDigest', { enumerable: true, get() { touched++; return ack().bindingDigest; } });
  const edge = createDeviceBootstrapDirectoryEdge({ enabled: true, origin, maxConcurrentRequests: 1,
    lookupReady: () => value, forward: () => { forwards++; } });
  assert.equal((await edge.handle(request())).status, 503); assert.equal(touched, 0); assert.equal(forwards, 0);
});
