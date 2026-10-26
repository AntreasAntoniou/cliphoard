// DISABLED synthetic adapter, deliberately not a Worker, route, persistence layer or mailer.
import { PROTOCOL, ProtocolError, need, exactFields, decode, epoch, randomToken, tokenDigest,
  canonicalDevice, verifyApprovalProof, sameTokenHash, verifyReceiptSignature, receiptPayload, base64url } from './protocol.mjs';
import { emptyActivationState, approvalDecision, reduceActivation } from './activation-state.mjs';

function verifiedEntitlement(value) {
  need(value && typeof value === 'object', 'entitlement_ineligible');
  decode(value.id, 16);
  need(Number.isSafeInteger(value.revision) && value.revision >= 1 && value.product === 'pro'
    && value.status === 'active' && typeof value.ownerEmail === 'string' && value.ownerEmail.length <= 254
    && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value.ownerEmail), 'entitlement_ineligible');
  return value;
}

export function createInMemoryActivationService({ issuerKeyID, issuerPublicKey, issueReceipt,
  resolveEntitlement, readEntitlement, deliverApproval, admission, clock, challengeTTLSeconds }) {
  // All external authority/effect seams must be supplied; there is no production default.
  for (const callback of [issueReceipt, resolveEntitlement, readEntitlement, deliverApproval, admission, clock]) need(typeof callback === 'function', 'configuration');
  need(Number.isSafeInteger(challengeTTLSeconds) && challengeTTLSeconds > 0 && challengeTTLSeconds <= 1800, 'configuration');
  const trustedIssuers = new Map([[issuerKeyID, issuerPublicKey]]);
  let state = emptyActivationState();
  let tail = Promise.resolve();
  const serial = action => {
    const result = tail.then(action);
    tail = result.then(() => undefined, () => undefined);
    return result;
  };
  const response = record => ({ ok: true, challenge: structuredClone(record.challenge) });
  const requireDecision = decision => need(decision.ok, decision.code);
  const checkAdmission = async (phase, entitlementID, deviceKeyHash, now) => {
    // This is a private admission hook, never analytics. No email, token or purchase handle.
    const decision = await admission({ phase, entitlementID, deviceKeyHash, now });
    return decision === 'allow';
  };

  return Object.freeze({
    begin(input) { return serial(async () => {
      exactFields(input, ['method', 'entitlementHandle', 'devicePublicKey', 'requestID']);
      need(input.method === 'POST', 'method_not_allowed');
      decode(input.entitlementHandle, 32); decode(input.requestID, 16);
      const device = await canonicalDevice(input.devicePublicKey);
      // This seam must validate the purchase with authoritative provider/ledger state;
      // neither a claimed email nor a caller-supplied entitlement object is accepted.
      const entitlement = verifiedEntitlement(await resolveEntitlement(input.entitlementHandle));
      const requestKey = `${entitlement.id}.${input.requestID}`;
      const duplicateID = state.requests[requestKey];
      if (duplicateID) {
        const record = state.challenges[duplicateID];
        need(record.challenge.devicePublicKey === device.publicKey, 'idempotency_conflict');
        return response(record); // no resend, token rotation or extra challenge
      }
      const now = epoch(clock());
      need(await checkAdmission('begin', entitlement.id, device.hash, now), 'held_for_review');
      const token = randomToken(32);
      const challenge = { purpose: PROTOCOL.approvalPurpose, version: 1, algorithm: PROTOCOL.algorithm,
        entitlementID: entitlement.id, devicePublicKey: device.publicKey, deviceKeyHash: device.hash,
        challengeID: randomToken(16), nonce: randomToken(32), expiresAt: epoch(now + challengeTTLSeconds) };
      const record = { status: 'pending', challenge, createdAt: now, entitlementRevision: entitlement.revision,
        approvalTokenHash: await tokenDigest(token) };
      const reduced = reduceActivation(state, { type: 'begin', requestKey, record });
      requireDecision(reduced.result);
      state = reduced.state;
      try {
        // No real sender is supplied here. The token goes ONLY to the purchaser's verified
        // address through this outbox seam, never to begin's caller or any telemetry.
        await deliverApproval({ to: entitlement.ownerEmail, challengeID: challenge.challengeID,
          token, expiresAt: challenge.expiresAt });
      } catch {
        // This prototype cannot provide transactional outbox delivery/retry. Do not
        // pretend it sent; this challenge remains pending and a NEW request is required.
        throw new ProtocolError('delivery_unavailable');
      }
      return response(record);
    }); },

    preview({ method }) {
      need(method === 'GET' || method === 'HEAD', 'method_not_allowed');
      // Generic response even for a nonexistent ID. No token consumption or state change.
      return { ok: true, code: 'confirmation_required' };
    },

    approve(input) { return serial(async () => {
      exactFields(input, ['method', 'challengeID', 'approvalToken', 'approvalRequestID', 'deviceSignature']);
      need(input.method === 'POST', 'method_not_allowed');
      decode(input.challengeID, 16); decode(input.approvalRequestID, 16);
      decode(input.approvalToken, 32); decode(input.deviceSignature, 64);
      const record = state.challenges[input.challengeID];
      need(record, 'unknown_challenge');
      const candidateHash = await tokenDigest(input.approvalToken);
      const tokenMatches = sameTokenHash(record.approvalTokenHash, candidateHash);
      need(tokenMatches, 'approval_rejected');
      const deviceProofVerified = await verifyApprovalProof(record.challenge, candidateHash,
        input.approvalRequestID, input.deviceSignature);
      need(deviceProofVerified, 'approval_rejected');
      const entitlement = verifiedEntitlement(await readEntitlement(record.challenge.entitlementID));
      const now = epoch(clock());
      const admitted = await checkAdmission('approve', entitlement.id, record.challenge.deviceKeyHash, now);
      let event = { type: 'approve', expectedRevision: state.revision, method: input.method,
        challengeID: input.challengeID, approvalRequestID: input.approvalRequestID, now,
        entitlementActive: true, entitlementID: entitlement.id, entitlementRevision: entitlement.revision,
        tokenMatches, deviceProofVerified, admitted };
      const decision = approvalDecision(record, event);
      requireDecision(decision);
      if (decision.code === 'already_issued') return decision;

      const fields = { issuerKeyID, entitlementID: entitlement.id, deviceKeyHash: record.challenge.deviceKeyHash,
        receiptID: randomToken(16), issuedAt: now };
      const receipt = await issueReceipt(fields);
      const parsed = await verifyReceiptSignature(receipt, trustedIssuers);
      need(base64url(parsed.payload) === base64url(receiptPayload(fields)), 'signer_mismatch');
      // Re-read after asynchronous signing. A refund/revision change or expiry during
      // signing must win. Production additionally needs one durable ledger transaction.
      const commitAdmitted = await checkAdmission('approve_commit', entitlement.id,
        record.challenge.deviceKeyHash, epoch(clock()));
      const latest = verifiedEntitlement(await readEntitlement(record.challenge.entitlementID));
      event = { ...event, now: epoch(clock()), entitlementID: latest.id, entitlementRevision: latest.revision,
        admitted: commitAdmitted, receipt };
      const reduced = reduceActivation(state, event);
      requireDecision(reduced.result);
      state = reduced.state;
      return reduced.result;
    }); },

    // Diagnostic counts only. No tokens, email, handles, key IDs or entitlement identifiers.
    snapshot() { return Object.freeze({ revision: state.revision,
      pending: Object.values(state.challenges).filter(record => record.status === 'pending').length,
      issued: Object.values(state.challenges).filter(record => record.status === 'issued').length }); },
  });
}
