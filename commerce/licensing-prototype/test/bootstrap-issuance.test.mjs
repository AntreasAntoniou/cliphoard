import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import {
  mkdtempSync,
  rmSync
} from 'node:fs';
import { join } from 'node:path';
import { createDeviceBootstrapService } from '../bootstrap-service.mjs';
import { createDeviceBootstrapMail } from '../bootstrap-mail.mjs';
import {
  parseBootstrap,
  verifyBootstrap
} from '../bootstrap-protocol.mjs';

const b64 = value => Buffer.from(value).toString('base64url');
const opaque = (byte, size = 16) => b64(Buffer.alloc(size, byte));
const gate = () => {
  let release, entered;
  const wait = new Promise(r => release = r), seen = new Promise(r => entered = r);
  return {
    release,
    seen,
    async pause() {
      entered();
      await wait;
    }
  };
};
const pair = async () => {
  const k = await crypto.subtle.generateKey({
    name: 'ECDSA',
    namedCurve: 'P-256'
  }, false, [
    'sign',
    'verify'
  ]);
  return {
    privateKey: k.privateKey,
    publicKey: b64(await crypto.subtle.exportKey('raw', k.publicKey))
  };
};
async function fixture(t) {
  const dir = mkdtempSync('/Users/antreas/Documents/ChatGPT/Cliphoard/release/2026-10-27/bootstrap-issuance/service/runtime-');
  const dbs = [], signer = await pair(), receipt = await pair(), sealKey = await crypto.subtle.generateKey({
      name: 'AES-GCM',
      length: 256
    }, false, [
      'encrypt',
      'decrypt'
    ]);
  const reservation = {
    entitlementID: opaque(1),
    provisioningID: opaque(2),
    scope: {
      accountId: 'acct_bootstrap',
      mode: 'test',
      orderRef: '11111111-1111-4111-8111-111111111111',
      sessionId: 'cs_test_bootstrap',
      productId: 'prod_bootstrap',
      priceId: 'price_bootstrap',
      currency: 'gbp',
      unitAmount: 1000,
      taxBehavior: 'inclusive'
    }
  };
  const selection = {
    profileID: 'local-review',
    bootstrapKeyID: 'bootstrap-review',
    bootstrapPublicKey: signer.publicKey,
    receiptIssuerKeyID: 'receipt-review',
    receiptIssuerPublicKey: receipt.publicKey
  };
  const trust = {
    expectedProfileID: selection.profileID,
    bootstrapKeyID: selection.bootstrapKeyID,
    bootstrapPublicKey: selection.bootstrapPublicKey,
    receiptIssuerKeyIDs: [selection.receiptIssuerKeyID]
  };
  const state = {
    epoch: 1767323045000,
    monotonic: 0,
    alarm: null,
    signs: 0,
    inspections: 0,
    seals: 0,
    opens: 0,
    messages: [],
    signGate: null,
    sendGate: null,
    sendFail: false,
    alarmFail: false,
    authorityUnavailable: false,
    purchase: {
      ...reservation.scope,
      state: 'active',
      ownerEmail: 'owner@example.invalid'
    },
    trace: [],
    failAfterEnvelope: false
  };
  const enc = value => new TextEncoder().encode(value), dec = value => new TextDecoder().decode(value);
  const custody = {
    keyID: 'seal-review',
    async seal(plaintext, aad) {
      state.seals++;
      const iv = crypto.getRandomValues(new Uint8Array(12));
      const data = await crypto.subtle.encrypt({
        name: 'AES-GCM',
        iv,
        additionalData: enc(aad)
      }, sealKey, enc(plaintext));
      return 'TEST1.' + b64(iv) + '.' + b64(data);
    },
    async open(envelope, aad) {
      state.opens++;
      const [, iv, data] = envelope.split('.');
      return dec(await crypto.subtle.decrypt({
        name: 'AES-GCM',
        iv: Buffer.from(iv, 'base64url'),
        additionalData: enc(aad)
      }, sealKey, Buffer.from(data, 'base64url')));
    }
  };
  const mail = createDeviceBootstrapMail({
    enabled: true,
    entitlementID: reservation.entitlementID,
    trust,
    from: 'licensing@example.invalid',
    replyTo: 'support@example.invalid',
    timeoutMilliseconds: 50,
    send: async value => {
      state.messages.push(structuredClone(value));
      const g = state.sendGate;
      state.sendGate = null;
      if (g)
        await g.pause();
      if (state.sendFail)
        throw Error('private sender error');
      return { messageId: 'synthetic-' + state.messages.length };
    }
  });
  const open = () => {
    const db = new DatabaseSync(join(dir, 'bootstrap.sqlite'));
    db.exec('PRAGMA journal_mode=WAL');
    db.exec('PRAGMA synchronous=FULL');
    dbs.push(db);
    return db;
  };
  const options = db => ({
    enabled: true,
    storage: {
      sql: {
        exec(query, ...args) {
          return db.prepare(query).all(...args);
        }
      },
      transactionSync(fn) {
        db.exec('BEGIN IMMEDIATE');
        try {
          const r = fn();
          assert.ok(!(r instanceof Promise));
          db.exec('COMMIT');
          return r;
        } catch (e) {
          db.exec('ROLLBACK');
          throw e;
        }
      },
      async sync() {
        state.trace.push('sync');
        if (state.failAfterEnvelope && db.prepare('SELECT name FROM sqlite_master WHERE name=\'device_bootstrap_state\'').get() && db.prepare('SELECT envelope_hash FROM device_bootstrap_state').get()?.envelope_hash) {
          state.failAfterEnvelope = false;
          throw Error('ambiguous durability acknowledgment');
        }
      }
    },
    reservation,
    selection,
    signer: {
      async sign(payload) {
        state.signs++;
        state.trace.push('sign');
        const g = state.signGate;
        state.signGate = null;
        if (g)
          await g.pause();
        return new Uint8Array(await crypto.subtle.sign({
          name: 'ECDSA',
          hash: 'SHA-256'
        }, signer.privateKey, payload));
      }
    },
    custody,
    inspectDeviceAuthority: async () => {
      state.inspections++;
      if (state.authorityUnavailable)
        throw Error('private provider error');
      return structuredClone(state.purchase);
    },
    delivery: mail,
    alarmStorage: {
      async getAlarm() {
        return state.alarm;
      },
      async setAlarm(v) {
        state.alarm = v;
        state.trace.push('arm');
      },
      async deleteAlarm() {
        state.alarm = null;
        state.trace.push('delete');
      },
      async sync() {
        state.trace.push('alarm-sync');
        if (state.alarmFail)
          throw Error('alarm unavailable');
      }
    },
    clocks: {
      epochMilliseconds: () => state.epoch,
      monotonicMilliseconds: () => state.monotonic
    },
    operational: {
      maxPendingOperations: 2,
      maximumAttemptsPerInvocation: 3,
      invocationBudgetMilliseconds: 1000,
      prearmDelayMilliseconds: 1000,
      retryDelayMilliseconds: 1000,
      continuationDelayMilliseconds: 1000,
      deliveryLeaseSeconds: 2
    }
  });
  const db = open(), config = options(db), service = createDeviceBootstrapService(config);
  const reopen = () => createDeviceBootstrapService(options(open()));
  const row = () => db.prepare('SELECT * FROM device_bootstrap_state').get();
  const outbox = () => db.prepare('SELECT * FROM device_bootstrap_outbox ORDER BY id').all();
  const attempts = () => db.prepare('SELECT * FROM device_bootstrap_attempts ORDER BY started_at,lease_id').all();
  const envelope = () => {
    const text = state.messages.at(-1)?.message.text;
    return text?.match(/CLIPB1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/)?.[0];
  };
  t.after(() => {
    for (const db of dbs)
      try {
        db.close();
      } catch {
      }
    rmSync(dir, {
      recursive: true,
      force: true
    });
  });
  return {
    db,
    state,
    config,
    service,
    reopen,
    row,
    outbox,
    attempts,
    envelope,
    trust,
    reservation,
    selection,
    mail,
    custody
  };
}

