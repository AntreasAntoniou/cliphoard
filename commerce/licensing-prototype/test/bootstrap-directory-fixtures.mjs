import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';

export const token = (bytes, value) => Buffer.alloc(bytes, value).toString('base64url');
export const origin = 'https://directory.synthetic.invalid';
export const scope = (n = 1) => Object.freeze({ accountId: 'acct_Directory', mode: 'test',
  orderRef: `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`,
  sessionId: `cs_test_Directory${n}`, productId: 'prod_Directory', priceId: 'price_Directory',
  currency: 'gbp', unitAmount: 1000, taxBehavior: 'inclusive' });
export const reservation = (n = 1) => Object.freeze({ entitlementID: token(16, n),
  provisioningID: token(16, n + 20), scope: scope(n) });
export const ack = (r = reservation(), value = 80) => Object.freeze({ entitlementID: r.entitlementID,
  provisioningID: r.provisioningID, bindingDigest: token(32, value) });
export function deferred() {
  let resolve, reject;
  const promise = new Promise((a, b) => { resolve = a; reject = b; });
  return { promise, resolve, reject };
}
export const tick = () => new Promise(resolve => setImmediate(resolve));
export function storageFixture(t) {
  const db = new DatabaseSync(':memory:'); t.after(() => db.close());
  const state = { sql: 0, transactions: 0, syncs: 0 };
  const storage = {
    sql: { exec(query, ...values) { state.sql++; return db.prepare(query).all(...values); } },
    transactionSync(operation) {
      state.transactions++; db.exec('BEGIN IMMEDIATE');
      try { const result = operation(); assert(!result?.then); db.exec('COMMIT'); return result; }
      catch (error) { db.exec('ROLLBACK'); throw error; }
    },
    async sync() { state.syncs++; if (state.syncGate) await state.syncGate; },
  };
  return { db, storage, state };
}
export function request(id = reservation().entitlementID, route = 'begin', options = {}) {
  return new Request(`${origin}/device-licensing/v1/${route}`, { method: 'POST',
    headers: { 'content-type': 'application/json', 'X-Cliphoard-Entitlement': id },
    body: '{"opaque":"original-body"}', ...options });
}
