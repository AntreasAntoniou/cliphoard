import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createSqliteActivationService } from '../sqlite-service.mjs';
import { syntheticKey } from './fixtures.mjs';
import { randomToken, base64url, decode, tokenDigest, approvalMessage,
  signReceipt, verifyOffline, parseReceipt } from '../protocol.mjs';

function gate() {
  let release;
  const promise = new Promise(resolve => { release = resolve; });
  return { promise, release };
}

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'cliphoard-synthetic-ledger-'));
  const databasePath = join(directory, 'ledger.sqlite');
  const connections = new Set();
  t.after(async () => { for (const db of connections) db.close(); await rm(directory, { recursive: true }); });
  const signer = await syntheticKey(), device = await syntheticKey();
  const sealKey = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
  const id = randomToken(16), handle = randomToken(32), mails = [], receiptMails = [], signatures = [];
  const mutable = { now: 1767323045, revision: 1, status: 'active', held: false, admissionRevision: 1 };
  const authoritative = () => {
    if (mutable.authorityFailure) throw new Error('synthetic outage');
    return { id, product: 'pro', status: mutable.status, revision: mutable.revision, ownerEmail: 'owner@example.invalid' };
  };
  const options = {
    entitlementID: id, issuerKeyID: 'synthetic-1', issuerPublicKey: signer.publicKey,
    clock: () => mutable.now, challengeTTLSeconds: 600, deliveryLeaseSeconds: 30,
    resolveEntitlement: async candidate => candidate === handle ? authoritative() : undefined,
    readEntitlement: async () => { await mutable.duringRefresh?.(); return mutable.readSnapshot ?? authoritative(); },
    admission: async event => {
      if (mutable.admissionFailure) throw new Error('synthetic admission outage');
      const fact = { revision: mutable.admissionRevision, decision: mutable.held ? 'hold' : 'allow' };
      await mutable.duringAdmission?.(event);
      return fact;
    },
    issueReceipt: async fields => {
      mutable.mutateSignerFields?.(fields);
      signatures.push(structuredClone(fields));
      const result = await signReceipt(fields, signer.privateKey);
      await mutable.duringSigning?.();
      return result;
    },
    sealToken: async (token, aad) => {
      const iv = crypto.getRandomValues(new Uint8Array(12));
      const ciphertext = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv,
        additionalData: new TextEncoder().encode(aad) }, sealKey, new TextEncoder().encode(token)));
      await mutable.duringSealing?.();
      return base64url(new Uint8Array([...iv, ...ciphertext]));
    },
    openToken: async (sealed, aad) => {
      const bytes = decode(sealed, undefined, 2048);
      const plaintext = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: bytes.slice(0, 12),
        additionalData: new TextEncoder().encode(aad) }, sealKey, bytes.slice(12));
      await mutable.duringOpening?.();
      return new TextDecoder().decode(plaintext);
    },
    deliverApproval: async mail => { mails.push(mail); await mutable.duringDelivery?.(); return { accepted: true }; },
    deliverReceipt: async mail => { receiptMails.push(mail); await mutable.duringDelivery?.(); return { accepted: true }; },
  };
  function connect() {
    const db = new DatabaseSync(databasePath);
    connections.add(db);
    db.exec('PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=1000;');
    const storage = {
      sql: { exec(query, ...bindings) {
        if (mutable.failSQL && query.includes(mutable.failSQL)) { mutable.failSQL = undefined; throw new Error('synthetic write failure'); }
        return db.prepare(query).all(...bindings);
      } },
      transactionSync(callback) {
        db.exec('BEGIN IMMEDIATE');
        try {
          const result = callback();
          assert.equal(typeof result?.then, 'undefined');
          db.exec('COMMIT');
          return result;
        } catch (error) { db.exec('ROLLBACK'); throw error; }
      },
      async sync() {}, // DatabaseSync COMMIT + synchronous=FULL already completed.
    };
    return { service: createSqliteActivationService({ ...options, storage }), storage, db,
      close() { db.close(); connections.delete(db); } };
  }
  let current = connect();
  const start = (requestID = randomToken(16), withDevice = device, service = current.service) => service.begin({
    method: 'POST', entitlementHandle: handle, requestID, devicePublicKey: withDevice.publicKey });
  const approval = async (challenge, approvalRequestID = randomToken(16), withDevice = device,
    token = mails.find(mail => mail.challengeID === challenge.challengeID)?.token) => ({
    method: 'POST', challengeID: challenge.challengeID, approvalToken: token, approvalRequestID,
    deviceSignature: base64url(await withDevice.provider.signProof(approvalMessage(challenge, await tokenDigest(token), approvalRequestID))),
  });
  const startAndMail = async () => {
    const { challenge } = await start();
    assert.equal((await current.service.deliverOne()).code, 'accepted');
    return challenge;
  };
  const refund = async (status = 'refunded') => {
    mutable.revision++; mutable.status = status;
    await current.service.observeEntitlement(authoritative());
  };
  return { id, handle, device, signer, mutable, mails, receiptMails, signatures, options,
    start, startAndMail, approval, refund, connect,
    get service() { return current.service; }, get db() { return current.db; },
    restart() { current.close(); current = connect(); },
    trust: new Map([['synthetic-1', signer.publicKey]]),
  };
}