test('disabled constructors and allocation are inert until explicit provision; durable exact ack survives reopen', async t => {
  let getters = 0;
  for (const factory of [
      createDeviceBootstrapService,
      createDeviceBootstrapMail
    ]) {
    const options = { enabled: false };
    Object.defineProperty(options, 'storage', {
      get() {
        getters++;
        throw Error('getter');
      }
    });
    factory(options);
    const accessor = {};
    Object.defineProperty(accessor, 'enabled', {
      get() {
        getters++;
        return true;
      }
    });
    assert.throws(() => factory(accessor));
  }
  assert.equal(getters, 0);
  const f = await fixture(t);
  assert.equal(f.db.prepare('SELECT count(*) AS n FROM sqlite_master WHERE type=\'table\'').get().n, 0);
  assert.equal(f.state.signs, 0);
  assert.equal(f.state.inspections, 0);
  assert.equal(f.state.seals, 0);
  const ack = await f.service.provision();
  assert.deepEqual(Object.keys(ack).sort(), [
    'bindingDigest',
    'entitlementID',
    'provisioningID'
  ]);
  assert.equal(ack.entitlementID, f.reservation.entitlementID);
  assert.equal(ack.provisioningID, f.reservation.provisioningID);
  assert.deepEqual(await f.reopen().provision(), ack);
  assert.equal(f.state.seals, 1);
  assert.equal(f.state.signs, 0);
  assert.equal(f.state.inspections, 0);
  assert.equal(f.state.messages.length, 0);
  const binding = f.service.readActivationBinding();
  assert.equal(binding.entitlementID, ack.entitlementID);
  assert.equal(binding.entitlementHandleDigest, f.row().handle_digest);
  const drift = createDeviceBootstrapService({
    ...f.config,
    selection: {
      ...f.selection,
      profileID: 'changed'
    }
  });
  await assert.rejects(drift.provision());
  assert.deepEqual(await f.service.provision(), ack);
});

