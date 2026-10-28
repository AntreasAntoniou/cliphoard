import test from 'node:test';
import assert from 'node:assert/strict';
import { createDeviceLicenceDurableObjectClasses, createDeviceLicenceAuthenticatedEdge } from '../durable-object-hosts.mjs';
import { storageFixture, reservation, scope, token, request, origin } from './bootstrap-directory-fixtures.mjs';
import { syntheticMaterial } from './host-key-consumer-fixtures.mjs';
import { reconstructHostKeyCapabilities } from '../host-key-consumer.mjs';

class Base { constructor(ctx, env) { this.ctx = ctx; this.env = env; } }
export async function fixture(t) {
  const material = syntheticMaterial();
  const keys = await reconstructHostKeyCapabilities({ enabled: true, material });
  const realm = 'synthetic-realm';
  const state = { inspect: 0, configuration: 0, allocations: 0, mails: [], payment: 'active', authenticate: 0 };
  const targetContexts = new Map(), targets = new Map(); let Classes;
  const context = name => {
    const s = storageFixture(t); let alarm = null;
    return { id: { toString: () => name }, storage: { ...s.storage,
      getAlarm: async () => alarm, setAlarm: async n => { alarm = n; }, deleteAlarm: async () => { alarm = null; } }, db: s.db };
  };
  const targetNamespace = { idFromName: name => ({ toString: () => name }), getByName(name) {
    if (!targetContexts.has(name)) targetContexts.set(name, context(name));
    if (!targets.has(name)) targets.set(name, new Classes.Entitlement(targetContexts.get(name), {}));
    return targets.get(name);
  } };
  const directoryNamespace = { idFromName: name => ({ toString: () => name }), getByName: () => directory };
  const inspectDeviceAuthority = async purchase => { state.inspect++; return { ...purchase, state: state.payment,
    ownerEmail: state.payment === 'active' ? 'owner@example.invalid' : null }; };
  const common = { realm, directoryNamespace, targetNamespace };
  const clocks = { epochMilliseconds: () => Date.now(), monotonicMilliseconds: () => performance.now() };
  const operational = { maximumAttemptsPerInvocation: 2, maxPendingOperations: 4, invocationBudgetMilliseconds: 1000,
    prearmDelayMilliseconds: 60000, retryDelayMilliseconds: 60000, continuationDelayMilliseconds: 60000 };
  Classes = createDeviceLicenceDurableObjectClasses({ enabled: true, DurableObject: Base,
    configureDirectory: () => ({ ...common, inspectDeviceAuthority,
      allocateEntitlementID: () => { state.allocations++; return token(16, 1); }, allocateProvisioningID: () => token(16, 21) }),
    configureEntitlement: async () => { state.configuration++; return { ...common,
      selection: { profileID: 'synthetic-profile', bootstrapKeyID: material.bootstrapSigner.keyID,
        bootstrapPublicKey: material.bootstrapSigner.publicKey, receiptIssuerKeyID: material.receiptSigner.keyID,
        receiptIssuerPublicKey: material.receiptSigner.publicKey }, keys: state.invalidKeys ? null : keys, inspectDeviceAuthority,
      admission: { evaluate: async () => ({ decision: 'allow', revision: 1 }),
        readCurrent: async id => ({ entitlementID: id, decision: 'allow', revision: 1 }) },
      mail: { from: 'support@example.invalid', replyTo: 'support@example.invalid', timeoutMilliseconds: 1000,
        send: async value => { state.mails.push(value); return { messageId: 'synthetic-accepted' }; } },
      clocks, bootstrapOperational: { ...operational, deliveryLeaseSeconds: 30 }, activationOperational: operational,
      limits: { challengeTTLSeconds: 600, deliveryLeaseSeconds: 30 },
      http: { origin, bodyTimeoutMs: 1000 }, maxConcurrentRequests: 4, alarmRecoveryDelayMilliseconds: 60000 }; },
  });
  const directoryContext = context(`${realm}:directory`), directory = new Classes.Directory(directoryContext, {});
  const edge = createDeviceLicenceAuthenticatedEdge({ enabled: true, ...common, origin, maxConcurrentRequests: 4,
    authenticate: async (_request, id) => { state.authenticate++; return { decision: 'allow', realm, entitlementID: id }; } });
  return { state, Classes, directory, directoryContext, targetContexts, targets, targetNamespace, directoryNamespace,
    edge, common, context, target: () => targets.get(`${realm}:entitlement:${token(16, 1)}`) };
}

