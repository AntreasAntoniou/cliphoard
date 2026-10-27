import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { mkdtemp, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { createDeviceLicenceServerLifecycle } from '../server-lifecycle.mjs';
import { syntheticKey } from './fixtures.mjs';
import { gate } from './delivery-fixtures.mjs';
import { randomToken, base64url, decode, tokenDigest, approvalMessage, signReceipt } from '../protocol.mjs';

const origin = 'https://synthetic.invalid';
const operational = Object.freeze({ maximumAttemptsPerInvocation: 2, maxPendingOperations: 4,
  invocationBudgetMilliseconds: 1000, prearmDelayMilliseconds: 5000,
  retryDelayMilliseconds: 7000, continuationDelayMilliseconds: 1000 });
const fields = ['enabled', 'storage', 'binding', 'inspectDeviceAuthority', 'issuer', 'tokenCustody',
  'admission', 'mail', 'alarmStorage', 'clocks', 'limits', 'operational', 'http'];
const tick = () => new Promise(resolve => setImmediate(resolve));

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'cliphoard-lifecycle-'));
  let db;
  t.after(async () => { db?.close(); await rm(directory, { recursive: true }); });
  const issuer = await syntheticKey(), device = await syntheticKey();
  const sealKey = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
  const id = randomToken(16), handle = randomToken(32), sends = [], signatures = [];
  const scope = { accountId: 'acct_Synthetic', mode: 'test', orderRef: '00000000-0000-4000-8000-000000000001',
    sessionId: 'cs_test_Synthetic', productId: 'prod_Synthetic', priceId: 'price_Synthetic',
    currency: 'gbp', unitAmount: 1000, taxBehavior: 'inclusive' };
  const binding = { entitlementID: id, entitlementHandleDigest: await tokenDigest(handle), ...scope };
  const state = { milliseconds: 1767323045000, status: 'active', ownerEmail: 'buyer@example.invalid',
    admissionRevision: 1, decision: 'allow', sqlCalls: 0, alarmCalls: 0, reads: 0, admissions: 0 };
  const fact = () => ({ ...scope, state: state.status, ownerEmail: state.status === 'active' ? state.ownerEmail : null });
  const currentAdmission = () => ({ entitlementID: id, revision: state.admissionRevision, decision: state.decision });
  let options, lifecycle, alarmStorage;
  function open() {
    db = new DatabaseSync(join(directory, 'ledger.sqlite'));
    db.exec('PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=1000;');
    db.exec('CREATE TABLE IF NOT EXISTS synthetic_alarm (singleton INTEGER PRIMARY KEY, time INTEGER)');
    const storage = {
      sql: { exec: (query, ...args) => { state.sqlCalls++; return db.prepare(query).all(...args); } },
      transactionSync(action) {
        db.exec('BEGIN IMMEDIATE');
        try { const result = action(); assert(!result?.then); db.exec('COMMIT'); return result; }
        catch (error) { db.exec('ROLLBACK'); throw error; }
      }, async sync() {},
    };
    alarmStorage = {
      async getAlarm() { state.alarmCalls++; return db.prepare('SELECT time FROM synthetic_alarm').get()?.time ?? null; },
      async setAlarm(time) {
        state.alarmCalls++; if (state.failAlarm) throw Error('private scheduler detail');
        db.prepare('INSERT INTO synthetic_alarm VALUES(1,?) ON CONFLICT(singleton) DO UPDATE SET time=excluded.time').run(time);
      },
      async deleteAlarm() { state.alarmCalls++; db.prepare('DELETE FROM synthetic_alarm WHERE singleton=?').run(1); }, async sync() {},
    };
    options = { enabled: true, storage, binding: { ...binding },
      inspectDeviceAuthority: async () => {
        state.reads++; if (state.failRead) throw Error('private provider detail');
        return state.inspect ? state.inspect() : fact();
      },
      issuer: { issuerKeyID: 'synthetic-lifecycle', issuerPublicKey: issuer.publicKey, sign: async value => {
        signatures.push(structuredClone(value)); const receipt = await signReceipt(value, issuer.privateKey);
        await state.signGate?.(); return receipt;
      } },
      tokenCustody: {
        sealToken: async (token, aad) => {
          const iv = crypto.getRandomValues(new Uint8Array(12));
          const bytes = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv,
            additionalData: new TextEncoder().encode(aad) }, sealKey, new TextEncoder().encode(token)));
          await state.sealGate?.(); return base64url(new Uint8Array([...iv, ...bytes]));
        },
        openToken: async (value, aad) => {
          const bytes = decode(value, undefined, 2048);
          return new TextDecoder().decode(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: bytes.slice(0, 12),
            additionalData: new TextEncoder().encode(aad) }, sealKey, bytes.slice(12)));
        },
      },
      admission: {
        evaluate: async () => ({ revision: state.admissionRevision, decision: state.decision }),
        readCurrent: async () => {
          state.admissions++; if (state.failAdmission) throw Error('private admission detail');
          return state.readAdmission ? state.readAdmission() : currentAdmission();
        },
      },
      mail: { from: 'support@example.invalid', replyTo: 'support@example.invalid', timeoutMilliseconds: 500,
        send: async message => { sends.push(message); await state.sendGate?.(); return { messageId: 'synthetic-message' }; } },
      alarmStorage, clocks: { epochMilliseconds: () => state.milliseconds, monotonicMilliseconds: () => performance.now() },
      limits: { challengeTTLSeconds: 600, deliveryLeaseSeconds: 30 }, operational: { ...operational },
      http: { origin, bodyTimeoutMs: 100 },
    };
    lifecycle = createDeviceLicenceServerLifecycle(options);
  }
  open();
  const beginBody = () => ({ entitlementHandle: handle, devicePublicKey: device.publicKey, requestID: randomToken(16) });
  const call = async (route, body, method = 'POST') => {
    const response = await lifecycle.handle(new Request(`${origin}/device-licensing/v1/${route}`, {
      method, ...(body ? { body: JSON.stringify(body), headers: { 'content-type': 'application/json' } } : {}),
    }));
    return { status: response.status, body: method === 'HEAD' ? null : await response.json() };
  };
  const approveBody = async challenge => {
    const token = sends.find(message => message.subject === 'Approve this Mac for Cliphoard Pro').text
      .match(/Approval code:\n([A-Za-z0-9_-]{43})\n/)[1];
    const approvalRequestID = randomToken(16);
    return { challengeID: challenge.challengeID, approvalToken: token, approvalRequestID,
      deviceSignature: base64url(await device.provider.signProof(approvalMessage(challenge, await tokenDigest(token), approvalRequestID))) };
  };
  const count = (table, where = '1=1') => db.prepare(`SELECT count(*) AS n FROM ${table} WHERE ${where}`).get().n;
  return { id, handle, state, sends, signatures, binding, fact, currentAdmission, beginBody, approveBody, call, count,
    get db() { return db; }, get options() { return options; }, get lifecycle() { return lifecycle; },
    get alarmStorage() { return alarmStorage; },
    restart() { db.close(); open(); },
  };
}