test('disk restart preserves exact challenge, sealed approval token and request idempotency', async t => {
  const f = await fixture(t), requestID = randomToken(16);
  const first = await f.start(requestID);
  assert.equal(f.mails.length, 0);
  f.restart();
  assert.deepEqual(await f.start(requestID), first);
  assert.equal(f.service.snapshot().challenges, 1);
  assert.equal((await f.service.deliverOne()).code, 'accepted');
  const stored = JSON.stringify(f.db.prepare('SELECT * FROM device_licence_challenges').all());
  assert.equal(stored.includes(f.mails[0].token), false);
  assert.equal(stored.includes('owner@example.invalid'), false);
  await assert.rejects(f.start(requestID, await syntheticKey()), { code: 'idempotency_conflict' });
  assert.equal((await f.service.deliverOne()).code, 'nothing_due');
});

test('GET and wrong token/device/request proof cannot consume a durable challenge', async t => {
  const f = await fixture(t), challenge = await f.startAndMail();
  const input = await f.approval(challenge), before = f.service.snapshot();
  assert.equal(f.service.preview({ method: 'GET' }).code, 'confirmation_required');
  await assert.rejects(f.service.approve({ ...input, method: 'GET' }), { code: 'method_not_allowed' });
  await assert.rejects(f.service.approve({ ...input, approvalToken: randomToken(32) }), { code: 'approval_rejected' });
  await assert.rejects(f.service.approve(await f.approval(challenge, randomToken(16), await syntheticKey())), { code: 'approval_rejected' });
  await assert.rejects(f.service.approve({ ...input, approvalRequestID: randomToken(16) }), { code: 'approval_rejected' });
  await assert.rejects(f.service.approve({ ...input, surprise: true }), { code: 'malformed' });
  assert.deepEqual(f.service.snapshot(), before);
  assert.equal(f.signatures.length, 0);
});

test('concurrent duplicate approval signs once per object and restart returns the exact receipt after expiry/hold', async t => {
  const f = await fixture(t), challenge = await f.startAndMail(), input = await f.approval(challenge);
  const [first, duplicate] = await Promise.all([f.service.approve(input), f.service.approve(input)]);
  assert.equal(first.receipt, duplicate.receipt);
  assert.equal(f.signatures.length, 1);
  f.restart(); f.mutable.now = challenge.expiresAt + 100; f.mutable.held = true;
  await f.service.observeAdmission({ entitlementID: f.id, revision: 2, decision: 'hold' });
  f.mutable.admissionFailure = true;
  assert.equal((await f.service.approve(input)).receipt, first.receipt);
  await assert.rejects(f.service.approve(await f.approval(challenge)), { code: 'challenge_consumed' });
  assert.equal((await f.service.deliverOne()).code, 'accepted');
  assert.equal(f.receiptMails[0].receipt, first.receipt);
  assert.equal(f.signatures.length, 1);
});

test('independent connections converge concurrent approvals on one durable intent, receipt and outbox', async t => {
  const f = await fixture(t), challenge = await f.startAndMail(), input = await f.approval(challenge);
  const other = f.connect(), entered = gate(), finish = gate();
  f.mutable.duringSigning = async () => { if (f.signatures.length === 2) entered.release(); await finish.promise; };
  const pending = [f.service.approve(input), other.service.approve(input)];
  await entered.promise; finish.release();
  const results = await Promise.all(pending);
  assert.equal(results[0].receipt, results[1].receipt);
  assert.equal(f.service.snapshot().issued, 1);
  assert.equal(f.db.prepare("SELECT count(*) AS n FROM device_licence_outbox WHERE kind='receipt'").get().n, 1);
  assert.equal(new Set(f.signatures.map(fields => fields.receiptID)).size, 1);
  // Sign calls can repeat across concurrent adapter instances; only one envelope commits.
});

