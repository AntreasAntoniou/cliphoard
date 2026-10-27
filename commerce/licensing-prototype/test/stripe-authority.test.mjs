import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { mkdtempSync, rmSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createStripeDeviceAuthority, createPinnedDeviceReceiptIssuer } from '../stripe-authority.mjs';
import { randomToken, tokenDigest, signReceipt, base64url, parseReceipt } from '../protocol.mjs';

const code = expected => error => error.code === expected && error.message === expected;
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
function database(path) {
  const db = new DatabaseSync(path);
  db.exec('PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=1000;');
  return { db, storage: {
    sql: { exec: (query, ...args) => db.prepare(query).all(...args) },
    transactionSync(action) {
      db.exec('BEGIN IMMEDIATE');
      try { const result = action(); assert(!result?.then); db.exec('COMMIT'); return result; }
      catch (error) { db.exec('ROLLBACK'); throw error; }
    },
    async sync() {},
  } };
}
async function fixture(t) {
  const dir = mkdtempSync(join(tmpdir(), 'cliphoard-authority-test-'));
  const path = join(dir, 'authority.sqlite'), connections = [];
  t.after(() => { for (const { db } of connections) { try { db.close(); } catch {} } rmSync(dir, { recursive: true }); });
  const open = () => { const connection = database(path); connections.push(connection); return connection; };
  const handle = randomToken(32), entitlementID = randomToken(16);
  const scope = { accountId: 'acct_Test', mode: 'test', orderRef: '00000000-0000-4000-8000-000000000001',
    sessionId: 'cs_test_Session', productId: 'prod_Pro', priceId: 'price_Pro', currency: 'gbp', unitAmount: 1000,
    taxBehavior: 'inclusive' };
  const binding = { entitlementID, entitlementHandleDigest: await tokenDigest(handle), ...scope };
  let fact = { ...scope, state: 'active', ownerEmail: 'buyer@example.invalid' }, calls = 0;
  const inspect = async () => { calls++; return structuredClone(fact); };
  const connection = open();
  const options = { enabled: true, storage: connection.storage, binding, inspectDeviceAuthority: inspect,
    admission: async () => ({ revision: 1, decision: 'allow' }) };
  const authority = createStripeDeviceAuthority(options);
  return { ...connection, open, path, handle, binding, scope, authority, options,
    setFact: value => { fact = value; }, getFact: () => structuredClone(fact), calls: () => calls };
}

test('default-off authority and issuer have zero storage/dependency effects', async () => {
  const trap = () => { throw Error('must not run'); };
  const authority = createStripeDeviceAuthority({ storage: { sql: { exec: trap }, transactionSync: trap, sync: trap },
    inspectDeviceAuthority: trap, admission: trap });
  for (const action of [() => authority.resolveEntitlement('anything'), () => authority.readEntitlement('anything'),
    () => authority.refreshAuthority(), () => authority.admission({})]) await assert.rejects(action(), code('prototype_disabled'));
  assert.throws(() => authority.readAuthorityFence(), code('prototype_disabled'));
  await assert.rejects(createPinnedDeviceReceiptIssuer({ sign: trap })({}), code('prototype_disabled'));
});

// Root-identified accessor extension AC01, independently reproduced after the
// initial review plan. These regressions are not claimed as plan-blind evidence.
const factoryDependencies = [
  [createStripeDeviceAuthority, ['storage', 'binding', 'inspectDeviceAuthority', 'admission']],
  [createPinnedDeviceReceiptIssuer, ['entitlementID', 'issuerKeyID', 'issuerPublicKey', 'sign']],
];
test('AC01 disabled factories do not evaluate any dependency option accessor', () => {
  for (const [factory, names] of factoryDependencies) {
    for (const name of names) for (const enabled of [false, undefined]) {
      let reads = 0;
      const options = enabled === undefined ? {} : { enabled };
      Object.defineProperty(options, name, { enumerable: true, get() {
        reads++; throw Error('synthetic disabled dependency effect');
      } });
      assert.doesNotThrow(() => factory(options)); assert.equal(reads, 0, name);
    }
  }
});