test('one committed encrypted descriptor and one initial outbox survive ambiguous commit acknowledgment', async t => {
  const f = await fixture(t);
  await f.service.provision();
  f.state.failAfterEnvelope = true;
  await assert.rejects(f.service.requestIssue());
  assert.ok(f.row().envelope_hash);
  assert.equal(f.outbox().length, 1);
  assert.equal(f.state.messages.length, 0);
  const hash = f.row().envelope_hash, issued = f.row().issued_at;
  await f.reopen().recover();
  assert.equal(f.state.signs, 1);
  assert.equal(f.row().envelope_hash, hash);
  assert.equal(f.row().issued_at, issued);
  assert.equal(f.state.messages.length, 1);
  const fields = await verifyBootstrap(f.envelope(), f.trust);
  assert.equal(fields.entitlementID, f.reservation.entitlementID);
  assert.ok(!JSON.stringify(f.row()).includes(fields.activationHandle));
  assert.ok(!JSON.stringify(f.row()).includes('CLIPB1.'));
  assert.ok(!JSON.stringify(f.outbox()).includes('owner@example.invalid'));
  assert.equal(f.outbox()[0].status, 'accepted');
  await f.service.requestIssue();
  assert.equal(f.state.signs, 1);
  assert.equal(f.outbox().length, 1);
});