test('refund committed during signing defeats a stale active read and survives restart', async t => {
  const f = await fixture(t), challenge = await f.startAndMail(), input = await f.approval(challenge);
  f.mutable.readSnapshot = { id: f.id, product: 'pro', status: 'active', revision: 1, ownerEmail: 'owner@example.invalid' };
  f.mutable.duringSigning = () => f.refund();
  await assert.rejects(f.service.approve(input), { code: 'entitlement_ineligible' });
  assert.equal(f.service.snapshot().issued, 0);
  f.restart();
  await assert.rejects(f.service.approve(input), { code: 'entitlement_ineligible' });
  assert.equal(f.signatures.length, 1);
});

test('revision change during signing invalidates the old challenge without an issued receipt', async t => {
  const f = await fixture(t), challenge = await f.startAndMail();
  f.mutable.duringSigning = async () => {
    f.mutable.revision++;
    await f.service.observeEntitlement({ id: f.id, product: 'pro', revision: f.mutable.revision, status: 'active' });
  };
  await assert.rejects(f.service.approve(await f.approval(challenge)), { code: 'entitlement_revision_changed' });
  assert.equal(f.service.snapshot().issued, 0);
});

test('refund before claim and while decrypting cancels approval mail before dispatch', async t => {
  const f = await fixture(t);
  await f.start(); await f.refund('disputed');
  assert.equal((await f.service.deliverOne()).code, 'nothing_due');
  assert.equal(f.mails.length, 0);
  const second = await fixture(t);
  await second.start(); second.mutable.duringOpening = () => second.refund();
  assert.equal((await second.service.deliverOne()).code, 'delivery_deferred');
  assert.equal(second.mails.length, 0);
  assert.equal(second.service.snapshot().cancelled, 1);
});

test('refund during external acceptance remains cancelled; an already-issued offline receipt still verifies', async t => {
  const f = await fixture(t), challenge = await f.startAndMail(), input = await f.approval(challenge);
  const issued = await f.service.approve(input);
  f.mutable.duringDelivery = () => f.refund();
  assert.equal((await f.service.deliverOne()).code, 'accepted_after_cancellation');
  assert.equal(f.receiptMails.length, 1);
  assert.equal(f.service.snapshot().cancelled, 1);
  assert.equal((await f.service.deliverOne()).code, 'nothing_due');
  f.mutable.authorityFailure = true;
  assert.equal((await verifyOffline(issued.receipt, f.device.provider, f.trust)).receiptID, parseReceipt(issued.receipt).fields.receiptID);
});

test('accepted-before-ack retry after restart sends the same receipt and stable delivery ID without signing again', async t => {
  const f = await fixture(t), challenge = await f.startAndMail();
  const issued = await f.service.approve(await f.approval(challenge));
  f.mutable.duringDelivery = async () => { throw new Error('synthetic lost acknowledgement'); };
  assert.equal((await f.service.deliverOne()).code, 'delivery_uncertain');
  assert.equal(f.service.snapshot().uncertain, 1);
  f.restart();
  assert.equal((await f.service.deliverOne()).code, 'nothing_due');
  f.mutable.now += 30; f.mutable.duringDelivery = undefined;
  assert.equal((await f.service.deliverOne()).code, 'accepted');
  assert.deepEqual(f.receiptMails.map(mail => mail.receipt), [issued.receipt, issued.receipt]);
  assert.equal(f.receiptMails[0].deliveryID, f.receiptMails[1].deliveryID);
  assert.equal(f.signatures.length, 1);
  assert.equal(f.service.snapshot().uncertain, 1); // successful retry does not erase the prior unknown attempt
  assert.deepEqual(f.db.prepare('SELECT outcome FROM device_licence_delivery_attempts ORDER BY rowid').all()
    .map(row => row.outcome), ['accepted', 'uncertain', 'accepted']);
});

test('uncertain approval-mail retry decrypts the original token instead of rotating it', async t => {
  const f = await fixture(t);
  await f.start(); f.mutable.duringDelivery = async () => { throw new Error('synthetic lost acknowledgement'); };
  assert.equal((await f.service.deliverOne()).code, 'delivery_uncertain');
  f.restart(); f.mutable.now += 30; f.mutable.duringDelivery = undefined;
  assert.equal((await f.service.deliverOne()).code, 'accepted');
  assert.equal(f.mails[0].token, f.mails[1].token);
  assert.equal(f.mails[0].deliveryID, f.mails[1].deliveryID);
  assert.equal(f.signatures.length, 0);
});