test('factory enabled opt-in is an own data property, never an evaluated or inherited getter', () => {
  for (const [factory] of factoryDependencies) {
    let reads = 0;
    const accessor = { get enabled() { reads++; return false; } };
    assert.throws(() => factory(accessor), code('configuration')); assert.equal(reads, 0);
    const inherited = Object.create({ get enabled() { reads++; return true; } });
    Object.defineProperty(inherited, 'storage', { get() { reads++; throw Error('must not read'); } });
    assert.doesNotThrow(() => factory(inherited)); assert.equal(reads, 0);
  }
});

test('enabled factory option shape rejects accessors and extensions before reading dependencies', () => {
  for (const [factory, names] of factoryDependencies) {
    const plain = Object.fromEntries(['enabled', ...names].map(name => [name, name === 'enabled' ? true : null]));
    for (const name of names) {
      let reads = 0; const options = { ...plain };
      Object.defineProperty(options, name, { enumerable: true, get() { reads++; throw Error('private dependency'); } });
      assert.throws(() => factory(options), code('configuration')); assert.equal(reads, 0, name);
    }
    assert.throws(() => factory({ ...plain, extra: true }), code('configuration'));
    assert.throws(() => factory({ ...plain, [Symbol('extra')]: true }), code('configuration'));
  }
});

test('fixed handle/ID scoping precedes provider reads and admission is never default allow', async t => {
  const f = await fixture(t);
  await assert.rejects(f.authority.resolveEntitlement(randomToken(32)), code('entitlement_ineligible'));
  await assert.rejects(f.authority.readEntitlement(randomToken(16)), code('authority_scope_mismatch'));
  assert.equal(f.calls(), 0);
  assert.throws(() => createStripeDeviceAuthority({ ...f.options, admission: undefined }), code('configuration'));
  assert.deepEqual(f.authority.readAuthorityFence(), { id: f.binding.entitlementID, revision: 0, status: 'unknown' });
  const result = await f.authority.resolveEntitlement(f.handle);
  assert.deepEqual(result, { id: f.binding.entitlementID, revision: 1, status: 'active', product: 'pro', ownerEmail: 'buyer@example.invalid' });
  assert.equal((await f.authority.readEntitlement(f.binding.entitlementID)).revision, 1);
  assert.equal(f.calls(), 2);
});

test('captured binding is immutable and scope/handle rebind fails on reopen', async t => {
  const f = await fixture(t), id = f.binding.entitlementID, original = structuredClone(f.binding);
  f.binding.entitlementID = randomToken(16); f.binding.priceId = 'price_Foreign';
  assert.equal((await f.authority.readEntitlement(id)).id, id);
  assert.throws(() => createStripeDeviceAuthority({ ...f.options, storage: f.open().storage }), code('storage_scope_mismatch'));
  const reopened = createStripeDeviceAuthority({ ...f.options, binding: original, storage: f.open().storage });
  assert.equal(reopened.readAuthorityFence().revision, 1);
});

test('terminal block is durable, idempotent and cannot be undone by a late active read', async t => {
  const f = await fixture(t); await f.authority.resolveEntitlement(f.handle);
  const paused = deferred(), active = f.getFact();
  const staleConnection = f.open();
  const stale = createStripeDeviceAuthority({ ...f.options, storage: staleConnection.storage,
    inspectDeviceAuthority: async () => { await paused.promise; return active; } });
  const inFlight = stale.readEntitlement(f.binding.entitlementID);
  f.setFact({ ...active, state: 'blocked', ownerEmail: null });
  const blocked = await f.authority.refreshAuthority();
  assert.deepEqual(blocked, { id: f.binding.entitlementID, revision: 2, status: 'blocked', product: 'pro' });
  paused.resolve(); await assert.rejects(inFlight, code('entitlement_ineligible'));
  f.setFact(active);
  staleConnection.db.close(); f.db.close();
  const reopened = createStripeDeviceAuthority({ ...f.options, storage: f.open().storage });
  await assert.rejects(reopened.readEntitlement(f.binding.entitlementID), code('entitlement_ineligible'));
  assert.deepEqual(await reopened.refreshAuthority(), blocked);
});

