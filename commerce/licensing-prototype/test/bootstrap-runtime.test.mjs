import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { createDeviceBootstrapSealer } from '../bootstrap-custody.mjs';
import { createDeviceLicenceAlarmMultiplexer } from '../bootstrap-alarm.mjs';

const key = () => crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
test('disabled custody and scheduler never inspect dependencies', async () => {
  const options = { enabled: false, get key() { throw Error('read'); }, get storage() { throw Error('read'); } };
  await assert.rejects(createDeviceBootstrapSealer(options).seal('secret', 'context'));
  await assert.rejects(createDeviceLicenceAlarmMultiplexer(options).recover());
  assert.throws(() => createDeviceBootstrapSealer({ get enabled() { throw Error('read'); } }), /configuration/);
});
test('authenticated custody conceals the whole descriptor and binds context and key ID', async () => {
  const aes = await key(), first = createDeviceBootstrapSealer({ enabled: true, keyID: 'test-one', key: aes });
  const plaintext = 'CLIPB1.synthetic-handle-bearing-descriptor', context = 'entitlement-A\nenvelope';
  const a = await first.seal(plaintext, context), b = await first.seal(plaintext, context);
  assert.notEqual(a, b); assert(!a.includes(plaintext));
  assert.equal(await first.open(a, context), plaintext);
  await assert.rejects(first.open(a, 'entitlement-B\nenvelope'));
  await assert.rejects(first.open(a, 'entitlement-A\npayload'));
  await assert.rejects(first.open(a.replace('test-one', 'test-two'), context));
  const sameKeyOtherID = createDeviceBootstrapSealer({ enabled: true, keyID: 'test-two', key: aes });
  await assert.rejects(sameKeyOtherID.open(a.replace('test-one', 'test-two'), context));
  const differentKey = createDeviceBootstrapSealer({ enabled: true, keyID: 'test-one', key: await key() });
  await assert.rejects(differentKey.open(a, context));
});
test('custody rejects tampering, noncanonical wire data and oversized or lossy text', async () => {
  const sealer = createDeviceBootstrapSealer({ enabled: true, keyID: 'test', key: await key() });
  const sealed = await sealer.seal('private setup', 'context');
  const parts = sealed.split('.'), bytes = Buffer.from(parts[3], 'base64url'); bytes[0] ^= 1;
  await assert.rejects(sealer.open([...parts.slice(0, 3), bytes.toString('base64url')].join('.'), 'context'));
  await assert.rejects(sealer.open(sealed + '=', 'context'));
  await assert.rejects(sealer.seal('x'.repeat(2049), 'context'));
  await assert.rejects(sealer.seal('\ud800', 'context'));
  await assert.rejects(sealer.seal('valid', '\ud800'));
  await assert.rejects(sealer.open(sealed, ''));
});
test('custody accepts only an independently supplied nonextractable AES256 key', async () => {
  const extractable = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, true, ['encrypt', 'decrypt']);
  const short = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 128 }, false, ['encrypt', 'decrypt']);
  for (const invalid of [extractable, short, {}, 'key-value'])
    assert.throws(() => createDeviceBootstrapSealer({ enabled: true, keyID: 'test', key: invalid }), /configuration/);
  const options = { enabled: true, keyID: 'test', key: await key() };
  const captured = createDeviceBootstrapSealer(options); options.key = await key(); options.keyID = 'changed';
  const sealed = await captured.seal('stable', 'context');
  assert.equal(await captured.open(sealed, 'context'), 'stable');
});

