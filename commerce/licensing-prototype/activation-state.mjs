// Pure reducer. Crypto/provider facts come ONLY from the adapter, never request booleans.
// Production must execute the read/decision/write atomically in durable per-entitlement storage.
export function emptyActivationState() { return { revision: 0, requests: {}, challenges: {} }; }
const refused = code => ({ ok: false, code });

export function approvalDecision(record, event) {
  if (event.method !== 'POST') return refused('method_not_allowed');
  if (!record) return refused('unknown_challenge');
  if (!Number.isSafeInteger(event.now) || event.now <= 0
    || (record.status !== 'pending' && record.status !== 'issued')) return refused('invalid_transition');
  if (event.entitlementActive !== true || event.entitlementID !== record.challenge.entitlementID
    || event.entitlementRevision !== record.entitlementRevision) return refused('entitlement_ineligible');
  if (event.tokenMatches !== true || event.deviceProofVerified !== true) return refused('approval_rejected');
  if (record.status === 'issued') {
    if (record.approvalRequestID === event.approvalRequestID) {
      // A delivery retry returns the exact original receipt; it does not consume again.
      return { ok: true, code: 'already_issued', receipt: record.receipt };
    }
    return refused('challenge_consumed');
  }
  if (event.now < record.createdAt || event.now >= record.challenge.expiresAt) return refused('challenge_expired');
  if (event.admitted !== true) return refused('held_for_review');
  return { ok: true, code: 'ready' };
}

export function reduceActivation(state, event) {
  if (event.type === 'begin') {
    const existingID = state.requests[event.requestKey];
    if (existingID) {
      const existing = state.challenges[existingID];
      if (existing.challenge.devicePublicKey !== event.record.challenge.devicePublicKey) {
        return { state, result: refused('idempotency_conflict') };
      }
      return { state, result: { ok: true, code: 'duplicate', record: existing } };
    }
    if (state.challenges[event.record.challenge.challengeID]) return { state, result: refused('nonce_collision') };
    const next = { revision: state.revision + 1,
      requests: { ...state.requests, [event.requestKey]: event.record.challenge.challengeID },
      challenges: { ...state.challenges, [event.record.challenge.challengeID]: event.record } };
    return { state: next, result: { ok: true, code: 'created', record: event.record } };
  }
  if (event.type === 'approve') {
    if (state.revision !== event.expectedRevision) return { state, result: refused('revision_conflict') };
    const record = state.challenges[event.challengeID];
    const decision = approvalDecision(record, event);
    if (!decision.ok || decision.code === 'already_issued') return { state, result: decision };
    if (typeof event.receipt !== 'string' || !event.receipt.startsWith('CLIPD1.')) {
      return { state, result: refused('receipt_unavailable') };
    }
    const nextRecord = { ...record, status: 'issued', approvalRequestID: event.approvalRequestID,
      receipt: event.receipt, issuedAt: event.now };
    return { state: { ...state, revision: state.revision + 1,
      challenges: { ...state.challenges, [event.challengeID]: nextRecord } },
    result: { ok: true, code: 'issued', receipt: event.receipt } };
  }
  // Viewing an email link is deliberately a no-op. GET/HEAD can never approve.
  if (event.type === 'preview') return { state, result: { ok: true, code: 'confirmation_required' } };
  return { state, result: refused('unknown_event') };
}
