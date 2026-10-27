import test from 'node:test';
import assert from 'node:assert/strict';
import { createDeliveryRunner } from '../delivery-runner.mjs';
import { createNativeMailDelivery } from '../native-mail.mjs';
import { deliveryFixture, gate } from './delivery-fixtures.mjs';

const operational = Object.freeze({ maximumAttemptsPerInvocation: 2, maxPendingOperations: 4, invocationBudgetMilliseconds: 1000,
  prearmDelayMilliseconds: 5000, retryDelayMilliseconds: 7000, continuationDelayMilliseconds: 1000 });
function runner(f, mail = { hasUnsettledSend: () => false }, overrides = {}) {
  return createDeliveryRunner({ enabled: true, makeService: () => f.service, alarmStorage: f.alarmStorage,
    mail, clockMilliseconds: () => f.state.milliseconds, monotonicMilliseconds: () => performance.now(), operational, ...overrides });
}
function native(f, send) {
  const mail = createNativeMailDelivery({ enabled: true, entitlementID: f.id, trustedIssuers: f.trust,
    from: 'support@example.invalid', replyTo: 'support@example.invalid', timeoutMilliseconds: 15, send });
  f.state.deliver = context => Object.hasOwn(context, 'token') ? mail.deliverApproval(context) : mail.deliverReceipt(context);
  return mail;
}

test('runner construction and default-off methods touch no dependency', async () => {
  let reads = 0;
  const disabled = createDeliveryRunner({ get makeService() { reads++; throw new Error('private'); } });
  for (const method of ['begin','approve','alarm','recover','observeEntitlement','observeAdmission'])
    await assert.rejects(disabled[method]({}), { code: 'runner_disabled' });
  const active = createDeliveryRunner({ enabled: true, makeService() { reads++; throw new Error('private'); },
    alarmStorage: { getAlarm() { reads++; }, setAlarm() { reads++; }, deleteAlarm() { reads++; }, sync() { reads++; } },
    mail: { hasUnsettledSend() { reads++; } }, clockMilliseconds() { reads++; },
    monotonicMilliseconds() { reads++; }, operational });
  assert.ok(active); assert.equal(reads, 0);
});

test('prearm failure prevents enqueue; successful commands queue without inline delivery', async t => {
  const f = await deliveryFixture(t), run = runner(f);
  f.state.failAlarm = true;
  await assert.rejects(run.begin(f.input()), { code: 'runner_unavailable', message: 'runner_unavailable' });
  assert.equal(f.service.snapshot().challenges, 0);
  f.state.failAlarm = false;
  await run.begin(f.input());
  assert.equal(f.service.snapshot().pending, 1); assert.equal(f.contexts.length, 0);
  assert.ok(await f.alarmStorage.getAlarm());
});

test('durable prearm survives interrupted setup and committed-before-response restart', async t => {
  const f = await deliveryFixture(t); let run = runner(f);
  f.state.afterArm = () => { throw new Error('synthetic crash after durable alarm'); };
  await assert.rejects(run.begin(f.input()), { code: 'runner_unavailable' });
  assert.ok(await f.alarmStorage.getAlarm()); assert.equal(f.service.snapshot().challenges, 0);
  f.state.afterArm = undefined; f.restart(); run = runner(f);
  await run.alarm(); assert.equal(await f.alarmStorage.getAlarm(), null);
  f.state.failSQL = 'INSERT INTO device_licence_outbox';
  await assert.rejects(run.begin(f.input()), { code: 'runner_unavailable' });
  assert.equal(f.service.snapshot().challenges, 0); assert.ok(await f.alarmStorage.getAlarm());
  // Fail only the final command acknowledgement, after its atomic outbox commit.
  const original = f.service, command = f.input();
  run = runner(f, undefined, { makeService: () => ({ ...original, begin: async input => {
    await original.begin(input); throw new Error('synthetic response lost after commit');
  } }) });
  await assert.rejects(run.begin(command), { code: 'runner_unavailable' });
  assert.equal(f.service.snapshot().pending, 1); assert.ok(await f.alarmStorage.getAlarm());
  f.restart(); run = runner(f);
  await run.recover(); assert.equal(f.contexts.length, 0);
  await run.alarm(); assert.equal(f.contexts.length, 1);
  assert.equal(await f.alarmStorage.getAlarm(), null);
});

test('alarm cleanup serializes with a queued enqueue so its wake cannot be deleted', async t => {
  const f = await deliveryFixture(t), run = runner(f), entered = gate(), release = gate();
  await f.alarmStorage.setAlarm(f.state.milliseconds + 5000);
  f.state.beforeDelete = async () => { entered.resolve(); await release.promise; };
  const cleanup = run.recover(); await entered.promise;
  const queued = run.begin(f.input());
  assert.equal(f.service.snapshot().pending, 0);
  release.resolve(); await cleanup; await queued;
  assert.equal(f.service.snapshot().pending, 1); assert.ok(await f.alarmStorage.getAlarm());
});