test('purchaser replacement and exact verified scope conflict terminally fence the original projection', async t => {
  for (const field of ['ownerEmail', 'accountId', 'mode', 'orderRef', 'sessionId', 'productId', 'priceId', 'currency', 'unitAmount', 'taxBehavior']) {
    const f = await fixture(t); await f.authority.resolveEntitlement(f.handle);
    const value = f.getFact();
    value[field] = field === 'unitAmount' ? 2000 : field === 'ownerEmail' ? 'other@example.invalid' : 'conflicting-value';
    f.setFact(value);
    await assert.rejects(f.authority.readEntitlement(f.binding.entitlementID), code('entitlement_ineligible'));
    assert.equal(f.authority.readAuthorityFence().status, 'blocked');
    assert.equal(f.authority.readAuthorityFence().revision, 2);
  }
});

test('pending is ineligible, revisions change only on observed state changes, terminal never revives', async t => {
  const f = await fixture(t), active = f.getFact();
  f.setFact({ ...active, state: 'pending', ownerEmail: null });
  assert.equal((await f.authority.refreshAuthority()).revision, 1);
  await assert.rejects(f.authority.resolveEntitlement(f.handle), code('entitlement_ineligible'));
  assert.equal(f.authority.readAuthorityFence().revision, 1);
  f.setFact(active); assert.equal((await f.authority.resolveEntitlement(f.handle)).revision, 2);
  f.setFact({ ...active, state: 'pending', ownerEmail: null });
  assert.equal((await f.authority.refreshAuthority()).revision, 3);
  assert.equal(f.authority.readAuthorityFence().status, 'pending');
  f.setFact(active); assert.equal((await f.authority.resolveEntitlement(f.handle)).revision, 4);
});

test('unavailable/malformed inspections never fall back to a cached active result or leak errors', async t => {
  const f = await fixture(t); await f.authority.resolveEntitlement(f.handle);
  for (const inspectDeviceAuthority of [
    async () => { throw Error('private provider detail'); },
    async () => ({ ...f.getFact(), extra: 'private detail' }),
    async () => ({ ...f.getFact(), ownerEmail: 'malformed\nemail' }),
  ]) {
    const other = createStripeDeviceAuthority({ ...f.options, storage: f.open().storage, inspectDeviceAuthority });
    await assert.rejects(other.readEntitlement(f.binding.entitlementID), code('authority_unavailable'));
  }
  let accessed = 0; const value = f.getFact();
  Object.defineProperty(value, 'ownerEmail', { enumerable: true, get() { accessed++; return 'private detail'; } });
  const other = createStripeDeviceAuthority({ ...f.options, storage: f.open().storage, inspectDeviceAuthority: async () => value });
  await assert.rejects(other.readEntitlement(f.binding.entitlementID), code('authority_unavailable')); assert.equal(accessed, 0);
});

test('durable projection contains no raw handle/email and returns fresh own-data fences', async t => {
  const f = await fixture(t); await f.authority.resolveEntitlement(f.handle);
  const rows = JSON.stringify(f.db.prepare('SELECT * FROM device_licence_stripe_authority').all());
  assert(!rows.includes(f.handle)); assert(!rows.includes('buyer@example.invalid'));
  const first = f.authority.readAuthorityFence(); first.status = 'blocked';
  assert.deepEqual(f.authority.readAuthorityFence(), { id: f.binding.entitlementID, revision: 1, status: 'active' });
  f.db.exec('PRAGMA wal_checkpoint(FULL)');
  const persisted = readFileSync(f.path).toString('latin1');
  assert(!persisted.includes(f.handle)); assert(!persisted.includes('buyer@example.invalid'));
});

test('failure of durability acknowledgement never returns an entitlement', async t => {
  const f = await fixture(t);
  const other = createStripeDeviceAuthority({ ...f.options,
    storage: { ...f.storage, sync: async () => { throw Error('private database details'); } } });
  await assert.rejects(other.resolveEntitlement(f.handle), code('authority_unavailable'));
});

test('current synchronous fence rejects a terminal change at a paused transaction boundary', async t => {
  const f = await fixture(t), current = await f.authority.resolveEntitlement(f.handle);
  const other = createStripeDeviceAuthority({ ...f.options, storage: f.open().storage });
  f.setFact({ ...f.getFact(), state: 'blocked', ownerEmail: null }); await other.refreshAuthority();
  // Exact hook consumer contract; a real sqlite-service composition is retained separately.
  assert.throws(() => f.storage.transactionSync(() => {
    const fence = f.authority.readAuthorityFence();
    assert(fence.id === current.id && fence.status === 'active' && fence.revision === current.revision);
  }));
});