test('default-off lifecycle never evaluates dependencies, inherited opt-in or request opt-in', async () => {
  let calls = 0;
  for (const enabled of [undefined, false]) for (const field of fields.filter(key => key !== 'enabled')) {
    const options = enabled === undefined ? {} : { enabled };
    Object.defineProperty(options, field, { get() { calls++; throw Error('private'); } });
    const lifecycle = createDeviceLicenceServerLifecycle(options);
    assert.deepEqual(Object.keys(lifecycle).sort(), ['alarm', 'handle', 'recover', 'refreshAdmission', 'refreshAuthority']);
    assert(Object.isFrozen(lifecycle));
    const response = await lifecycle.handle(new Request(`${origin}/device-licensing/v1/begin?enabled=true`, { method: 'POST' }));
    assert.equal(response.status, 404);
    for (const name of ['alarm','recover','refreshAuthority','refreshAdmission'])
      await assert.rejects(lifecycle[name](), { code: 'lifecycle_disabled', message: 'lifecycle_disabled' });
  }
  const inherited = Object.create({ get enabled() { calls++; return true; } });
  assert.equal((await createDeviceLicenceServerLifecycle(inherited).handle(new Request(origin))).status, 404);
  assert.throws(() => createDeviceLicenceServerLifecycle({ get enabled() { calls++; return true; } }), { code: 'lifecycle_configuration' });
  assert.equal(calls, 0);
});