test('consumed alarm rearms while begin is paused, before later commit and recreation', async t => {
  const f = await deliveryFixture(t), sealing = gate(), releaseSeal = gate(), committed = gate(), abandoned = gate();
  f.state.sealGate = async () => { sealing.resolve(); await releaseSeal.promise; };
  const service = f.service;
  const run = runner(f, undefined, { makeService: () => ({ ...service, begin: async input => {
    const result = await service.begin(input); committed.resolve(); await abandoned.promise; return result;
  } }) });
  // These never-resumed continuations model the discarded old incarnation; they
  // hold no timer/process and cannot touch the database after recreation below.
  run.begin(f.input()).catch(() => {});
  await sealing.promise;
  await f.alarmStorage.deleteAlarm(); // Runtime consumes the wake before JS entry.
  run.alarm().catch(() => {});
  await new Promise(resolve => setImmediate(resolve));
  assert.ok(await f.alarmStorage.getAlarm(), 'alarm entry must durably rearm before waiting on begin');
  releaseSeal.resolve(); await committed.promise;
  assert.equal(f.service.snapshot().pending, 1);
  assert.ok(await f.alarmStorage.getAlarm());
  f.restart(); const resumed = runner(f);
  await resumed.recover(); await resumed.alarm();
  assert.equal(f.service.snapshot().accepted, 1); assert.equal(f.contexts.length, 1);
});

test('bounded invocation drains only its allowance and retains wake for ready pending work', async t => {
  const f = await deliveryFixture(t), run = runner(f);
  for (let i = 0; i < 3; i++) await run.begin(f.input());
  await run.alarm();
  assert.equal(f.contexts.length, 2); assert.equal(f.service.snapshot().pending, 1);
  assert.ok(await f.alarmStorage.getAlarm());
  await run.alarm();
  assert.equal(f.contexts.length, 3); assert.equal(await f.alarmStorage.getAlarm(), null);
});

test('earlier wake is retained; unexpired leases are not claimed or immediately spun on', async t => {
  const f = await deliveryFixture(t), run = runner(f), earlier = f.state.milliseconds + 100;
  await f.alarmStorage.setAlarm(earlier); await run.begin(f.input());
  assert.equal(await f.alarmStorage.getAlarm(), earlier);
  f.state.deliver = async () => { throw new Error('synthetic lost ack'); };
  // Simulate the runtime consuming the earlier alarm before entering its handler.
  await f.alarmStorage.deleteAlarm(); await run.alarm();
  const attempts = f.db.prepare('SELECT count(*) AS n FROM device_licence_delivery_attempts').get().n;
  assert.equal(await f.alarmStorage.getAlarm(), f.state.milliseconds + 30000);
  await run.alarm();
  assert.equal(f.db.prepare('SELECT count(*) AS n FROM device_licence_delivery_attempts').get().n, attempts);
  assert.ok((await f.alarmStorage.getAlarm()) > f.state.milliseconds);
});

test('stuck native send keeps one slot across alarms; recreation retries identical content after lease', async t => {
  const f = await deliveryFixture(t), underlying = gate(), sent = [];
  let mail = native(f, message => { sent.push(message); return underlying.promise; });
  let run = runner(f, mail);
  await run.begin(f.input()); await run.alarm();
  assert.equal(mail.hasUnsettledSend(), true); assert.equal(sent.length, 1);
  f.state.milliseconds += 31000;
  for (let i = 0; i < 4; i++) await run.alarm();
  assert.equal(sent.length, 1);
  assert.equal(f.db.prepare('SELECT count(*) AS n FROM device_licence_delivery_attempts').get().n, 1);
  assert.ok(await f.alarmStorage.getAlarm());
  f.restart();
  mail = native(f, async message => { sent.push(message); return { messageId: 'synthetic-restarted' }; });
  run = runner(f, mail); await run.recover(); await run.alarm();
  assert.equal(sent.length, 2); assert.deepEqual(sent[0], sent[1]);
  assert.equal(f.service.snapshot().accepted, 1); assert.equal(f.service.snapshot().uncertain, 1);
  underlying.resolve({ messageId: 'synthetic-late-accepted' });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.service.snapshot().accepted, 1);
});

