import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture } from './stripe-fixtures.mjs';
import { orderService } from '../src/stripe-order.mjs';

async function setup(paid = true) {
  const f = await fixture();
  await f.service().start(f.ref);
  if (paid) f.stripe.pay();
  const option = { enabled: true, orderRef: f.ref, sessionId: f.stripe.s.id };
  const make = (deviceAuthority = option) => orderService({ ...f, deviceAuthority });
  return { ...f, option, make };
}
function state(f) {
  return { rows: structuredClone([...f.storage.data]), writes: f.storage.writes,
    sent: structuredClone(f.sent), alarms: [...f.alarms], creates: f.stripe.creates };
}
const code = expected => e => e.code === expected;

test('inspection is disabled by construction and has no storage/provider effects', async () => {
  const f = await fixture(); let reads = 0;
  f.storage.get = async () => { reads++; throw Error('must not read'); };
  for (const deviceAuthority of [undefined, { enabled: false }]) {
    const service = orderService({ ...f, deviceAuthority });
    await assert.rejects(service.inspectDeviceAuthority(), code('device_authority_disabled'));
  }
  assert.equal(reads, 0); assert.deepEqual(f.stripe.calls, []); assert.equal(f.storage.writes, 0);
});

test('eligible inspection returns only scoped authenticated facts without minting or mutation', async () => {
  const f = await setup(), before = state(f);
  // A read cannot silently invoke the legacy signer or delivery pipeline.
  f.env.CLIPHOARD_SIGNING_SEED = 'invalid-unused-seed';
  const result = await f.make().inspectDeviceAuthority();
  assert.deepEqual(result, { accountId: 'acct_TestAccount', mode: 'test', orderRef: f.ref,
    sessionId: 'cs_test_Session1', productId: 'prod_Cliphoard', priceId: 'price_Pro',
    currency: 'gbp', unitAmount: 1000, taxBehavior: 'inclusive', state: 'active',
    ownerEmail: 'synthetic-buyer@example.invalid' });
  assert.deepEqual(state(f), before);
  assert(!JSON.stringify(result).includes(f.token()));
  assert(!JSON.stringify(result).includes(f.keys.publicHex));
});

test('inspection captures fixed trusted IDs and rejects request-selected arguments', async () => {
  const f = await setup(), service = f.make();
  f.option.orderRef = '00000000-0000-4000-8000-000000000001';
  f.option.sessionId = 'cs_Foreign';
  assert.equal((await service.inspectDeviceAuthority()).orderRef, f.ref);
  const calls = f.stripe.calls.length;
  await assert.rejects(service.inspectDeviceAuthority({ orderRef: f.ref }), code('device_authority_arguments'));
  assert.equal(f.stripe.calls.length, calls);
});

test('scope option rejects getters, extra keys and unbound sessions before read', async () => {
  const f = await setup(); let getters = 0;
  const option = { enabled: true, sessionId: f.stripe.s.id, get orderRef() { getters++; return f.ref; } };
  assert.throws(() => f.make(option), code('device_authority_configuration'));
  assert.equal(getters, 0);
  assert.throws(() => f.make({ ...f.option, alias: 'anything' }), code('device_authority_configuration'));
  const record = f.storage.data.get('order'); record.sessionId = null;
  const before = state(f), calls = f.stripe.calls.length;
  await assert.rejects(f.make().inspectDeviceAuthority(), code('device_authority_scope_mismatch'));
  assert.equal(f.stripe.calls.length, calls); assert.deepEqual(state(f), before);
});

test('pending and stored blocked inspections omit purchaser without changing legacy rows', async () => {
  const f = await setup(false); const before = state(f);
  assert.equal((await f.make().inspectDeviceAuthority()).state, 'pending');
  assert.equal((await f.make().inspectDeviceAuthority()).ownerEmail, null);
  assert.deepEqual(state(f), before);
  f.storage.data.get('order').blocked = true;
  const blockedBefore = state(f);
  assert.equal((await f.make().inspectDeviceAuthority()).state, 'blocked');
  assert.deepEqual(state(f), blockedBefore);
});

for (const [label, modify] of [
  ['partial refund', f => { f.stripe.ch.amount_refunded = 1; }],
  ['dispute', f => { f.stripe.ch.disputed = true; }],
  ...['pending', 'requires_action', 'succeeded', 'failed', 'canceled'].map(status =>
    [`${status} refund attempt`, f => { f.stripe.refundRows = [{ status }]; }]),
]) test(`inspection conservatively blocks ${label} with no legacy tombstone write`, async () => {
  const f = await setup(); modify(f); const before = state(f);
  const result = await f.make().inspectDeviceAuthority();
  assert.equal(result.state, 'blocked'); assert.equal(result.ownerEmail, null);
  assert.deepEqual(state(f), before);
});

test('inspection retains account/session/items/payment/charge/refund validation and exact links', async () => {
  for (const mutate of [
    f => { f.stripe.a.id = 'acct_Foreign'; },
    f => { f.stripe.s.metadata.cliphoard_order = 'foreign'; },
    f => { f.stripe.items.data[0].price.id = 'price_Foreign'; },
    f => { f.stripe.s.success_url = 'https://purchase.example/fake'; },
    f => { f.stripe.pi.amount_received = 999; },
    f => { f.stripe.ch.captured = false; },
    f => { f.stripe.refunds = async () => ({ object: 'invalid' }); },
    f => { f.stripe.s.customer_details.email = 'bad\r\naddress'; },
  ]) {
    const f = await setup(); mutate(f); const before = state(f);
    await assert.rejects(f.make().inspectDeviceAuthority());
    assert.deepEqual(state(f), before);
  }
});

test('legacy drain still persists attempt and arms recovery before any authenticated reads', async () => {
  const f = await setup(); await f.service().paid(f.ref, f.stripe.s.id);
  const events = [], put = f.storage.put.bind(f.storage), account = f.stripe.account.bind(f.stripe);
  f.storage.put = async (key, value) => { events.push(`put:${value.mail.attempts}`); await put(key, value); };
  f.stripe.account = async () => { events.push('account'); return account(); };
  const service = orderService({ ...f, schedule: async () => events.push('schedule') });
  await service.drain();
  assert.deepEqual(events.slice(0, 3), ['put:1', 'schedule', 'account']);
});

test('new inspection boundary sanitizes Stripe and storage rejections without leaking sentinel data', async () => {
  for (const dependency of ['stripe', 'storage']) {
    const f = await setup(), service = f.make();
    const reject = async () => { throw Object.assign(Error('private-sentinel-provider-body'), { code: 'private-sentinel-code' }); };
    if (dependency === 'stripe') f.stripe.account = reject; else f.storage.get = reject;
    await assert.rejects(service.inspectDeviceAuthority(), error => error.code === 'device_authority_unavailable'
      && error.message === 'device_authority_unavailable' && !JSON.stringify(error).includes('sentinel'));
  }
});