test('two service instances may sign but CAS commits only one envelope and delivery intent', async t => {
  const f = await fixture(t);
  await f.service.provision();
  const g = gate();
  f.state.signGate = g;
  const first = f.service.requestIssue();
  await g.seen;
  const second = f.reopen().requestIssue();
  await second;
  g.release();
  await first;
  assert.equal(f.state.signs, 2);
  assert.equal(f.outbox().length, 1);
  const hash = f.row().envelope_hash;
  await f.service.recover();
  assert.equal(f.row().envelope_hash, hash);
  assert.equal(f.state.messages.length, 1);
});

test('pending/unavailable payment holds issue and recovery keeps exact allocation', async t => {
  const f = await fixture(t);
  const ack = await f.service.provision(), payloadHash = f.row().payload_hash;
  f.state.purchase = {
    ...f.state.purchase,
    state: 'pending',
    ownerEmail: null
  };
  await assert.rejects(f.service.requestIssue());
  assert.equal(f.state.signs, 0);
  assert.ok(f.state.alarm);
  f.state.authorityUnavailable = true;
  await assert.rejects(f.reopen().recover());
  assert.equal(f.state.signs, 0);
  assert.equal(f.row().payload_hash, payloadHash);
  f.state.authorityUnavailable = false;
  f.state.purchase = {
    ...f.reservation.scope,
    state: 'active',
    ownerEmail: 'owner@example.invalid'
  };
  await f.reopen().recover();
  assert.equal(f.state.signs, 1);
  assert.equal(f.state.messages.length, 1);
  assert.deepEqual(await f.service.provision(), ack);
});

test('terminal authority feed overtakes signer and never permits late commit or later active resurrection', async t => {
  const f = await fixture(t);
  await f.service.provision();
  const g = gate();
  f.state.signGate = g;
  const issuing = f.service.requestIssue();
  await g.seen;
  f.state.purchase = {
    ...f.reservation.scope,
    state: 'blocked',
    ownerEmail: null
  };
  await f.service.refreshAuthority();
  g.release();
  await assert.rejects(issuing);
  assert.equal(f.row().status, 'blocked');
  assert.equal(f.row().envelope_hash, null);
  assert.equal(f.outbox().length, 0);
  f.state.purchase = {
    ...f.reservation.scope,
    state: 'active',
    ownerEmail: 'owner@example.invalid'
  };
  await assert.rejects(f.reopen().requestIssue());
  assert.equal(f.state.signs, 1);
  assert.equal(f.state.messages.length, 0);
});

test('uncertain mail retries identical envelope and deliveryID; intentional recovery is idempotent', async t => {
  const f = await fixture(t);
  await f.service.provision();
  await f.service.requestIssue();
  f.state.sendFail = true;
  await f.service.recover();
  assert.equal(f.outbox()[0].outcome, 'uncertain');
  assert.equal(f.state.messages.length, 1);
  const first = structuredClone(f.state.messages[0]), envelope = f.envelope();
  f.state.sendFail = false;
  f.state.epoch += 3000;
  await f.reopen().recover();
  assert.deepEqual(f.state.messages[1], first);
  assert.equal(f.envelope(), envelope);
  assert.equal(f.state.signs, 1);
  assert.ok(f.attempts().some(row => row.outcome === 'uncertain'));
  const request = { requestID: opaque(9) };
  await f.service.requestRecovery(request);
  await f.service.requestRecovery(request);
  assert.equal(f.outbox().length, 2);
  await f.service.recover();
  assert.equal(f.envelope(), envelope);
  assert.notEqual(f.state.messages[2].deliveryID, first.deliveryID);
  assert.equal(f.state.messages[2].message.to, 'owner@example.invalid');
  assert.equal(f.state.signs, 1);
});

