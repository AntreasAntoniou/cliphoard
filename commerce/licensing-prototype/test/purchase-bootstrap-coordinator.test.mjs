import test from 'node:test';
import assert from 'node:assert/strict';
import { createPurchaseBootstrapCoordinator } from '../purchase-bootstrap-coordinator.mjs';
import { createDeviceBootstrapDirectory } from '../bootstrap-directory.mjs';
import { createDeviceBootstrapService } from '../bootstrap-service.mjs';
import { reconstructHostKeyCapabilities } from '../host-key-consumer.mjs';
import { syntheticMaterial } from './host-key-consumer-fixtures.mjs';
import { scope as syntheticScope, token, storageFixture, deferred } from './bootstrap-directory-fixtures.mjs';
import { fixture as stripeFixture } from '../../test/stripe-fixtures.mjs';
import { orderService } from '../../src/stripe-order.mjs';

const safe = code => error => error.name === 'PurchaseBootstrapCoordinatorError' && error.code === code
  && error.message === code && error.cause === undefined;

async function fixture(t, custom = {}) {
  const fixedScope = custom.scope ?? syntheticScope(), initial = { ...fixedScope, state: 'active', ownerEmail: 'synthetic-buyer@example.invalid' };
  const state = { fact: initial, inspectCalls: 0, allocations: 0, reserves: 0, provisions: 0,
    resolves: 0, issues: 0, signs: 0, sends: 0, serial: 1, unavailable: false,
    loseReserve: false, loseProvision: false, loseTargetProvision: false, loseIssue: false,
    afterProvision: null, inspectGate: null };
  const inspect = custom.inspect ?? (async () => {
    state.inspectCalls++;
    if (state.inspectGate) await state.inspectGate.promise;
    if (state.unavailable) throw Error('PRIVATE PROVIDER ERROR');
    return structuredClone(state.fact);
  });
  const host = await reconstructHostKeyCapabilities({ enabled: true, material: syntheticMaterial() });
  const targets = new Map(), directoryStore = storageFixture(t);
  const directory = createDeviceBootstrapDirectory({ enabled: true, storage: directoryStore.storage,
    provisionTarget: async reservation => {
      let target = targets.get(reservation.entitlementID);
      if (!target) {
        const db = storageFixture(t); let alarm = null;
        const service = createDeviceBootstrapService({ enabled: true, storage: db.storage, reservation,
          selection: { profileID: 'coordinator-synthetic', bootstrapKeyID: host.bootstrapSigner.bootstrapKeyID,
            bootstrapPublicKey: host.bootstrapSigner.bootstrapPublicKey, receiptIssuerKeyID: host.receiptSigner.issuerKeyID,
            receiptIssuerPublicKey: host.receiptSigner.issuerPublicKey },
          signer: { sign: async bytes => { state.signs++; return host.bootstrapSigner.sign(bytes); } },
          custody: host.setupSealer, inspectDeviceAuthority: inspect,
          delivery: { deliverBootstrap: async () => { state.sends++; throw Error('send not expected'); }, hasUnsettledSend: () => false },
          alarmStorage: { getAlarm: async () => alarm, setAlarm: async value => { alarm = value; },
            deleteAlarm: async () => { alarm = null; }, sync: async () => {} },
          clocks: { epochMilliseconds: () => 1800000000000, monotonicMilliseconds: () => 0 },
          // Explicit synthetic test values only, never production defaults.
          operational: { maxPendingOperations: 8, maximumAttemptsPerInvocation: 4, invocationBudgetMilliseconds: 1000,
            prearmDelayMilliseconds: 50, retryDelayMilliseconds: 100, continuationDelayMilliseconds: 100, deliveryLeaseSeconds: 60 } });
        target = { service, db }; targets.set(reservation.entitlementID, target);
      }
      const acknowledgement = await target.service.provision(); target.ack = acknowledgement;
      if (state.loseTargetProvision) { state.loseTargetProvision = false; throw Error('lost target acknowledgement'); }
      return acknowledgement;
    } });
  const dependencies = {
    lookupReservation: value => directory.lookupReservation(value),
    lookupReady: value => directory.lookupReady(value),
    reserve: async value => { state.reserves++; const result = await directory.reserve(value);
      if (state.loseReserve) { state.loseReserve = false; throw Error('lost reserve acknowledgement'); } return result; },
    provision: async value => { state.provisions++; const result = await directory.provision(value);
      if (state.afterProvision) await state.afterProvision();
      if (state.loseProvision) { state.loseProvision = false; throw Error('lost directory acknowledgement'); } return result; },
  };
  const options = { enabled: true, scope: { ...fixedScope }, inspectDeviceAuthority: inspect, directory: dependencies,
    allocateEntitlementID: () => { state.allocations++; return token(16, state.serial++); },
    allocateProvisioningID: () => { state.allocations++; return token(16, state.serial++); },
    resolveTarget: async ack => {
      state.resolves++; const target = targets.get(ack.entitlementID); assert(target);
      return { ...target.ack, requestIssue: async (...args) => {
        assert.equal(args.length, 0); state.issues++; const result = await target.service.requestIssue();
        if (state.loseIssue) { state.loseIssue = false; throw Error('lost issuance acknowledgement'); } return result;
      } };
    } };
  const make = changes => createPurchaseBootstrapCoordinator({ ...options, ...changes });
  return { state, options, make, coordinator: make(), directory, directoryStore, targets, fixedScope,
    mutations: () => ({ allocations: state.allocations, reserves: state.reserves, provisions: state.provisions,
      targets: targets.size, issues: state.issues, signs: state.signs, sends: state.sends }) };
}

