// DISABLED candidate: no Worker export, route, binding, signer, mailer or scheduler.
import { PROTOCOL, need, exactFields, decode, epoch, randomToken,
  tokenDigest, canonicalDevice, verifyApprovalProof, sameTokenHash,
  verifyReceiptSignature, receiptPayload, base64url } from './protocol.mjs';
import { approvalDecision } from './activation-state.mjs';

function entitlement(value, expectedID, recipient = false) {
  need(value && value.id === expectedID && value.product === 'pro'
    && Number.isSafeInteger(value.revision) && value.revision >= 1
    && ['active', 'refunded', 'disputed', 'blocked'].includes(value.status), 'entitlement_ineligible');
  if (recipient) need(typeof value.ownerEmail === 'string' && value.ownerEmail.length <= 254
    && /^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/.test(value.ownerEmail), 'entitlement_ineligible');
  return { id: value.id, revision: value.revision, status: value.status,
    product: 'pro', ...(recipient ? { ownerEmail: value.ownerEmail } : {}) };
}

export function createSqliteActivationService({ storage, entitlementID, issuerKeyID,
  issuerPublicKey, issueReceipt, resolveEntitlement, readEntitlement, sealToken, openToken,
  deliverApproval, deliverReceipt, admission, clock, challengeTTLSeconds, deliveryLeaseSeconds,
  readAuthorityFence }) {
  decode(entitlementID, 16);
  need(storage?.sql?.exec && typeof storage.transactionSync === 'function'
    && typeof storage.sync === 'function', 'configuration');
  for (const callback of [issueReceipt, resolveEntitlement, readEntitlement, sealToken,
    openToken, deliverApproval, deliverReceipt, admission, clock]) need(typeof callback === 'function', 'configuration');
  need(readAuthorityFence === undefined || typeof readAuthorityFence === 'function', 'configuration');
  need(Number.isSafeInteger(challengeTTLSeconds) && challengeTTLSeconds > 0
    && challengeTTLSeconds <= 1800 && Number.isSafeInteger(deliveryLeaseSeconds)
    && deliveryLeaseSeconds > 0 && deliveryLeaseSeconds <= 1800, 'configuration');
  const exec = (query, ...args) => Array.from(storage.sql.exec(query, ...args));
  const tx = callback => storage.transactionSync(callback);
  const now = () => epoch(clock());
  const trust = new Map([[issuerKeyID, issuerPublicKey]]);
  tx(() => {
    exec(`CREATE TABLE IF NOT EXISTS device_licence_meta (
      singleton INTEGER PRIMARY KEY CHECK(singleton=1), schema_version INTEGER NOT NULL,
      entitlement_id TEXT NOT NULL, revision INTEGER NOT NULL, status TEXT NOT NULL,
      admission_revision INTEGER NOT NULL, admission_decision TEXT NOT NULL)`);
    if (exec('SELECT * FROM device_licence_meta').length === 0)
      exec(`INSERT INTO device_licence_meta VALUES(1,2,?,0,'unknown',0,'unknown')`, entitlementID);
    const meta = exec('SELECT * FROM device_licence_meta')[0];
    need(meta.schema_version === 2 && meta.entitlement_id === entitlementID, 'storage_scope_mismatch');
    exec(`CREATE TABLE IF NOT EXISTS device_licence_challenges (
      id TEXT PRIMARY KEY, request_id TEXT NOT NULL UNIQUE, record TEXT NOT NULL)`);
    exec(`CREATE TABLE IF NOT EXISTS device_licence_outbox (
      id TEXT PRIMARY KEY, challenge_id TEXT NOT NULL, kind TEXT NOT NULL,
      status TEXT NOT NULL, sealed_token TEXT, lease_id TEXT, lease_until INTEGER,
      attempts INTEGER NOT NULL DEFAULT 0, outcome TEXT NOT NULL DEFAULT 'not_attempted')`);
    exec(`CREATE TABLE IF NOT EXISTS device_licence_delivery_attempts (
      lease_id TEXT PRIMARY KEY, outbox_id TEXT NOT NULL, started_at INTEGER NOT NULL,
      outcome TEXT NOT NULL, finished_at INTEGER)`);
  });
  const meta = () => exec('SELECT revision,status,admission_revision,admission_decision FROM device_licence_meta')[0];
  const recordFor = id => {
    const row = exec('SELECT record FROM device_licence_challenges WHERE id=?', id)[0];
    return row ? JSON.parse(row.record) : undefined;
  };
  const requireCurrent = revision => {
    const current = meta();
    need(current.status === 'active', 'entitlement_ineligible');
    need(current.revision === revision, 'entitlement_revision_changed');
    if (readAuthorityFence !== undefined) {
      // A same-database committed block must win even while its asynchronous
      // observeEntitlement notification is pending. No I/O or Promise is allowed.
      try {
        const fact = readAuthorityFence();
        need(fact && typeof fact === 'object'
          && [Object.prototype, null].includes(Object.getPrototypeOf(fact)));
        const descriptors = Object.getOwnPropertyDescriptors(fact);
        const keys = Reflect.ownKeys(descriptors);
        need(keys.length === 3 && ['id', 'revision', 'status'].every(key =>
          descriptors[key] && Object.hasOwn(descriptors[key], 'value')));
        need(descriptors.id.value === entitlementID && Number.isSafeInteger(descriptors.revision.value)
          && descriptors.revision.value >= 1 && descriptors.revision.value === revision
          && descriptors.status.value === 'active');
      } catch { need(false, 'authority_fence_rejected'); }
    }
  };
  function observe(value) {
    const current = meta();
    if (value.revision < current.revision) return;
    // At an equal revision, an ineligible observation wins over active. A stale
    // active read cannot undo a refund already committed by another operation.
    if (value.revision === current.revision && current.status !== 'active'
      && current.status !== 'unknown' && value.status === 'active') return;
    exec('UPDATE device_licence_meta SET revision=?,status=?', value.revision, value.status);
    if (value.status !== 'active' || value.revision !== current.revision) {
      for (const row of exec("SELECT id,challenge_id FROM device_licence_outbox WHERE status IN ('pending','leased')")) {
        const record = recordFor(row.challenge_id);
        if (value.status !== 'active' || record.entitlementRevision !== value.revision)
          exec("UPDATE device_licence_outbox SET status='cancelled',sealed_token=NULL WHERE id=?", row.id);
      }
    }
  }
  async function observeEntitlement(value) {
    const verified = entitlement(value, entitlementID);
    tx(() => observe(verified));
    await storage.sync();
  }
  async function refresh() {
    const value = entitlement(await readEntitlement(entitlementID), entitlementID, true);
    await observeEntitlement(value);
    need(value.status === 'active', 'entitlement_ineligible');
    requireCurrent(value.revision);
    return value;
  }
  async function observeAdmission(value) {
    exactFields(value, ['entitlementID', 'revision', 'decision']);
    need(value.entitlementID === entitlementID && Number.isSafeInteger(value.revision)
      && value.revision >= 1 && ['allow', 'hold'].includes(value.decision), 'admission_invalid');
    tx(() => {
      const current = meta();
      if (value.revision < current.admission_revision) return;
      if (value.revision === current.admission_revision
        && current.admission_decision === 'hold' && value.decision === 'allow') return;
      exec('UPDATE device_licence_meta SET admission_revision=?,admission_decision=?', value.revision, value.decision);
    });
    await storage.sync();
  }
  const requireAdmission = revision => {
    const current = meta();
    need(current.admission_decision === 'allow', 'held_for_review');
    need(current.admission_revision === revision, 'admission_revision_changed');
  };
  const admitted = async (phase, record) => {
    const fact = await admission({ phase, entitlementID,
      deviceKeyHash: record.challenge.deviceKeyHash, now: now() });
    exactFields(fact, ['revision', 'decision']);
    await observeAdmission({ entitlementID, ...fact });
    return fact.revision;
  };
  const response = record => ({ ok: true, challenge: record.challenge });
  const aad = record => `cliphoard.approval-outbox\n1\n${entitlementID}\n${record.entitlementRevision}\n${record.challenge.challengeID}\n${record.approvalTokenHash}\n`;
  let tail = Promise.resolve();
  const serialApproval = action => {
    const result = tail.then(action);
    tail = result.then(() => undefined, () => undefined);
    return result;
  };
  function decision(record, input, admissionRevision) {
    requireCurrent(record.entitlementRevision);
    // Already-issued retrieval is not a new approval. Refund checks still apply.
    if (record.status !== 'issued') requireAdmission(admissionRevision);
    const result = approvalDecision(record, { method: input.method, now: now(),
      entitlementActive: true, entitlementID, entitlementRevision: record.entitlementRevision,
      tokenMatches: true, deviceProofVerified: true, admitted: true,
      approvalRequestID: input.approvalRequestID });
    need(result.ok, result.code);
    return result;
  }

  return Object.freeze({
    // TRUSTED internal feed only. A future verified commerce adapter must route
    // refunds and revisions into this same per-entitlement object; never an HTTP input.
    observeEntitlement,
    // TRUSTED admission authority feed, independently revisioned. A remote hold
    // not yet observed here is not an atomic global revocation signal.
    observeAdmission,
    async begin(input) {
      exactFields(input, ['method', 'entitlementHandle', 'devicePublicKey', 'requestID']);
      need(input.method === 'POST', 'method_not_allowed');
      decode(input.entitlementHandle, 32); decode(input.requestID, 16);
      const device = await canonicalDevice(input.devicePublicKey);
      const value = entitlement(await resolveEntitlement(input.entitlementHandle), entitlementID, true);
      await observeEntitlement(value);
      need(value.status === 'active', 'entitlement_ineligible');
      requireCurrent(value.revision);
      const duplicate = exec('SELECT record FROM device_licence_challenges WHERE request_id=?', input.requestID)[0];
      if (duplicate) {
        const record = JSON.parse(duplicate.record);
        need(record.challenge.devicePublicKey === device.publicKey, 'idempotency_conflict');
        return response(record);
      }
      const createdAt = now(), token = randomToken(32);
      const record = { status: 'pending', createdAt, entitlementRevision: value.revision,
        approvalTokenHash: await tokenDigest(token), challenge: {
          purpose: PROTOCOL.approvalPurpose, version: 1, algorithm: PROTOCOL.algorithm,
          entitlementID, devicePublicKey: device.publicKey, deviceKeyHash: device.hash,
          challengeID: randomToken(16), nonce: randomToken(32), expiresAt: epoch(createdAt + challengeTTLSeconds),
        } };
      const admissionRevision = await admitted('begin', record);
      requireAdmission(admissionRevision);
      // Injected authenticated encryption; no default, plaintext fallback or key storage.
      const sealed = await sealToken(token, aad(record));
      need(typeof sealed === 'string' && sealed.length >= 32 && sealed.length <= 2048
        && sealed !== token, 'sealed_token_invalid');
      await refresh();
      const result = tx(() => {
        requireCurrent(value.revision);
        requireAdmission(admissionRevision);
        need(now() >= createdAt && now() < record.challenge.expiresAt, 'challenge_expired');
        const duplicate = exec('SELECT record FROM device_licence_challenges WHERE request_id=?', input.requestID)[0];
        if (duplicate) {
          const previous = JSON.parse(duplicate.record);
          need(previous.challenge.devicePublicKey === device.publicKey, 'idempotency_conflict');
          return response(previous);
        }
        exec('INSERT INTO device_licence_challenges VALUES(?,?,?)', record.challenge.challengeID,
          input.requestID, JSON.stringify(record));
        exec(`INSERT INTO device_licence_outbox(id,challenge_id,kind,status,sealed_token)
          VALUES(?,?,'approval','pending',?)`, `${record.challenge.challengeID}.approval`, record.challenge.challengeID, sealed);
        return response(record);
      });
      await storage.sync();
      return result;
    },
    preview({ method }) {
      need(method === 'GET' || method === 'HEAD', 'method_not_allowed');
      return { ok: true, code: 'confirmation_required' };
    },
    approve(input) { return serialApproval(async () => {
      exactFields(input, ['method', 'challengeID', 'approvalToken', 'approvalRequestID', 'deviceSignature']);
      need(input.method === 'POST', 'method_not_allowed');
      decode(input.challengeID, 16); decode(input.approvalRequestID, 16);
      decode(input.approvalToken, 32); decode(input.deviceSignature, 64);
      const record = recordFor(input.challengeID);
      need(record, 'unknown_challenge');
      const hash = await tokenDigest(input.approvalToken);
      need(sameTokenHash(record.approvalTokenHash, hash)
        && await verifyApprovalProof(record.challenge, hash, input.approvalRequestID, input.deviceSignature), 'approval_rejected');
      await refresh();
      const previouslyIssued = recordFor(input.challengeID);
      if (previouslyIssued.status === 'issued') return decision(previouslyIssued, input);
      const startAdmissionRevision = await admitted('approve', record);
      const intent = tx(() => {
        const latest = recordFor(input.challengeID);
        const ready = decision(latest, input, startAdmissionRevision);
        if (ready.code === 'already_issued') return ready;
        if (latest.signingIntent) {
          need(latest.signingIntent.approvalRequestID === input.approvalRequestID, 'approval_in_progress');
          return latest.signingIntent;
        }
        const signingIntent = { approvalRequestID: input.approvalRequestID, fields: {
          issuerKeyID, entitlementID, deviceKeyHash: record.challenge.deviceKeyHash,
          receiptID: randomToken(16), issuedAt: now(),
        } };
        exec('UPDATE device_licence_challenges SET record=? WHERE id=?',
          JSON.stringify({ ...latest, signingIntent }), input.challengeID);
        return signingIntent;
      });
      await storage.sync();
      if (intent.code === 'already_issued') return intent;
      const { fields } = intent;
      const expectedPayload = base64url(receiptPayload(fields));
      const receipt = await issueReceipt(structuredClone(fields));
      const verified = await verifyReceiptSignature(receipt, trust);
      need(base64url(verified.payload) === expectedPayload, 'signer_mismatch');
      const commitAdmissionRevision = await admitted('approve_commit', record);
      await refresh();
      const result = tx(() => {
        const latest = recordFor(input.challengeID);
        const current = decision(latest, input, commitAdmissionRevision);
        if (current.code === 'already_issued') return current;
        const issued = { ...latest, status: 'issued', receipt,
          approvalRequestID: input.approvalRequestID, issuedAt: fields.issuedAt };
        exec('UPDATE device_licence_challenges SET record=? WHERE id=?', JSON.stringify(issued), input.challengeID);
        exec(`UPDATE device_licence_outbox SET sealed_token=NULL,
          status=CASE WHEN status='accepted' THEN status ELSE 'cancelled' END
          WHERE challenge_id=? AND kind='approval'`, input.challengeID);
        exec(`INSERT INTO device_licence_outbox(id,challenge_id,kind,status)
          VALUES(?,?,'receipt','pending')`, `${input.challengeID}.receipt`, input.challengeID);
        return { ok: true, code: 'issued', receipt };
      });
      await storage.sync();
      return result;
    }); },
    async deliverOne() {
      const candidate = exec(`SELECT * FROM device_licence_outbox WHERE status='pending'
        OR (status='leased' AND lease_until<=?) ORDER BY rowid LIMIT 1`, now())[0];
      if (!candidate) return { ok: true, code: 'nothing_due' };
      await refresh();
      const leaseID = randomToken(16);
      const claimed = tx(() => {
        const row = exec('SELECT * FROM device_licence_outbox WHERE id=?', candidate.id)[0];
        if (!(row.status === 'pending' || (row.status === 'leased' && row.lease_until <= now()))) return false;
        const record = recordFor(row.challenge_id);
        requireCurrent(record.entitlementRevision);
        if (row.kind === 'approval' && (record.status !== 'pending'
          || now() < record.createdAt || now() >= record.challenge.expiresAt)) {
          exec("UPDATE device_licence_outbox SET status='cancelled',sealed_token=NULL WHERE id=?", row.id);
          return false;
        }
        // Reclaiming a crashed/expired lease must not erase its uncertain outcome.
        if (row.lease_id) exec(`UPDATE device_licence_delivery_attempts SET outcome='uncertain'
          WHERE lease_id=? AND outcome='in_flight'`, row.lease_id);
        exec(`INSERT INTO device_licence_delivery_attempts VALUES(?,?,?,'in_flight',NULL)`, leaseID, row.id, now());
        exec(`UPDATE device_licence_outbox SET status='leased',lease_id=?,lease_until=?,
          attempts=attempts+1,outcome='in_flight' WHERE id=?`, leaseID, epoch(now() + deliveryLeaseSeconds), row.id);
        return { row, record };
      });
      await storage.sync();
      if (!claimed) return { ok: true, code: 'not_claimed' };
      let dispatched = false;
      try {
        const { row, record } = claimed;
        let token;
        if (row.kind === 'approval') {
          token = await openToken(row.sealed_token, aad(record));
          need(sameTokenHash(record.approvalTokenHash, await tokenDigest(token)), 'sealed_token_invalid');
        }
        const owner = await refresh();
        const authorizeDispatch = () => tx(() => {
          requireCurrent(record.entitlementRevision);
          const current = exec('SELECT * FROM device_licence_outbox WHERE id=?', row.id)[0];
          need(current.status === 'leased' && current.lease_id === leaseID
            && now() < current.lease_until, 'delivery_superseded');
          const latest = recordFor(row.challenge_id);
          need(latest.entitlementRevision === record.entitlementRevision, 'delivery_superseded');
          if (row.kind === 'approval') need(now() >= record.createdAt
            && now() < record.challenge.expiresAt && latest.status === 'pending', 'challenge_expired');
          else need(latest.status === 'issued' && latest.receipt === record.receipt, 'delivery_superseded');
        });
        authorizeDispatch();
        dispatched = true;
        const common = { to: owner.ownerEmail, deliveryID: row.id, challengeID: row.challenge_id,
          entitlementID, entitlementRevision: record.entitlementRevision,
          deviceKeyHash: record.challenge.deviceKeyHash, authorizeDispatch };
        const result = await (row.kind === 'approval'
          ? deliverApproval({ ...common, token, expiresAt: record.challenge.expiresAt })
          : deliverReceipt({ ...common, receipt: record.receipt }));
        need(result?.accepted === true, 'delivery_not_confirmed');
        const code = tx(() => {
          exec("UPDATE device_licence_delivery_attempts SET outcome='accepted',finished_at=? WHERE lease_id=?", now(), leaseID);
          const current = exec('SELECT status,lease_id FROM device_licence_outbox WHERE id=?', row.id)[0];
          if (current.lease_id !== leaseID) return 'acknowledgement_superseded';
          exec(`UPDATE device_licence_outbox SET outcome='accepted',sealed_token=NULL,
            status=CASE WHEN status='cancelled' THEN status ELSE 'accepted' END WHERE id=?`, row.id);
          return current.status === 'cancelled' ? 'accepted_after_cancellation' : 'accepted';
        });
        await storage.sync();
        return { ok: true, code };
      } catch {
        // An exception after dispatch can mean accepted-before-ack. Keep the lease;
        // after expiry a retry may deliver the IDENTICAL token/receipt a second time.
        tx(() => {
          const outcome = dispatched ? 'uncertain' : 'not_dispatched';
          exec(`UPDATE device_licence_delivery_attempts SET outcome=?,finished_at=?
            WHERE lease_id=? AND outcome<>'accepted'`, outcome, now(), leaseID);
          exec('UPDATE device_licence_outbox SET outcome=? WHERE id=? AND lease_id=?', outcome, candidate.id, leaseID);
        });
        await storage.sync();
        return { ok: false, code: dispatched ? 'delivery_uncertain' : 'delivery_deferred' };
      }
    },
    nextDeliveryAt() {
      // Scheduling metadata only: no customer, device, token or outbox identifier.
      const value = exec(`SELECT MIN(CASE WHEN status='pending' THEN ? ELSE lease_until END) AS due
        FROM device_licence_outbox WHERE status IN ('pending','leased')`, now())[0].due;
      return value === null ? null : epoch(value);
    },
    snapshot() {
      // Fixed aggregate counters only. No email, token, key, device or customer IDs.
      return Object.freeze({
        challenges: exec('SELECT count(*) AS n FROM device_licence_challenges')[0].n,
        issued: exec("SELECT count(*) AS n FROM device_licence_challenges WHERE json_extract(record,'$.status')='issued'")[0].n,
        pending: exec("SELECT count(*) AS n FROM device_licence_outbox WHERE status='pending'")[0].n,
        leased: exec("SELECT count(*) AS n FROM device_licence_outbox WHERE status='leased'")[0].n,
        accepted: exec("SELECT count(*) AS n FROM device_licence_outbox WHERE status='accepted'")[0].n,
        cancelled: exec("SELECT count(*) AS n FROM device_licence_outbox WHERE status='cancelled'")[0].n,
        uncertain: exec("SELECT count(*) AS n FROM device_licence_delivery_attempts WHERE outcome='uncertain'")[0].n,
      });
    },
  });
}