test('enabled lifecycle validates exact own-data nested bindings without getters or effects', async t => {
  const f = await fixture(t); let reads = 0;
  const paths = fields.filter(key => key !== 'enabled').map(key => [key]);
  for (const [parent, value] of Object.entries(f.options)) if (value && typeof value === 'object')
    for (const key of Object.keys(value)) paths.push([parent, key]);
  paths.push(['storage','sql','exec']);
  for (const path of paths) {
    const bad = { ...f.options }; let at = bad, original = f.options;
    for (const key of path.slice(0, -1)) { at[key] = { ...original[key] }; at = at[key]; original = original[key]; }
    Object.defineProperty(at, path.at(-1), { enumerable: true, get() { reads++; throw Error('private'); } });
    assert.throws(() => createDeviceLicenceServerLifecycle(bad), { code: 'lifecycle_configuration' }, path.join('.'));
  }
  assert.throws(() => createDeviceLicenceServerLifecycle({ ...f.options, unexpected: true }), { code: 'lifecycle_configuration' });
  assert.throws(() => createDeviceLicenceServerLifecycle({ ...f.options, admission: { evaluate: async () => 'allow' } }), { code: 'lifecycle_configuration' });
  assert.equal(reads, 0); assert.equal(f.state.sqlCalls, 0); assert.equal(f.state.reads, 0); assert.equal(f.state.alarmCalls, 0);
});

test('generic HTTP and malformed input do not initialize SQL, touch providers or prearm; no raw components escape', async t => {
  const f = await fixture(t);
  for (const [route, method] of [['confirmation','GET'],['confirmation','HEAD'],['begin','GET'],['approve','HEAD'],['approve','OPTIONS']]) {
    const response = await f.call(route, undefined, method); assert.notEqual(response.status, 503);
  }
  assert.equal((await f.call('begin', { ...f.beginBody(), eligibility: 'active' })).status, 400);
  assert.equal((await f.call('begin?token=private', f.beginBody())).status, 400);
  assert.equal(f.state.sqlCalls, 0); assert.equal(f.state.reads, 0); assert.equal(f.state.alarmCalls, 0);
  assert.deepEqual(Object.keys(f.lifecycle).sort(), ['alarm','handle','recover','refreshAdmission','refreshAuthority']);
  assert.equal(f.lifecycle.service, undefined); assert.equal(f.lifecycle.begin, undefined); assert.equal(f.lifecycle.deliverOne, undefined);
  for (const name of ['refreshAuthority','refreshAdmission','alarm','recover'])
    await assert.rejects(f.lifecycle[name]({ status: 'active' }), { code: 'lifecycle_rejected' });
  assert.equal(f.state.sqlCalls, 0); assert.equal(f.state.alarmCalls, 0);
  f.state.failAlarm = true;
  assert.equal((await f.call('begin', f.beginBody())).status, 503);
  assert.equal(f.state.sqlCalls, 0); assert.equal(f.state.reads, 0);
});

test('actual scoped HTTP composition queues native approval then issues one exact receipt and survives held replay', async t => {
  const f = await fixture(t), input = f.beginBody();
  const first = await f.call('begin', input), repeated = await f.call('begin', input);
  assert.equal(first.status, 200); assert.deepEqual(first, repeated); assert.equal(f.sends.length, 0);
  assert.equal(first.body.challenge.entitlementID, f.id); assert.ok(await f.alarmStorage.getAlarm());
  await f.lifecycle.alarm(); assert.equal(f.sends.length, 1); assert.equal(f.sends[0].to, 'buyer@example.invalid');
  const approval = await f.approveBody(first.body.challenge);
  const issued = await f.call('approve', approval); assert.equal(issued.status, 200); assert.equal(f.signatures.length, 1);
  f.state.decision = 'hold'; f.state.admissionRevision = 2; await f.lifecycle.refreshAdmission();
  const duplicate = await f.call('approve', approval);
  assert.equal(duplicate.status, 200); assert.equal(duplicate.body.code, 'already_issued');
  assert.equal(duplicate.body.receipt, issued.body.receipt); assert.equal(f.signatures.length, 1);
  await f.lifecycle.alarm(); assert.equal(f.sends.length, 2); assert(f.sends[1].text.includes(issued.body.receipt));
  assert.equal(await f.alarmStorage.getAlarm(), null);
  assert.deepEqual(Object.keys(issued.body).sort(), ['code','ok','receipt']);
});

test('captured purchase bindings cannot be changed by later options mutation or request facts', async t => {
  const f = await fixture(t), originalID = f.id;
  f.options.binding.entitlementID = randomToken(16); f.options.binding.priceId = 'price_Foreign';
  f.options.mail.send = () => { throw Error('mutated sender'); };
  f.options.admission.readCurrent = () => { throw Error('mutated authority'); };
  const first = await f.call('begin', f.beginBody());
  assert.equal(first.status, 200); assert.equal(first.body.challenge.entitlementID, originalID);
  await f.lifecycle.alarm(); assert.equal(f.sends.length, 1);
  const before = f.count('device_licence_challenges');
  assert.equal((await f.call('begin', { ...f.beginBody(), entitlementHandle: randomToken(32) })).status, 503);
  assert.equal(f.count('device_licence_challenges'), before);
  assert.equal(f.db.prepare('SELECT entitlement_id FROM device_licence_meta').get().entitlement_id, originalID);
});