test('disabled construction never evaluates dependency getters; opt-in accessor refuses', async () => {
  let reads = 0; const input = { get scope() { reads++; throw Error('private'); } };
  await assert.rejects(createPurchaseBootstrapCoordinator(input).process(), safe('coordinator_disabled'));
  input.enabled = false;
  await assert.rejects(createPurchaseBootstrapCoordinator(input).process(), safe('coordinator_disabled'));
  const enabledAccessor = { get enabled() { reads++; throw Error('private'); } };
  assert.throws(() => createPurchaseBootstrapCoordinator(enabledAccessor), safe('coordinator_configuration'));
  await assert.rejects(createPurchaseBootstrapCoordinator(Object.create({ enabled: true })).process(), safe('coordinator_disabled'));
  assert.equal(reads, 0);
});

test('constructor captures exact own scope and capabilities without getters or extra fields', async t => {
  const f = await fixture(t); let reads = 0;
  const invalid = [ { ...f.options, extra: true }, { ...f.options, scope: { ...f.fixedScope, extra: true } },
    { ...f.options, scope: { ...f.fixedScope, get unitAmount() { reads++; return 1000; } } },
    { ...f.options, directory: { ...f.options.directory, extra: true } },
    { ...f.options, get resolveTarget() { reads++; return f.options.resolveTarget; } } ];
  for (const value of invalid) assert.throws(() => createPurchaseBootstrapCoordinator(value), safe('coordinator_configuration'));
  assert.equal(reads, 0); assert.equal(f.state.inspectCalls, 0);
  const stable = f.make(); f.options.scope.unitAmount = 1; f.options.directory.reserve = () => { throw Error('retargeted'); };
  f.options.inspectDeviceAuthority = () => { throw Error('retargeted'); };
  assert.equal((await stable.process()).code, 'issued');
});

test('no operation arguments can supply eligibility, purchaser, recipient or IDs', async t => {
  const f = await fixture(t);
  await assert.rejects(f.coordinator.process({ state: 'active', recipient: 'attacker@example.invalid', entitlementID: token(16, 9) }), safe('coordinator_rejected'));
  assert.equal(f.state.inspectCalls, 0); assert.deepEqual(f.mutations(), { allocations: 0, reserves: 0, provisions: 0, targets: 0, issues: 0, signs: 0, sends: 0 });
});

test('pending, blocked, unavailable and mismatched authority cause zero mutations', async t => {
  const f = await fixture(t);
  for (const state of ['pending', 'blocked']) {
    f.state.fact = { ...f.fixedScope, state, ownerEmail: null };
    await assert.rejects(f.coordinator.process(), safe('coordinator_ineligible'));
  }
  f.state.unavailable = true; await assert.rejects(f.coordinator.process(), safe('coordinator_authority_unavailable'));
  f.state.unavailable = false; f.state.fact = { ...f.fixedScope, unitAmount: 999, state: 'active', ownerEmail: 'buyer@example.invalid' };
  await assert.rejects(f.coordinator.process(), safe('coordinator_scope_mismatch'));
  assert.deepEqual(f.mutations(), { allocations: 0, reserves: 0, provisions: 0, targets: 0, issues: 0, signs: 0, sends: 0 });
});

test('unavailable, undefined and malformed lookup results are never a reservation miss', async t => {
  const f = await fixture(t);
  for (const lookupReservation of [async () => { throw Error('private'); }, async () => undefined,
    async () => false, async () => ({}), async () => ({ get scope() { throw Error('private'); } })]) {
    const coordinator = f.make({ directory: { ...f.options.directory, lookupReservation } });
    await assert.rejects(coordinator.process());
  }
  assert.equal(f.state.allocations, 0); assert.equal(f.state.reserves, 0);
});