function fixture() {
  const db = new DatabaseSync(':memory:'); let physical = null, time = 100000, rejectSet = false, effects = 0;
  const sql = { exec(query, ...args) { return db.prepare(query).all(...args); } };
  const storage = { sql, transactionSync(fn) {
    db.exec('BEGIN'); try { const result = fn(); db.exec('COMMIT'); return result; }
    catch (error) { db.exec('ROLLBACK'); throw error; }
  }, sync: async () => {} };
  const physicalAlarm = { getAlarm: async () => physical,
    setAlarm: async value => { effects++; if (rejectSet) throw Error('physical unavailable'); physical = value; },
    deleteAlarm: async () => { effects++; physical = null; }, sync: async () => {} };
  let activation = async () => {}, bootstrap = async () => {};
  const make = () => createDeviceLicenceAlarmMultiplexer({ enabled: true, storage, physicalAlarm,
    clockMilliseconds: () => time, recoveryDelayMilliseconds: 100,
    handlers: { activation: () => activation(), bootstrap: () => bootstrap() } });
  return { db, make, physical: () => physical, consume: () => { physical = null; },
    advance: value => { time = value; }, failSet: value => { rejectSet = value; },
    effects: () => effects, handlers: (a, b) => { activation = a; bootstrap = b; } };
}
test('one channel cannot delete another channel wake; reconstruction retains schedule', async () => {
  const f = fixture(); const mux = f.make(); assert.equal(f.effects(), 0);
  await mux.activation.setAlarm(100500); await mux.bootstrap.setAlarm(100300);
  assert.equal(f.physical(), 100300);
  await mux.bootstrap.deleteAlarm(); assert.equal(f.physical(), 100500);
  const fresh = f.make(); assert.equal(await fresh.activation.getAlarm(), 100500);
  assert.equal(await fresh.bootstrap.getAlarm(), null);
  await fresh.recover(); assert.equal(f.physical(), 100500); f.db.close();
});
test('both due handlers run after a durable guard; completion clears only its own channel', async () => {
  const f = fixture(), mux = f.make(); let a = 0, b = 0;
  f.handlers(async () => { a++; assert.notEqual(f.physical(), null); await mux.activation.deleteAlarm(); },
    async () => { b++; assert.notEqual(f.physical(), null); await mux.bootstrap.deleteAlarm(); });
  await mux.activation.setAlarm(100001); await mux.bootstrap.setAlarm(100001);
  f.advance(100002); f.consume(); await mux.alarm();
  assert.equal(a, 1); assert.equal(b, 1); assert.equal(f.physical(), null); f.db.close();
});
test('a consumed wake behind unsettled work rearms without duplicate handler entry', async () => {
  const f = fixture(), mux = f.make(); let entered = 0, release;
  const paused = new Promise(resolve => { release = resolve; });
  f.handlers(async () => { entered++; await paused; await mux.activation.deleteAlarm(); }, async () => {});
  await mux.activation.setAlarm(100001); f.advance(100002); f.consume(); const running = mux.alarm();
  while (entered === 0) await new Promise(resolve => setImmediate(resolve));
  f.advance(100200); f.consume(); await mux.alarm();
  assert.equal(entered, 1); assert(f.physical() > 100200);
  release(); await running; assert.equal(f.physical(), null); f.db.close();
});
test('failed handler after clearing logical work retains a durable recovery guard', async () => {
  const f = fixture(), mux = f.make();
  f.handlers(async () => { await mux.activation.deleteAlarm(); throw Error('lost outcome'); }, async () => {});
  await mux.activation.setAlarm(100001); f.advance(100002); f.consume();
  await assert.rejects(mux.alarm(), /dispatch/); assert(f.physical() > 100002);
  const recreated = f.make(); let recovered = 0;
  f.handlers(async () => { recovered++; await recreated.activation.deleteAlarm(); }, async () => {});
  f.advance(100200); f.consume(); await recreated.alarm();
  assert.equal(recovered, 1); assert.equal(f.physical(), null); f.db.close();
});
test('failed prearm refuses a new logical schedule and does not dispatch', async () => {
  const f = fixture(), mux = f.make(); f.failSet(true); let entered = 0;
  f.handlers(async () => { entered++; }, async () => { entered++; });
  await assert.rejects(mux.bootstrap.setAlarm(100050));
  assert.equal(await mux.bootstrap.getAlarm(), null);
  await assert.rejects(mux.alarm()); assert.equal(entered, 0); f.db.close();
});