test('trusted refund/admission observations stay immediate while mail is pending', async t => {
  const f = await deliveryFixture(t), entered = gate(), release = gate();
  f.state.deliver = async () => { entered.resolve(); await release.promise; return { accepted: true }; };
  const run = runner(f); await run.begin(f.input()); const delivering = run.alarm();
  await entered.promise;
  f.state.fence = { id: f.id, revision: 2, status: 'blocked' };
  await run.observeEntitlement({ ...f.fact(), revision: 2, status: 'blocked' });
  await run.observeAdmission({ entitlementID: f.id, revision: 2, decision: 'hold' });
  assert.equal(f.service.snapshot().cancelled, 1);
  release.resolve(); await delivering;
  assert.equal(f.service.snapshot().cancelled, 1); assert.equal(f.service.snapshot().accepted, 0);
});

test('actual service begin, native approval, signed approval and receipt retry use one committed receipt', async t => {
  const f = await deliveryFixture(t), sent = [];
  const mail = native(f, async message => { sent.push(message); return { messageId: 'synthetic-accepted' }; });
  const run = runner(f, mail), input = f.input();
  const first = await run.begin(input), duplicate = await run.begin(input);
  assert.deepEqual(first, duplicate); assert.equal(sent.length, 0);
  await run.alarm(); const request = await f.approval(first.challenge);
  const issued = await run.approve(request), again = await run.approve(request);
  assert.equal(issued.receipt, again.receipt); assert.equal(f.signatures.length, 1);
  await run.observeAdmission({ entitlementID: f.id, revision: 2, decision: 'hold' });
  await run.alarm();
  assert.equal(sent.length, 2); assert.equal(sent[1].text.includes(issued.receipt), true);
  assert.equal(f.signatures.length, 1); assert.equal(await f.alarmStorage.getAlarm(), null);
});

test('post-verification lease denial remains conservatively uncertain with zero provider sends', async t => {
  const f = await deliveryFixture(t), sent = [];
  const mail = native(f, async value => { sent.push(value); return { messageId: 'synthetic' }; });
  f.state.deliver = async context => {
    f.state.fence = { id: f.id, revision: 2, status: 'blocked' };
    return mail.deliverApproval(context);
  };
  const run = runner(f, mail); await run.begin(f.input()); await run.alarm();
  assert.equal(sent.length, 0); assert.equal(f.service.snapshot().uncertain, 1);
});

test('authority fence stops dispatch but terminal feed is needed to cancel work and remove its wake', async t => {
  const f = await deliveryFixture(t), run = runner(f);
  await run.begin(f.input());
  f.state.fence = { id: f.id, revision: 2, status: 'blocked' };
  await run.alarm();
  assert.equal(f.contexts.length, 0); assert.equal(f.service.snapshot().pending, 1);
  assert.ok(await f.alarmStorage.getAlarm());
  await run.observeEntitlement({ ...f.fact(), revision: 2, status: 'blocked' });
  await run.recover();
  assert.equal(f.service.snapshot().cancelled, 1); assert.equal(await f.alarmStorage.getAlarm(), null);
});

test('finite capacity rejects excess commands and coalesces alarm floods while work is paused', async t => {
  const f = await deliveryFixture(t), entered = gate(), release = gate();
  f.state.sealGate = async () => { entered.resolve(); await release.promise; };
  const run = runner(f, undefined, { operational: { ...operational, maxPendingOperations: 2 } });
  const first = run.begin(f.input()); await entered.promise;
  const second = run.begin(f.input());
  await assert.rejects(run.begin(f.input()), { code: 'runner_busy', message: 'runner_busy' });
  await assert.rejects(run.recover(), { code: 'runner_busy' });
  await f.alarmStorage.deleteAlarm();
  const alarm = run.alarm();
  for (let i = 0; i < 100; i++) assert.equal(run.alarm(), alarm);
  await new Promise(resolve => setImmediate(resolve));
  assert.ok(await f.alarmStorage.getAlarm());
  release.resolve(); await Promise.all([first, second, alarm]);
  assert.equal(f.service.snapshot().challenges, 2);
  assert.equal(f.service.snapshot().accepted, 2);
});

test('monotonic soft budget survives epoch reversal and stops on monotonic regression', async t => {
  for (const regress of [false, true]) {
    const f = await deliveryFixture(t); let monotonic = 100;
    const run = runner(f, undefined, { monotonicMilliseconds: () => monotonic,
      operational: { ...operational, maximumAttemptsPerInvocation: 3 } });
    for (let i = 0; i < 3; i++) await run.begin(f.input());
    f.state.deliver = async () => {
      f.state.milliseconds -= 5000;
      monotonic = regress ? 99 : 1101;
      return { accepted: true };
    };
    await run.alarm();
    assert.equal(f.contexts.length, 1);
    assert.equal(f.service.snapshot().pending, 2); assert.ok(await f.alarmStorage.getAlarm());
  }
});