test('actual directory and bootstrap service initialize and issue one stable allocation', async t => {
  const f = await fixture(t), result = await f.coordinator.process();
  assert.equal(result.code, 'issued'); assert.equal(result.ok, true); assert(Object.isFrozen(result));
  assert.equal(f.directoryStore.db.prepare('SELECT count(*) AS n FROM device_bootstrap_directory').get().n, 1);
  const target = f.targets.get(result.entitlementID); assert.equal(target.service.snapshot().issued, 1);
  assert.equal(target.db.db.prepare('SELECT count(*) AS n FROM device_bootstrap_outbox').get().n, 1);
  assert.equal(f.state.sends, 0);
  assert.deepEqual(Reflect.ownKeys(result).sort(), ['bindingDigest', 'code', 'entitlementID', 'ok', 'provisioningID']);
});

test('duplicate notifications repeat requestIssue without allocating or adding another outbox', async t => {
  const f = await fixture(t), first = await f.coordinator.process(), second = await f.coordinator.process();
  assert.equal(second.code, 'already_issued'); assert.equal(second.entitlementID, first.entitlementID);
  assert.equal(f.state.allocations, 2); assert.equal(f.state.reserves, 1); assert.equal(f.targets.size, 1);
  assert.equal(f.state.signs, 1); assert.equal(f.targets.get(first.entitlementID).service.snapshot().pending, 1);
});

test('lost reserve acknowledgement reconciles the exact original scope and IDs', async t => {
  const f = await fixture(t); f.state.loseReserve = true;
  const result = await f.coordinator.process();
  assert.equal(result.code, 'issued'); assert.equal(result.entitlementID, token(16, 1));
  assert.equal(f.state.allocations, 2); assert.equal(f.state.reserves, 1);
});

test('unresolved reserve uncertainty holds later calls without a replacement allocation', async t => {
  const f = await fixture(t); let reserves = 0;
  const coordinator = f.make({ directory: { ...f.options.directory, lookupReservation: async () => null,
    reserve: async () => { reserves++; throw Error('uncertain'); } } });
  await assert.rejects(coordinator.process()); await assert.rejects(coordinator.process());
  assert.equal(reserves, 1); assert.equal(f.state.allocations, 2); assert.equal(f.state.provisions, 0);
});

test('lost committed directory provision acknowledgement recovers READY without new IDs', async t => {
  const f = await fixture(t); f.state.loseProvision = true;
  assert.equal((await f.coordinator.process()).code, 'issued');
  assert.equal(f.state.allocations, 2); assert.equal(f.state.reserves, 1); assert.equal(f.state.provisions, 1);
});

test('lost target provision acknowledgement retries the same pending reservation', async t => {
  const f = await fixture(t); f.state.loseTargetProvision = true;
  await assert.rejects(f.coordinator.process());
  const original = await f.directory.lookupReservation(f.fixedScope);
  assert.equal(await f.directory.lookupReady(original.entitlementID), null);
  const result = await f.coordinator.process(); assert.equal(result.entitlementID, original.entitlementID);
  assert.equal(f.state.allocations, 2); assert.equal(f.state.reserves, 1); assert.equal(f.targets.size, 1);
});

test('lost issuance acknowledgement retries stable requestIssue and preserves one winning descriptor', async t => {
  const f = await fixture(t); f.state.loseIssue = true;
  await assert.rejects(f.coordinator.process(), safe('coordinator_issue_unavailable'));
  const r = await f.directory.lookupReservation(f.fixedScope), target = f.targets.get(r.entitlementID);
  const before = target.db.db.prepare('SELECT envelope_hash FROM device_bootstrap_state').get().envelope_hash;
  const result = await f.coordinator.process(); assert.equal(result.code, 'already_issued');
  assert.equal(target.db.db.prepare('SELECT envelope_hash FROM device_bootstrap_state').get().envelope_hash, before);
  assert.equal(target.service.snapshot().pending, 1); assert.equal(f.state.signs, 1); assert.equal(f.state.allocations, 2);
});

test('same-instance concurrent notifications coalesce one operation and one reservation', async t => {
  const f = await fixture(t), gate = deferred(); f.state.inspectGate = gate;
  const first = f.coordinator.process(), second = f.coordinator.process(); assert.equal(first, second);
  gate.resolve(); const result = await first;
  assert.equal(result.code, 'issued'); assert.equal(f.state.reserves, 1); assert.equal(f.state.allocations, 2);
});

test('separate coordinators reconcile conflicting candidates to the actual unique directory winner', async t => {
  const f = await fixture(t); const second = f.make();
  const [a, b] = await Promise.all([f.coordinator.process(), second.process()]);
  assert.equal(a.entitlementID, b.entitlementID); assert.equal(a.provisioningID, b.provisioningID);
  assert.equal(f.directoryStore.db.prepare('SELECT count(*) AS n FROM device_bootstrap_directory').get().n, 1);
  assert.equal(f.targets.size, 1); assert.equal(f.state.signs, 1);
});