test('real SQLite rollback leaves neither half of challenge/outbox or issuance/outbox writes', async t => {
  const f = await fixture(t), requestID = randomToken(16);
  f.mutable.failSQL = 'INSERT INTO device_licence_outbox';
  await assert.rejects(f.start(requestID), /synthetic write failure/);
  assert.equal(f.service.snapshot().challenges, 0);
  assert.equal(f.service.snapshot().pending, 0);
  f.restart();
  const { challenge } = await f.start(requestID);
  await f.service.deliverOne();
  const input = await f.approval(challenge);
  f.mutable.failSQL = 'INSERT INTO device_licence_outbox';
  await assert.rejects(f.service.approve(input), /synthetic write failure/);
  assert.equal(f.service.snapshot().issued, 0);
  assert.equal(f.service.snapshot().pending, 0);
  f.restart();
  const result = await f.service.approve(input);
  assert.equal(result.code, 'issued');
  assert.equal(f.signatures.length, 2); // first signed candidate was never released/committed
  assert.deepEqual(f.signatures[0], f.signatures[1]); // persisted intent survives that crash boundary
  assert.equal(f.service.snapshot().issued, 1);
  assert.equal(f.service.snapshot().pending, 1);
});

test('authenticated outbox binding rejects ciphertext moved between two challenges', async t => {
  const f = await fixture(t);
  await f.start(); await f.start();
  const rows = f.db.prepare('SELECT id,sealed_token FROM device_licence_outbox ORDER BY rowid').all();
  f.db.prepare('UPDATE device_licence_outbox SET sealed_token=? WHERE id=?').run(rows[1].sealed_token, rows[0].id);
  assert.equal((await f.service.deliverOne()).code, 'delivery_deferred');
  assert.equal(f.mails.length, 0);
});

test('expired challenge, admission hold and authority outage never issue; database scope/version are exact', async t => {
  const f = await fixture(t), challenge = await f.startAndMail(), input = await f.approval(challenge);
  f.mutable.held = true;
  await assert.rejects(f.service.approve(input), { code: 'held_for_review' });
  f.mutable.held = false; f.mutable.admissionRevision++; f.mutable.authorityFailure = true;
  await assert.rejects(f.service.approve(input), /synthetic outage/);
  f.mutable.authorityFailure = false; f.mutable.now = challenge.expiresAt;
  await assert.rejects(f.service.approve(input), { code: 'challenge_expired' });
  assert.equal(f.signatures.length, 0);
  const wrong = f.connect();
  assert.throws(() => createSqliteActivationService({ ...f.options, storage: wrong.storage, entitlementID: randomToken(16) }), { code: 'storage_scope_mismatch' });
  f.db.exec('UPDATE device_licence_meta SET schema_version=1');
  assert.throws(() => createSqliteActivationService({ ...f.options, storage: wrong.storage }), { code: 'storage_scope_mismatch' });
});

test('an old delayed acknowledgement cannot replace a later lease result', async t => {
  const f = await fixture(t), started = gate(), finish = gate();
  await f.start();
  f.mutable.duringDelivery = async () => { started.release(); await finish.promise; };
  const first = f.service.deliverOne();
  await started.promise;
  const other = f.connect(); f.mutable.now += 30; f.mutable.duringDelivery = undefined;
  assert.equal((await other.service.deliverOne()).code, 'accepted');
  finish.release();
  assert.equal((await first).code, 'acknowledgement_superseded');
  assert.equal(f.service.snapshot().accepted, 1);
  assert.equal(f.mails[0].token, f.mails[1].token);
});

test('hold observed during begin sealing or refresh prevents challenge/outbox commit', async t => {
  for (const seam of ['duringSealing', 'duringRefresh']) {
    const f = await fixture(t);
    f.mutable[seam] = () => f.service.observeAdmission({ entitlementID: f.id, revision: 2, decision: 'hold' });
    await assert.rejects(f.start(), { code: 'held_for_review' });
    assert.equal(f.service.snapshot().challenges, 0, seam);
    assert.equal(f.service.snapshot().pending, 0, seam);
    assert.equal(f.db.prepare('SELECT admission_decision FROM device_licence_meta').get().admission_decision, 'hold');
  }
});