test('admission has its own explicit revisioned authority, strict scope, and sanitized failures', async t => {
  const f = await fixture(t); await f.authority.resolveEntitlement(f.handle); let calls = 0;
  const input = { phase: 'begin', entitlementID: f.binding.entitlementID, deviceKeyHash: randomToken(32), now: 1700000000 };
  const authority = createStripeDeviceAuthority({ ...f.options, admission: async value => {
    calls++; assert.deepEqual(value, input); return { revision: 7, decision: 'hold' };
  } });
  assert.deepEqual(await authority.admission(input), { revision: 7, decision: 'hold' });
  await assert.rejects(authority.admission({ ...input, entitlementID: randomToken(16) }), code('authority_scope_mismatch'));
  assert.equal(calls, 1);
  for (const admission of [async () => { throw Error('private admission details'); }, async () => ({ revision: 1, decision: 'allow', extra: true })]) {
    const other = createStripeDeviceAuthority({ ...f.options, admission });
    await assert.rejects(other.admission(input), code('admission_unavailable'));
  }
});

async function issuerFixture() {
  const key = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const issuerPublicKey = base64url(await crypto.subtle.exportKey('raw', key.publicKey));
  const fields = { issuerKeyID: 'synthetic-device-v1', entitlementID: randomToken(16),
    deviceKeyHash: randomToken(32), receiptID: randomToken(16), issuedAt: 1700000000 };
  const options = { enabled: true, issuerKeyID: fields.issuerKeyID, entitlementID: fields.entitlementID,
    issuerPublicKey, sign: value => signReceipt(value, key.privateKey) };
  return { key, fields, options };
}

test('pinned issuer validates exact CLIPD1 envelope with no legacy signer authority', async () => {
  const f = await issuerFixture(), issue = createPinnedDeviceReceiptIssuer(f.options);
  const receipt = await issue(f.fields); assert.deepEqual(parseReceipt(receipt).fields, f.fields);
  for (const fields of [{ ...f.fields, issuerKeyID: 'other' }, { ...f.fields, entitlementID: randomToken(16) }, { ...f.fields, extra: true }])
    await assert.rejects(issue(fields), code('signer_mismatch'));
});

test('issuer snapshots input before await and rejects signer mutation, wrong key, extras and CLIP1', async () => {
  const f = await issuerFixture(), other = await issuerFixture();
  const badSigners = [
    async fields => { fields.receiptID = randomToken(16); return signReceipt(fields, f.key.privateKey); },
    async fields => signReceipt(fields, other.key.privateKey),
    async () => ({ receipt: 'private detail', diagnostic: 'private detail' }),
    async () => 'CLIP1-private-legacy-token',
  ];
  for (const sign of badSigners) await assert.rejects(createPinnedDeviceReceiptIssuer({ ...f.options, sign })(f.fields), code('signer_mismatch'));
  const paused = deferred(), original = structuredClone(f.fields);
  const issue = createPinnedDeviceReceiptIssuer({ ...f.options, sign: async fields => { await paused.promise; return signReceipt(fields, f.key.privateKey); } });
  const pending = issue(f.fields); f.fields.receiptID = randomToken(16); paused.resolve();
  assert.deepEqual(parseReceipt(await pending).fields, original);
});

test('issuer rejects getters without invoking them and sanitizes signer exceptions', async () => {
  const f = await issuerFixture(); let accessed = 0;
  const fields = { ...f.fields };
  Object.defineProperty(fields, 'receiptID', { get() { accessed++; return f.fields.receiptID; } });
  await assert.rejects(createPinnedDeviceReceiptIssuer(f.options)(fields), code('signer_mismatch')); assert.equal(accessed, 0);
  await assert.rejects(createPinnedDeviceReceiptIssuer({ ...f.options, sign: async () => { throw Error('private key/provider detail'); } })(f.fields), code('signer_unavailable'));
});

test('invalid pinned curve point cannot invoke the issuer capability', async () => {
  const f = await issuerFixture(); let calls = 0;
  const invalid = new Uint8Array(65); invalid[0] = 4;
  const issue = createPinnedDeviceReceiptIssuer({ ...f.options, issuerPublicKey: base64url(invalid),
    sign: async () => { calls++; return 'invalid'; } });
  await assert.rejects(issue(f.fields), code('configuration')); assert.equal(calls, 0);
});