test('refund between READY and issuance prevents issue; READY is initialization only', async t => {
  const f = await fixture(t); f.state.afterProvision = () => { f.state.fact = { ...f.fixedScope, state: 'blocked', ownerEmail: null }; };
  await assert.rejects(f.coordinator.process(), safe('coordinator_ineligible'));
  const r = await f.directory.lookupReservation(f.fixedScope); assert(await f.directory.lookupReady(r.entitlementID));
  assert.equal(f.state.issues, 0); assert.equal(f.state.signs, 0);
});

test('target final recheck fences a refund after coordinator final inspection', async t => {
  const f = await fixture(t);
  const coordinator = f.make({ resolveTarget: async ack => {
    const target = await f.options.resolveTarget(ack);
    return { ...target, requestIssue: async () => {
      f.state.fact = { ...f.fixedScope, state: 'blocked', ownerEmail: null }; return target.requestIssue();
    } };
  } });
  await assert.rejects(coordinator.process(), safe('coordinator_issue_unavailable'));
  assert.equal(f.state.signs, 0); const r = await f.directory.lookupReservation(f.fixedScope);
  assert.equal(f.targets.get(r.entitlementID).service.snapshot().issued, 0);
});

test('foreign target identity and non-service acknowledgement never report success', async t => {
  const f = await fixture(t);
  const coordinator = f.make({ resolveTarget: async ack => ({ ...ack, entitlementID: token(16, 99), requestIssue: async () => ({ ok: true, code: 'issued' }) }) });
  await assert.rejects(coordinator.process(), safe('coordinator_target_mismatch')); assert.equal(f.state.issues, 0);
  const other = f.make({ resolveTarget: async ack => ({ ...ack, requestIssue: async () => ({ ok: true, code: 'delivered' }) }) });
  await assert.rejects(other.process(), safe('coordinator_issue_unavailable'));
});

test('actual fixed-order orderService inspector composes active and refunded flows without legacy issuance', async t => {
  const stripe = await stripeFixture(); await stripe.service().start(stripe.ref); stripe.stripe.pay();
  const inspector = orderService({ ...stripe, deviceAuthority: { enabled: true, orderRef: stripe.ref, sessionId: stripe.stripe.s.id } }).inspectDeviceAuthority;
  const initial = await inspector(), fixedScope = Object.fromEntries(Object.keys(syntheticScope()).map(key => [key, initial[key]]));
  stripe.env.CLIPHOARD_SIGNING_SEED = 'invalid-unused-legacy-seed';
  const f = await fixture(t, { scope: fixedScope, inspect: inspector }), writes = stripe.storage.writes;
  assert.equal((await f.coordinator.process()).code, 'issued'); assert.equal(stripe.storage.writes, writes);
  assert.equal(stripe.sent.length, 0); assert.equal(stripe.storage.data.get('order').licence, null);
  stripe.stripe.ch.amount_refunded = 1;
  await assert.rejects(f.coordinator.process(), safe('coordinator_ineligible'));
  assert.equal(stripe.storage.writes, writes); assert.equal(f.state.allocations, 2);
});

// This per-operation comparison does not replace the target's durable purchaser fence.
test('purchaser change between READY and issuance holds before requesting issue', async t => {
  const f = await fixture(t); f.state.afterProvision = () => {
    f.state.fact = { ...f.fixedScope, state: 'active', ownerEmail: 'changed-buyer@example.invalid' };
  };
  await assert.rejects(f.coordinator.process(), safe('coordinator_purchaser_mismatch'));
  assert.equal(f.state.issues, 0); assert.equal(f.state.signs, 0);
});

test('synchronous inspector reentry shares the already installed in-flight promise', async t => {
  const f = await fixture(t); let reentered, inspections = 0, entered = false;
  const coordinator = f.make({ inspectDeviceAuthority: () => {
    inspections++;
    if (!entered) { entered = true; reentered = coordinator.process(); }
    return f.options.inspectDeviceAuthority();
  } });
  const first = coordinator.process();
  const settled = await Promise.allSettled([first, reentered]);
  assert(settled.every(result => result.status === 'fulfilled'));
  assert.equal(reentered, first);
  assert.equal(inspections, 2);
  assert.equal(f.state.reserves, 1); assert.equal(f.state.provisions, 1); assert.equal(f.state.issues, 1);
  assert.equal(f.state.allocations, 2); assert.equal(f.state.signs, 1); assert.equal(f.state.sends, 0);
});
