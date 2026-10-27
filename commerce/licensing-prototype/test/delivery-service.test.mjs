import test from 'node:test';
import assert from 'node:assert/strict';
import { deliveryFixture, gate } from './delivery-fixtures.mjs';
import { createSqliteActivationService } from '../sqlite-service.mjs';
import { randomToken } from '../protocol.mjs';

test('authority block during sealing defeats a stale async active fact before enqueue', async t => {
  const f = await deliveryFixture(t);
  f.state.sealGate = () => { f.state.fence = { id: f.id, revision: 2, status: 'blocked' }; };
  await assert.rejects(f.service.begin(f.input()), { code: 'authority_fence_rejected' });
  assert.equal(f.service.snapshot().challenges, 0);
  assert.equal(f.service.snapshot().pending, 0);
});

test('authority block during signing and token opening fences before the async feed', async t => {
  const f = await deliveryFixture(t);
  const { challenge } = await f.service.begin(f.input());
  await f.service.deliverOne();
  f.state.signGate = () => { f.state.fence = { id: f.id, revision: 2, status: 'blocked' }; };
  await assert.rejects(f.service.approve(await f.approval(challenge)), { code: 'authority_fence_rejected' });
  assert.equal(f.service.snapshot().issued, 0);
  const other = await deliveryFixture(t);
  await other.service.begin(other.input());
  other.state.openGate = () => { other.state.fence = { id: other.id, revision: 2, status: 'blocked' }; };
  assert.equal((await other.service.deliverOne()).code, 'delivery_deferred');
  assert.equal(other.contexts.length, 0);
});

test('authority fence rejects accessors, Promise, wrong identity/revision and extras without getter reads', async t => {
  const f = await deliveryFixture(t); let reads = 0;
  const getter = { id: f.id, revision: 1, get status() { reads++; return 'active'; } };
  for (const value of [getter, Promise.resolve({ id: f.id, revision: 1, status: 'active' }),
    { id: randomToken(16), revision: 1, status: 'active' },
    { id: f.id, revision: 2, status: 'active' },
    { id: f.id, revision: 1, status: 'active', extra: true },
    { id: f.id, revision: 0, status: 'blocked' }]) {
    f.state.fence = value;
    await assert.rejects(f.service.begin(f.input()), { code: 'authority_fence_rejected' });
  }
  assert.equal(reads, 0); assert.equal(f.service.snapshot().pending, 0);
  assert.throws(() => createSqliteActivationService({ ...f.options, storage: f.storage, readAuthorityFence: 7 }),
    { code: 'configuration' });
});

test('generic blocked observation cancels outstanding mail and stays terminal at its revision', async t => {
  const f = await deliveryFixture(t, { fence: false });
  await f.service.begin(f.input());
  await f.service.observeEntitlement({ ...f.fact(), status: 'blocked', revision: 2 });
  await f.service.observeEntitlement({ ...f.fact(), status: 'active', revision: 2 });
  assert.equal(f.service.snapshot().cancelled, 1);
  assert.equal((await f.service.deliverOne()).code, 'nothing_due');
  assert.equal(f.service.nextDeliveryAt(), null);
});

test('aggregate due time survives restart and excludes accepted/cancelled rows', async t => {
  const f = await deliveryFixture(t, { fence: false });
  assert.equal(f.service.nextDeliveryAt(), null);
  await f.service.begin(f.input());
  assert.equal(f.service.nextDeliveryAt(), f.state.milliseconds / 1000);
  f.state.deliver = async () => { throw new Error('synthetic lost ack'); };
  assert.equal((await f.service.deliverOne()).code, 'delivery_uncertain');
  const expiry = f.state.milliseconds / 1000 + 30;
  assert.equal(f.service.nextDeliveryAt(), expiry);
  f.restart(); assert.equal(f.service.nextDeliveryAt(), expiry);
  await f.service.begin(f.input());
  assert.equal(f.service.nextDeliveryAt(), f.state.milliseconds / 1000);
  f.state.deliver = undefined;
  await f.service.deliverOne();
  assert.equal(f.service.nextDeliveryAt(), expiry);
  f.state.milliseconds += 30000;
  await f.service.deliverOne();
  assert.equal(f.service.nextDeliveryAt(), null);
});

test('private final dispatch capability is scoped to its exact live lease and authority', async t => {
  const f = await deliveryFixture(t); const entered = gate(), release = gate();
  const { challenge } = await f.service.begin(f.input());
  f.state.deliver = async context => { entered.resolve(context); await release.promise; return { accepted: true }; };
  const pending = f.service.deliverOne(), context = await entered.promise;
  assert.deepEqual(Object.keys(context).sort(), ['to','deliveryID','challengeID','entitlementID',
    'entitlementRevision','deviceKeyHash','authorizeDispatch','token','expiresAt'].sort());
  assert.equal(context.entitlementID, f.id); assert.equal(context.entitlementRevision, 1);
  assert.equal(context.deviceKeyHash, challenge.deviceKeyHash);
  assert.equal(context.authorizeDispatch(), undefined);
  f.state.fence = { id: f.id, revision: 2, status: 'blocked' };
  assert.throws(() => context.authorizeDispatch(), { code: 'authority_fence_rejected' });
  f.state.fence = { id: f.id, revision: 1, status: 'active' };
  f.state.milliseconds += 30000;
  assert.throws(() => context.authorizeDispatch(), { code: 'delivery_superseded' });
  release.resolve(); await pending;
  assert.throws(() => context.authorizeDispatch(), { code: 'delivery_superseded' });
});