test('purchaser change blocks pending mail; sealed payload tamper cannot sign; prearm failure precedes enqueue', async t => {
  const f = await fixture(t);
  await f.service.provision();
  f.state.alarmFail = true;
  await assert.rejects(f.service.requestIssue());
  assert.equal(f.row().issue_requested, 0);
  assert.equal(f.state.signs, 0);
  f.state.alarmFail = false;
  const original = f.row().sealed_payload;
  f.db.prepare('UPDATE device_bootstrap_state SET sealed_payload=?').run(original.slice(0, -4) + 'AAAA');
  await assert.rejects(f.service.requestIssue());
  assert.equal(f.state.signs, 0);
  f.db.prepare('UPDATE device_bootstrap_state SET sealed_payload=?').run(original);
  await f.service.requestIssue();
  f.state.purchase.ownerEmail = 'other@example.invalid';
  await assert.rejects(f.service.recover());
  assert.equal(f.state.messages.length, 0);
  assert.equal(f.row().status, 'blocked');
  assert.equal(f.outbox()[0].status, 'cancelled');
});

test('soft mail timeout retains unsettled ownership and terminal block fences late retry', async t => {
  const f = await fixture(t);
  await f.service.provision();
  await f.service.requestIssue();
  const g = gate();
  f.state.sendGate = g;
  const working = f.service.recover();
  await g.seen;
  await working;
  assert.equal(f.mail.hasUnsettledSend(), true);
  assert.equal(f.state.messages.length, 1);
  f.state.epoch += 3000;
  await f.service.recover();
  assert.equal(f.state.messages.length, 1);
  f.state.purchase = {
    ...f.reservation.scope,
    state: 'blocked',
    ownerEmail: null
  };
  await f.service.refreshAuthority();
  g.release();
  await new Promise(r => setImmediate(r));
  assert.equal(f.mail.hasUnsettledSend(), false);
  assert.equal(f.outbox()[0].status, 'cancelled');
  assert.equal(f.state.messages.length, 1);
});

test('prearm dependency errors expose only fixed service failure', async t => {
  const f = await fixture(t);
  await f.service.provision();
  f.state.alarmFail = true;
  await assert.rejects(f.service.requestIssue(), error => error.code === 'bootstrap_unavailable' && error.message === 'bootstrap_unavailable');
  assert.equal(f.state.signs, 0);
  assert.equal(f.row().issue_requested, 0);
});

test('reserved alarm observes failed early prearm while queued behind signer', async t => {
  const f = await fixture(t);
  await f.service.provision();
  const g = gate();
  f.state.signGate = g;
  const issuing = f.service.requestIssue();
  await g.seen;
  f.state.alarmFail = true;
  const alarm = f.service.alarm(), failed = assert.rejects(alarm, error => error.code === 'bootstrap_unavailable');
  await new Promise(r => setImmediate(r));
  f.state.alarmFail = false;
  g.release();
  await issuing;
  await failed;
  assert.equal(f.state.signs, 1);
  assert.equal(f.state.messages.length, 0);
  assert.ok(f.state.alarm);
});

test('finite command capacity retains queued ownership and never executes overflow later', async t => {
  const f = await fixture(t);
  await f.service.provision();
  const g = gate();
  f.state.signGate = g;
  const first = f.service.requestIssue();
  await g.seen;
  const second = f.service.requestIssue();
  await assert.rejects(f.service.requestIssue(), error => error.code === 'bootstrap_busy');
  assert.equal(f.state.signs, 1);
  g.release();
  await first;
  await second;
  assert.equal(f.state.signs, 1);
  assert.equal(f.outbox().length, 1);
});

test('terminal recovery failure removes only its empty durable wake after the block is synchronized', async t => {
  const f = await fixture(t);
  await f.service.provision();
  await f.service.requestIssue();
  f.state.purchase = {
    ...f.reservation.scope,
    state: 'blocked',
    ownerEmail: null
  };
  await assert.rejects(f.service.recover());
  assert.equal(f.row().status, 'blocked');
  assert.equal(f.outbox()[0].status, 'cancelled');
  assert.equal(f.state.alarm, null);
  await assert.rejects(f.reopen().recover());
  assert.equal(f.state.alarm, null);
  assert.equal(f.state.messages.length, 0);
});