test('hold after approve_commit admission, during refresh, prevents issuance; newer allow recovers the same intent', async t => {
  const f = await fixture(t), challenge = await f.startAndMail(), input = await f.approval(challenge);
  f.mutable.duringAdmission = async event => {
    if (event.phase === 'approve_commit') f.mutable.duringRefresh = () =>
      f.service.observeAdmission({ entitlementID: f.id, revision: 2, decision: 'hold' });
  };
  await assert.rejects(f.service.approve(input), { code: 'held_for_review' });
  assert.equal(f.service.snapshot().issued, 0);
  assert.equal(f.db.prepare("SELECT count(*) AS n FROM device_licence_outbox WHERE kind='receipt'").get().n, 0);
  f.mutable.duringAdmission = undefined; f.mutable.duringRefresh = undefined;
  await f.service.observeAdmission({ entitlementID: f.id, revision: 3, decision: 'allow' });
  f.mutable.admissionRevision = 3;
  assert.equal((await f.service.approve(input)).code, 'issued');
  assert.deepEqual(f.signatures[0], f.signatures[1]);
});

test('hold during signing survives equal-revision and delayed older allows across restart', async t => {
  const f = await fixture(t), challenge = await f.startAndMail(), input = await f.approval(challenge);
  f.mutable.duringSigning = () => f.service.observeAdmission({ entitlementID: f.id, revision: 2, decision: 'hold' });
  await assert.rejects(f.service.approve(input), { code: 'held_for_review' });
  await f.service.observeAdmission({ entitlementID: f.id, revision: 2, decision: 'allow' });
  f.restart();
  await f.service.observeAdmission({ entitlementID: f.id, revision: 1, decision: 'allow' });
  await assert.rejects(f.service.approve(input), { code: 'held_for_review' });
  assert.equal(f.signatures.length, 1);
  const current = f.db.prepare('SELECT admission_revision,admission_decision FROM device_licence_meta').get();
  assert.equal(current.admission_revision, 2);
  assert.equal(current.admission_decision, 'hold');
});

test('unknown admission stays fail-closed and legacy/unversioned decisions are rejected', async t => {
  const f = await fixture(t), connection = f.connect();
  assert.equal(f.db.prepare('SELECT admission_decision FROM device_licence_meta').get().admission_decision, 'unknown');
  const legacy = createSqliteActivationService({ ...f.options, storage: connection.storage, admission: async () => 'allow' });
  await assert.rejects(f.start(randomToken(16), f.device, legacy), { code: 'malformed' });
  await assert.rejects(f.service.observeAdmission({ entitlementID: f.id, revision: 0, decision: 'allow' }), { code: 'admission_invalid' });
  await assert.rejects(f.service.observeAdmission({ entitlementID: randomToken(16), revision: 1, decision: 'allow' }), { code: 'admission_invalid' });
  assert.equal(f.service.snapshot().challenges, 0);
  assert.equal(f.db.prepare('SELECT admission_decision FROM device_licence_meta').get().admission_decision, 'unknown');
});

test('a newer allow cannot silently validate an earlier in-flight admission revision', async t => {
  const f = await fixture(t), requestID = randomToken(16);
  f.mutable.duringSealing = () => f.service.observeAdmission({ entitlementID: f.id, revision: 2, decision: 'allow' });
  await assert.rejects(f.start(requestID), { code: 'admission_revision_changed' });
  assert.equal(f.service.snapshot().challenges, 0);
  f.mutable.duringSealing = undefined; f.mutable.admissionRevision = 2;
  assert.equal((await f.start(requestID)).ok, true);
});

test('a signer mutating its input cannot change the persisted intent or expected payload', async t => {
  for (const [field, bytes] of [['receiptID', 16], ['deviceKeyHash', 32]]) {
    const f = await fixture(t), challenge = await f.startAndMail();
    f.mutable.mutateSignerFields = fields => { fields[field] = randomToken(bytes); };
    await assert.rejects(f.service.approve(await f.approval(challenge)), { code: 'signer_mismatch' });
    const record = JSON.parse(f.db.prepare('SELECT record FROM device_licence_challenges WHERE id=?').get(challenge.challengeID).record);
    assert.notEqual(record.signingIntent.fields[field], f.signatures[0][field]);
    assert.equal(record.status, 'pending');
    assert.equal(f.service.snapshot().issued, 0);
    assert.equal(f.db.prepare("SELECT count(*) AS n FROM device_licence_outbox WHERE kind='receipt'").get().n, 0);
  }
});