test('lifecycle hooks refresh after durable prearm for commands, recover and empty alarms', async t => {
  const f = await deliveryFixture(t), observed = [];
  const run = runner(f, undefined, { refreshFeeds: async () => {
    assert.ok(await f.alarmStorage.getAlarm()); observed.push('refresh');
  }, isTerminalAuthority: () => false });
  await run.recover(); assert.deepEqual(observed, ['refresh']);
  await run.alarm(); assert.equal(observed.length, 2);
  await run.begin(f.input()); assert.equal(observed.length, 3);
  assert.equal(f.contexts.length, 0);
});

test('lifecycle hook failure retains a durable wake and prevents cached-active commands or delivery', async t => {
  const f = await deliveryFixture(t); await f.service.begin(f.input());
  const run = runner(f, undefined, { refreshFeeds: async () => { throw new Error('private dependency'); } });
  for (const operation of [() => run.begin(f.input()), () => run.recover(), () => run.alarm()]) {
    await assert.rejects(operation(), { code: 'runner_unavailable', message: 'runner_unavailable' });
    assert.ok(await f.alarmStorage.getAlarm());
  }
  assert.equal(f.service.snapshot().challenges, 1); assert.equal(f.contexts.length, 0);
});

test('lifecycle terminal cleanup bypasses paused signing but stale blocked notification and hold preserve prearm', async t => {
  const f = await deliveryFixture(t), entered = gate(), release = gate();
  const run = runner(f, undefined, { isTerminalAuthority: () => f.state.fence.status === 'blocked' });
  const first = await run.begin(f.input()); await run.alarm();
  const request = await f.approval(first.challenge);
  f.state.signGate = async () => { entered.resolve(); await release.promise; };
  const approving = assert.rejects(run.approve(request), { code: 'runner_unavailable' });
  await entered.promise;
  await run.observeAdmission({ entitlementID: f.id, revision: 2, decision: 'hold' });
  assert.ok(await f.alarmStorage.getAlarm(), 'hold must not delete prearm');
  // An old blocked observation cannot authorize deletion while the current
  // same-ledger fence is active; here its revision is stale to the ledger too.
  await run.observeEntitlement({ ...f.fact(), revision: 2 });
  await run.observeEntitlement({ ...f.fact(), revision: 1, status: 'blocked' });
  assert.ok(await f.alarmStorage.getAlarm(), 'stale notification must not delete prearm');
  f.state.fence = { id: f.id, revision: 3, status: 'blocked' };
  await run.observeEntitlement({ ...f.fact(), revision: 3, status: 'blocked' });
  assert.equal(await f.alarmStorage.getAlarm(), null, 'terminal feed cleans wake before signer resumes');
  release.resolve(); await approving;
  assert.equal(f.service.snapshot().issued, 0);
});

test('lifecycle terminal probe is checked inside wake chain and failing or nonboolean probes never clear wake', async t => {
  for (const outcome of ['throws', 'promise', 'false']) {
    const f = await deliveryFixture(t);
    await f.alarmStorage.setAlarm(f.state.milliseconds + 5000);
    const run = runner(f, undefined, { isTerminalAuthority: () => {
      if (outcome === 'throws') throw new Error('private');
      return outcome === 'promise' ? Promise.resolve(true) : false;
    } });
    const feed = run.observeEntitlement({ ...f.fact(), revision: 2, status: 'blocked' });
    if (outcome === 'false') await feed;
    else await assert.rejects(feed, { code: 'runner_unavailable' });
    assert.ok(await f.alarmStorage.getAlarm());
  }
  const f = await deliveryFixture(t), entered = gate(), release = gate();
  let terminal = true;
  f.state.afterArm = async () => { entered.resolve(); await release.promise; };
  const run = runner(f, undefined, { isTerminalAuthority: () => terminal });
  const command = run.begin(f.input()); await entered.promise;
  const feed = run.observeEntitlement({ ...f.fact(), revision: 2, status: 'blocked' });
  terminal = false; release.resolve(); await feed;
  await assert.rejects(command, { code: 'runner_unavailable' });
  assert.ok(await f.alarmStorage.getAlarm());
});

test('lifecycle hook options reject accessors and unknown fields without invocation', async t => {
  const f = await deliveryFixture(t); let calls = 0;
  const options = { enabled: true, makeService: () => f.service, alarmStorage: f.alarmStorage,
    mail: { hasUnsettledSend: () => false }, clockMilliseconds: () => f.state.milliseconds,
    monotonicMilliseconds: () => 1, operational };
  for (const field of ['refreshFeeds', 'isTerminalAuthority']) {
    const bad = { ...options };
    Object.defineProperty(bad, field, { enumerable: true, get() { calls++; return () => true; } });
    assert.throws(() => createDeliveryRunner(bad), { code: 'runner_configuration' });
    assert.throws(() => createDeliveryRunner({ ...options, [field]: true }), { code: 'runner_configuration' });
  }
  assert.equal(calls, 0);
});