test('unavailable refresh cannot use cached active authority and leaves a wake even with empty outbox', async t => {
  const f = await fixture(t); await f.lifecycle.recover();
  assert.equal(await f.alarmStorage.getAlarm(), null);
  f.state.failRead = true;
  assert.equal((await f.call('begin', f.beginBody())).status, 503);
  assert.equal(f.count('device_licence_challenges'), 0); assert.ok(await f.alarmStorage.getAlarm());
  await assert.rejects(f.lifecycle.alarm(), { code: 'lifecycle_unavailable', message: 'lifecycle_unavailable' });
  assert.ok(await f.alarmStorage.getAlarm()); assert.equal(f.sends.length, 0);
  f.state.failRead = false; f.state.failAdmission = true;
  await assert.rejects(f.lifecycle.recover(), { code: 'lifecycle_unavailable' });
  assert.ok(await f.alarmStorage.getAlarm());
  f.state.failAdmission = false; await f.lifecycle.recover(); assert.equal(await f.alarmStorage.getAlarm(), null);
});

test('pending authority is not terminal, does not cancel email and cannot dispatch from cached active', async t => {
  const f = await fixture(t); await f.call('begin', f.beginBody());
  f.state.status = 'pending';
  await assert.rejects(f.lifecycle.alarm(), { code: 'lifecycle_unavailable' });
  assert.equal(f.count('device_licence_outbox', "status='pending'"), 1);
  assert.ok(await f.alarmStorage.getAlarm()); assert.equal(f.sends.length, 0);
});

test('temporary hold blocks new issuance but preserves code delivery and exact pending retry after allow', async t => {
  const f = await fixture(t), input = f.beginBody();
  const first = await f.call('begin', input); assert.equal(first.status, 200);
  f.state.decision = 'hold'; f.state.admissionRevision = 2;
  await f.lifecycle.refreshAdmission();
  assert.equal(f.count('device_licence_outbox', "status='pending'"), 1);
  assert.ok(await f.alarmStorage.getAlarm());
  assert.equal((await f.call('begin', f.beginBody())).status, 503);
  await f.lifecycle.alarm(); assert.equal(f.sends.length, 1);
  const approval = await f.approveBody(first.body.challenge);
  assert.equal((await f.call('approve', approval)).status, 503); assert.equal(f.signatures.length, 0);
  assert.equal(f.count('device_licence_challenges'), 1);
  f.state.decision = 'allow'; f.state.admissionRevision = 3; await f.lifecycle.refreshAdmission();
  assert.equal((await f.call('approve', approval)).status, 200); assert.equal(f.signatures.length, 1);
});

test('terminal refund during paused signing fences commit and removes wake before signer resumes', async t => {
  const f = await fixture(t), entered = gate(), release = gate();
  const first = await f.call('begin', f.beginBody()); await f.lifecycle.alarm();
  const approval = await f.approveBody(first.body.challenge);
  f.state.signGate = async () => { entered.resolve(); await release.promise; };
  const pending = f.call('approve', approval); await entered.promise;
  assert.ok(await f.alarmStorage.getAlarm());
  f.state.status = 'blocked'; await f.lifecycle.refreshAuthority();
  assert.equal(await f.alarmStorage.getAlarm(), null);
  release.resolve(); assert.equal((await pending).status, 503);
  assert.equal(f.db.prepare('SELECT status FROM device_licence_meta').get().status, 'blocked');
  assert.equal(f.count('device_licence_outbox', "kind='receipt'"), 0);
  assert.equal(f.sends.length, 1);
});

test('terminal block during native send cancels leased email promptly; late acknowledgement cannot revive it', async t => {
  const f = await fixture(t), entered = gate(), release = gate();
  await f.call('begin', f.beginBody());
  f.state.sendGate = async () => { entered.resolve(); await release.promise; };
  const pending = f.lifecycle.alarm(); await entered.promise;
  f.state.status = 'blocked'; await f.lifecycle.refreshAuthority();
  assert.equal(f.count('device_licence_outbox', "status='cancelled'"), 1);
  assert.equal(await f.alarmStorage.getAlarm(), null);
  release.resolve(); await pending;
  assert.equal(f.sends.length, 1, 'already-entered native send is not recallable');
  assert.equal(f.count('device_licence_outbox', "status='accepted'"), 0);
});

