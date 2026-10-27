import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { mkdtemp, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { createSqliteActivationService } from '../sqlite-service.mjs';
import { syntheticKey } from './fixtures.mjs';
import { randomToken, base64url, decode, tokenDigest, approvalMessage, signReceipt } from '../protocol.mjs';

export function gate() {
  let resolve, reject;
  const promise = new Promise((a, b) => { resolve = a; reject = b; });
  return { promise, resolve, reject };
}

export async function deliveryFixture(t, { fence = true } = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'cliphoard-mail-candidate-'));
  const connections = new Set();
  t.after(async () => { for (const db of connections) db.close(); await rm(directory, { recursive: true }); });
  const issuer = await syntheticKey(), device = await syntheticKey();
  const sealKey = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
  const id = randomToken(16), handle = randomToken(32), contexts = [], signatures = [];
  const state = { milliseconds: 1767323045000, revision: 1, status: 'active', ownerEmail: 'owner@example.invalid',
    fence: { id, revision: 1, status: 'active' }, admissionRevision: 1, admission: 'allow' };
  const fact = () => ({ id, product: 'pro', revision: state.revision, status: state.status, ownerEmail: state.ownerEmail });
  const options = {
    entitlementID: id, issuerKeyID: 'synthetic-mail', issuerPublicKey: issuer.publicKey,
    clock: () => Math.floor(state.milliseconds / 1000), challengeTTLSeconds: 600, deliveryLeaseSeconds: 30,
    ...(fence ? { readAuthorityFence: () => state.fence } : {}),
    resolveEntitlement: async candidate => candidate === handle ? fact() : undefined,
    readEntitlement: async () => { await state.readGate?.(); return fact(); },
    admission: async () => ({ revision: state.admissionRevision, decision: state.admission }),
    issueReceipt: async fields => {
      signatures.push(structuredClone(fields));
      const value = await signReceipt(fields, issuer.privateKey);
      await state.signGate?.(); return value;
    },
    sealToken: async (token, aad) => {
      const iv = crypto.getRandomValues(new Uint8Array(12));
      const encrypted = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv,
        additionalData: new TextEncoder().encode(aad) }, sealKey, new TextEncoder().encode(token)));
      await state.sealGate?.(); return base64url(new Uint8Array([...iv, ...encrypted]));
    },
    openToken: async (token, aad) => {
      const bytes = decode(token, undefined, 2048);
      const decrypted = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: bytes.slice(0, 12),
        additionalData: new TextEncoder().encode(aad) }, sealKey, bytes.slice(12));
      await state.openGate?.(); return new TextDecoder().decode(decrypted);
    },
    deliverApproval: async context => { contexts.push(context); return state.deliver ? state.deliver(context) : { accepted: true }; },
    deliverReceipt: async context => { contexts.push(context); return state.deliver ? state.deliver(context) : { accepted: true }; },
  };
  function connect() {
    const db = new DatabaseSync(join(directory, 'ledger.sqlite'));
    connections.add(db);
    db.exec('PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=1000;');
    db.exec('CREATE TABLE IF NOT EXISTS test_alarm (singleton INTEGER PRIMARY KEY CHECK(singleton=1), time INTEGER)');
    const storage = {
      sql: { exec(query, ...bindings) {
        if (state.failSQL && query.includes(state.failSQL)) { state.failSQL = undefined; throw new Error('synthetic write failure'); }
        return db.prepare(query).all(...bindings);
      } },
      transactionSync(callback) {
        db.exec('BEGIN IMMEDIATE');
        try { const value = callback(); assert.equal(typeof value?.then, 'undefined'); db.exec('COMMIT'); return value; }
        catch (error) { db.exec('ROLLBACK'); throw error; }
      },
      async sync() { if (state.failSync) { state.failSync = false; throw new Error('synthetic sync failure'); } },
    };
    const alarmStorage = {
      async getAlarm() { return db.prepare('SELECT time FROM test_alarm WHERE singleton=1').get()?.time ?? null; },
      async setAlarm(time) {
        assert.equal(Number.isSafeInteger(time), true);
        if (state.failAlarm) throw new Error('synthetic alarm failure');
        db.prepare('INSERT INTO test_alarm VALUES(1,?) ON CONFLICT(singleton) DO UPDATE SET time=excluded.time').run(time);
        await state.afterArm?.();
      },
      async deleteAlarm() { await state.beforeDelete?.(); db.prepare('DELETE FROM test_alarm').run(); },
      async sync() {},
    };
    return { db, storage, alarmStorage, service: createSqliteActivationService({ ...options, storage }),
      close() { db.close(); connections.delete(db); } };
  }
  let current = connect();
  const input = () => ({ method: 'POST', entitlementHandle: handle, requestID: randomToken(16), devicePublicKey: device.publicKey });
  const approval = async (challenge, token = contexts.find(c => c.challengeID === challenge.challengeID)?.token) => {
    const approvalRequestID = randomToken(16);
    return { method: 'POST', challengeID: challenge.challengeID, approvalToken: token, approvalRequestID,
      deviceSignature: base64url(await device.provider.signProof(approvalMessage(challenge, await tokenDigest(token), approvalRequestID))) };
  };
  return { id, handle, issuer, device, state, contexts, signatures, fact, input, approval, options, connect,
    trust: new Map([['synthetic-mail', issuer.publicKey]]),
    get service() { return current.service; }, get db() { return current.db; },
    get storage() { return current.storage; }, get alarmStorage() { return current.alarmStorage; },
    restart() { current.close(); current = connect(); },
  };
}
