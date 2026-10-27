// Fresh local SQLite and synthetic in-memory crypto/custody only. No external I/O.
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { mkdtemp, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { syntheticKey } from './fixtures.mjs';
import { randomToken, tokenDigest, approvalMessage, base64url, signReceipt } from '../protocol.mjs';

export const origin = 'https://bootstrap.synthetic.invalid';
export const tick = () => new Promise(resolve => setImmediate(resolve));
export function deferred() {
  let resolve, reject;
  const promise = new Promise((a, b) => { resolve = a; reject = b; });
  return { promise, resolve, reject };
}
export function request(id, route, body, options = {}) {
  return new Request(`${origin}/device-licensing/v1/${route}`, {
    method: 'POST', headers: { 'content-type': 'application/json', 'X-Cliphoard-Entitlement': id },
    body: JSON.stringify(body), ...options,
  });
}
export async function scopedFixture(t, overrides = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'cliphoard-bootstrap-router-'));
  const db = new DatabaseSync(join(directory, 'ledger.sqlite'));
  db.exec('PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;');
  db.exec('CREATE TABLE fake_alarm (singleton INTEGER PRIMARY KEY, time INTEGER)');
  t.after(async () => { db.close(); await rm(directory, { recursive: true }); });
  const issuer = await syntheticKey(), device = overrides.device ?? await syntheticKey();
  const id = randomToken(16), handle = randomToken(32), sends = [], signatures = [], sealed = new Map();
  const state = { milliseconds: 1767323045000, status: 'active', ownerEmail: 'purchaser@example.invalid',
    revision: 1, admission: 'allow', reads: 0, sqlCalls: 0, alarmCalls: 0 };
  const scope = { accountId: 'acct_Bootstrap', mode: 'test', orderRef: '00000000-0000-4000-8000-000000000002',
    sessionId: 'cs_test_Bootstrap', productId: 'prod_Bootstrap', priceId: 'price_Bootstrap',
    currency: 'gbp', unitAmount: 1000, taxBehavior: 'inclusive' };
  const storage = {
    sql: { exec: (query, ...args) => { state.sqlCalls++; return db.prepare(query).all(...args); } },
    transactionSync(action) {
      db.exec('BEGIN IMMEDIATE');
      try { const result = action(); assert(!result?.then); db.exec('COMMIT'); return result; }
      catch (error) { db.exec('ROLLBACK'); throw error; }
    }, async sync() {},
  };
  const alarmStorage = {
    async getAlarm() { state.alarmCalls++; return db.prepare('SELECT time FROM fake_alarm').get()?.time ?? null; },
    async setAlarm(time) { state.alarmCalls++; db.prepare('INSERT INTO fake_alarm VALUES(1,?) ON CONFLICT(singleton) DO UPDATE SET time=excluded.time').run(time); },
    async deleteAlarm() { state.alarmCalls++; db.prepare('DELETE FROM fake_alarm').run(); }, async sync() {},
  };
  const options = { enabled: true, storage,
    binding: { entitlementID: id, entitlementHandleDigest: await tokenDigest(handle), ...scope },
    inspectDeviceAuthority: async () => {
      state.reads++; await state.readGate?.();
      if (state.failRead) throw Error('secret provider detail');
      return { ...scope, state: state.status, ownerEmail: state.status === 'active' ? state.ownerEmail : null };
    },
    issuer: { issuerKeyID: 'synthetic-receipt', issuerPublicKey: issuer.publicKey, sign: async fields => {
      signatures.push(structuredClone(fields)); await state.signGate?.(); return signReceipt(fields, issuer.privateKey);
    } },
    tokenCustody: {
      async sealToken(token, aad) { const value = `fake-only.${randomToken(32)}`; sealed.set(value, { token, aad }); return value; },
      async openToken(value, aad) { const record = sealed.get(value); assert.equal(record?.aad, aad); return record.token; },
    },
    admission: {
      evaluate: async () => ({ revision: state.revision, decision: state.admission }),
      readCurrent: async () => ({ entitlementID: id, revision: state.revision, decision: state.admission }),
    },
    mail: { from: 'support@example.invalid', replyTo: 'support@example.invalid', timeoutMilliseconds: 500,
      send: async value => { sends.push(value); return { messageId: 'fake-captured-mail' }; } },
    alarmStorage, clocks: { epochMilliseconds: () => state.milliseconds, monotonicMilliseconds: () => performance.now() },
    limits: { challengeTTLSeconds: 600, deliveryLeaseSeconds: 30 },
    operational: { maximumAttemptsPerInvocation: 2, maxPendingOperations: 4, invocationBudgetMilliseconds: 1000,
      prearmDelayMilliseconds: 5000, retryDelayMilliseconds: 7000, continuationDelayMilliseconds: 1000 },
    http: { origin: overrides.origin ?? origin, bodyTimeoutMs: 25 },
  };
  const begin = () => ({ entitlementHandle: handle, devicePublicKey: device.publicKey, requestID: randomToken(16) });
  const approval = async challenge => {
    const approvalToken = sends.find(m => m.subject === 'Approve this Mac for Cliphoard Pro').text.match(/Approval code:\n([A-Za-z0-9_-]{43})\n/)[1];
    const approvalRequestID = randomToken(16);
    return { challengeID: challenge.challengeID, approvalToken, approvalRequestID,
      deviceSignature: base64url(await device.provider.signProof(approvalMessage(challenge, await tokenDigest(approvalToken), approvalRequestID))) };
  };
  return { id, handle, device, issuer, db, options, state, sends, signatures, begin, approval };
}