test('default disabled factories do not read dependencies', async () => {
  let calls = 0; const options = { get configureDirectory() { calls++; throw Error(); } };
  assert.throws(() => createDeviceLicenceDurableObjectClasses(options), /host_disabled/);
  assert.equal((await createDeviceLicenceAuthenticatedEdge(options).handle(request())).status, 404);
  assert.equal(calls, 0);
});
test('authenticated edge denies mismatched or malformed authority before any directory effect', async t => {
  const f = await fixture(t);
  for (const auth of [null, false, { decision: 'allow', realm: 'other', entitlementID: token(16, 1) },
    { decision: 'allow', realm: f.common.realm, entitlementID: token(16, 2) }]) {
    const edge = createDeviceLicenceAuthenticatedEdge({ enabled: true, ...f.common, origin, maxConcurrentRequests: 1,
      authenticate: async () => auth });
    assert.equal((await edge.handle(request())).status, 503);
  }
  assert.equal(f.state.inspect, 0); assert.equal(f.state.configuration, 0); assert.equal(f.targetContexts.size, 0);
  assert.equal(f.directoryContext.db.prepare("SELECT count(*) n FROM sqlite_master WHERE name LIKE 'device_%'").get().n, 0);
});
test('unknown authenticated locator never creates target or provisions directory', async t => {
  const f = await fixture(t); assert.equal((await f.edge.handle(request())).status, 503);
  assert.equal(f.targetContexts.size, 0); assert.equal(f.state.allocations, 0);
});
test('trusted purchase provisions once, reuses original reservation and reconstructs persisted target', async t => {
  const f = await fixture(t);
  const [a, b] = await Promise.all([f.directory.processPurchase(scope()), f.directory.processPurchase(scope())]);
  assert.equal(a.entitlementID, token(16, 1)); assert.equal(a.bindingDigest, b.bindingDigest);
  assert.equal(f.targetContexts.size, 1);
  const id = `${f.common.realm}:entitlement:${a.entitlementID}`;
  f.targets.delete(id); const target = f.targetNamespace.getByName(id);
  assert.deepEqual(await target.provision(reservation()), { entitlementID: a.entitlementID, provisioningID: a.provisioningID, bindingDigest: a.bindingDigest });
  assert.equal((await target.requestIssue({ entitlementID: a.entitlementID, provisioningID: a.provisioningID, bindingDigest: a.bindingDigest })).code, 'already_issued');
  await assert.rejects(target.provision({ ...reservation(), scope: scope(2) }), /host_unavailable/);
});
test('wrong target address and unprovisioned public fetch refuse before host configuration', async t => {
  const f = await fixture(t), c = f.context('wrong'); const bad = new f.Classes.Entitlement(c, {});
  assert.equal((await bad.fetch(request())).status, 503); assert.equal(f.state.configuration, 0);
  await assert.rejects(bad.provision(reservation()), /host_unavailable/);
  assert.equal(c.db.prepare("SELECT count(*) n FROM sqlite_master WHERE name='device_bootstrap_state'").get().n, 0);
});
test('refund refresh reaches existing target and blocks issuance without allocating replacement', async t => {
  const f = await fixture(t), result = await f.directory.processPurchase(scope());
  const before = f.state.allocations; f.state.payment = 'blocked';
  await f.directory.refreshPurchase(scope());
  assert.equal(f.state.allocations, before);
  await assert.rejects(f.directory.processPurchase(scope()), /host_unavailable/);
  assert.equal((await f.directory.lookupReady(result.entitlementID)).bindingDigest, result.bindingDigest);
});
test('control RPCs reject absent and mismatched acknowledgements without authority reads', async t => {
  const f = await fixture(t), result = await f.directory.processPurchase(scope()), target = f.target();
  const ack = await f.directory.lookupReady(result.entitlementID), reads = f.state.inspect;
  for (const value of [undefined, null, { ...ack, bindingDigest: token(32, 9) }]) {
    await assert.rejects(target.requestIssue(value), /host_unavailable/);
    await assert.rejects(target.refreshAuthority(value), /host_unavailable/);
    await assert.rejects(target.recover(value), /host_unavailable/);
  }
  assert.equal(f.state.inspect, reads);
  const id = `${f.common.realm}:entitlement:${result.entitlementID}`, configurations = f.state.configuration;
  f.targets.delete(id);
  await assert.rejects(f.targetNamespace.getByName(id).requestIssue({ ...ack, bindingDigest: token(32, 9) }), /host_unavailable/);
  assert.equal(f.state.configuration, configurations);
});
test('refund refresh on genuine missing reservation is a typed no-op, pending remains retryable', async t => {
  const f = await fixture(t);
  assert.deepEqual(await f.directory.refreshPurchase(scope()), { ok: true, code: 'absent' });
  assert.equal(f.state.inspect, 0); assert.equal(f.state.configuration, 0); assert.equal(f.targetContexts.size, 0);
  f.state.invalidKeys = true;
  await assert.rejects(f.directory.processPurchase(scope()), /host_unavailable/);
  await assert.rejects(f.directory.refreshPurchase(scope()), /host_unavailable/);
});
test('partially initialized reservation cannot be completed by public requests', async t => {
  const f = await fixture(t); f.state.invalidKeys = true;
  await assert.rejects(f.directory.processPurchase(scope()), /host_unavailable/);
  const target = f.target(), count = f.state.configuration;
  f.state.invalidKeys = false;
  assert.equal((await target.fetch(request())).status, 503);
  assert.equal(f.state.configuration, count);
  assert.equal(await f.directory.lookupReady(reservation().entitlementID), null);
  await f.directory.processPurchase(scope());
  assert.equal((await f.directory.lookupReady(reservation().entitlementID)).entitlementID, reservation().entitlementID);
});
test('purchase scope rejects coercible objects before invoking authority', async t => {
  const f = await fixture(t); let coercions = 0;
  await assert.rejects(f.directory.processPurchase({ ...scope(), orderRef: { toString() { coercions++; return scope().orderRef; } } }), /host_unavailable/);
  assert.equal(coercions, 0); assert.equal(f.state.inspect, 0);
});
test('authentication holds concurrency slot until settlement after client abort', async t => {
  const f = await fixture(t); let release, entered = 0;
  const gate = new Promise(resolve => { release = resolve; });
  const edge = createDeviceLicenceAuthenticatedEdge({ enabled: true, ...f.common, origin, maxConcurrentRequests: 1,
    authenticate: async (_request, id) => { entered++; await gate; return { decision: 'allow', realm: f.common.realm, entitlementID: id }; } });
  const abort = new AbortController(), first = edge.handle(request(undefined, undefined, { signal: abort.signal }));
  await Promise.resolve(); abort.abort();
  assert.equal((await edge.handle(request())).status, 503); assert.equal(entered, 1);
  release(); assert.equal((await first).status, 503);
});