test('reordered authority and admission refresh cannot undo terminal block or later hold', async t => {
  const f = await fixture(t); await f.call('begin', f.beginBody());
  const entered = gate(), release = gate(), stale = f.fact();
  let first = true;
  f.state.inspect = async () => {
    if (first) { first = false; entered.resolve(); await release.promise; return stale; }
    return f.fact();
  };
  const old = f.lifecycle.refreshAuthority(); await entered.promise;
  f.state.status = 'blocked'; await f.lifecycle.refreshAuthority(); release.resolve(); await old;
  assert.equal(f.db.prepare('SELECT status FROM device_licence_meta').get().status, 'blocked');
  assert.equal(await f.alarmStorage.getAlarm(), null);
  const enteredAdmission = gate(), releaseAdmission = gate(), staleAdmission = f.currentAdmission();
  first = true;
  f.state.readAdmission = async () => {
    if (first) { first = false; enteredAdmission.resolve(); await releaseAdmission.promise; return staleAdmission; }
    return f.currentAdmission();
  };
  const oldAdmission = f.lifecycle.refreshAdmission(); await enteredAdmission.promise;
  f.state.decision = 'hold'; f.state.admissionRevision = 2; await f.lifecycle.refreshAdmission();
  releaseAdmission.resolve(); await oldAdmission;
  const meta = f.db.prepare('SELECT admission_revision,admission_decision FROM device_licence_meta').get();
  assert.equal(meta.admission_revision, 2); assert.equal(meta.admission_decision, 'hold');
});

test('terminal observations discovered within service reads reach cancellation and wake cleanup', async t => {
  const f = await fixture(t); await f.call('begin', f.beginBody());
  let calls = 0;
  f.state.inspect = () => { if (++calls === 2) f.state.status = 'blocked'; return f.fact(); };
  assert.equal((await f.call('begin', f.beginBody())).status, 503);
  assert.equal(f.count('device_licence_outbox', "status='cancelled'"), 1);
  assert.equal(await f.alarmStorage.getAlarm(), null);
});

test('consumed alarm is rearmed while a command owns the slow queue', async t => {
  const f = await fixture(t), entered = gate(), release = gate();
  f.state.sealGate = async () => { entered.resolve(); await release.promise; };
  const command = f.call('begin', f.beginBody()); await entered.promise;
  await f.alarmStorage.deleteAlarm(); const alarm = f.lifecycle.alarm(); await tick();
  assert.ok(await f.alarmStorage.getAlarm());
  release.resolve(); assert.equal((await command).status, 200); await alarm;
  assert.equal(f.sends.length, 1); assert.equal(await f.alarmStorage.getAlarm(), null);
});

test('same-SQLite reconstruction refreshes feeds and dispatches pending receipt without re-signing', async t => {
  const f = await fixture(t); const first = await f.call('begin', f.beginBody());
  f.restart(); const before = f.state.reads; await f.lifecycle.recover();
  assert(f.state.reads > before); await f.lifecycle.alarm();
  const issued = await f.call('approve', await f.approveBody(first.body.challenge)); assert.equal(issued.status, 200);
  f.restart(); await f.lifecycle.recover(); await f.lifecycle.alarm();
  assert.equal(f.sends.length, 2); assert(f.sends[1].text.includes(issued.body.receipt));
  assert.equal(f.signatures.length, 1); assert.equal(await f.alarmStorage.getAlarm(), null);
});

test('recipient changes terminally block and dependency errors expose no private payload', async t => {
  const f = await fixture(t); await f.call('begin', f.beginBody());
  f.state.ownerEmail = 'different@example.invalid'; await f.lifecycle.refreshAuthority();
  assert.equal(f.count('device_licence_outbox', "status='cancelled'"), 1);
  assert.equal(await f.alarmStorage.getAlarm(), null); assert.equal(f.sends.length, 0);
  f.state.failRead = true;
  const response = await f.call('begin', f.beginBody());
  assert.deepEqual(response, { status: 503, body: { ok: false, code: 'temporarily_unavailable' } });
  await assert.rejects(f.lifecycle.refreshAuthority(), { code: 'lifecycle_unavailable', message: 'lifecycle_unavailable' });
});
