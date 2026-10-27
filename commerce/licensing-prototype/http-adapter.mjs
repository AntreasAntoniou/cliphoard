// DISABLED transport prototype. No Worker export, listener, authority lookup,
// provider, mail dispatch, deployment binding or background scheduler.
import { ProtocolError, exactFields, decode, canonicalDevice, validateChallenge, parseReceipt } from './protocol.mjs';

export const HTTP_LIMITS = Object.freeze({ maxBodyBytes: 2048, maxBodyTimeoutMs: 30000 });
const prefix = '/device-licensing/v1';
const beginFields = ['entitlementHandle', 'devicePublicKey', 'requestID'];
const approvalFields = ['challengeID', 'approvalToken', 'approvalRequestID', 'deviceSignature'];
const challengeFields = ['purpose', 'version', 'algorithm', 'entitlementID', 'devicePublicKey',
  'deviceKeyHash', 'challengeID', 'nonce', 'expiresAt'];
const denied = new Set(['unknown_challenge', 'approval_rejected', 'entitlement_ineligible',
  'challenge_expired', 'held_for_review', 'idempotency_conflict', 'challenge_consumed',
  'approval_in_progress', 'entitlement_revision_changed', 'admission_revision_changed']);
const headers = Object.freeze({ 'content-type': 'application/json; charset=utf-8',
  'cache-control': 'no-store', pragma: 'no-cache', 'referrer-policy': 'no-referrer',
  'x-content-type-options': 'nosniff', 'cross-origin-resource-policy': 'same-origin',
  'content-security-policy': "default-src 'none'; frame-ancestors 'none'" });

class HttpFailure extends Error {
  constructor(status, code) { super(code); this.status = status; this.code = code; }
}
const invalid = () => new HttpFailure(400, 'invalid_request');
const reply = (status, value, head = false, allow) => new Response(head ? null : JSON.stringify(value), {
  status, headers: { ...headers, ...(allow ? { allow } : {}) },
});
const failure = (status, code, head = false, allow) => reply(status, { ok: false, code }, head, allow);

function contentLength(request) {
  const value = request.headers.get('content-length');
  if (value === null) return undefined;
  if (!/^(0|[1-9][0-9]*)$/.test(value) || !Number.isSafeInteger(Number(value))) throw invalid();
  const length = Number(value);
  if (length > HTTP_LIMITS.maxBodyBytes) throw new HttpFailure(413, 'body_too_large');
  return length;
}

async function readBody(request, timeoutMs, expectedLength) {
  let reader;
  try { reader = request.body?.getReader(); } catch { throw invalid(); }
  if (!reader) throw invalid();
  let timer, onAbort, completed = false;
  const end = performance.now() + timeoutMs;
  const deadline = new Promise((_, reject) => {
    onAbort = () => reject(new HttpFailure(400, 'request_aborted'));
    request.signal.addEventListener('abort', onAbort, { once: true });
    timer = setTimeout(() => reject(new HttpFailure(408, 'request_timeout')), timeoutMs);
    if (request.signal.aborted) onAbort();
  });
  const chunks = [];
  let length = 0;
  try {
    while (true) {
      const { value, done } = await Promise.race([reader.read(), deadline]);
      if (request.signal.aborted) throw new HttpFailure(400, 'request_aborted');
      if (performance.now() >= end) throw new HttpFailure(408, 'request_timeout');
      if (done) { completed = true; break; }
      // Empty chunks cannot spin through microtasks indefinitely and starve the timer.
      if (!(value instanceof Uint8Array) || value.byteLength === 0) throw invalid();
      length += value.byteLength;
      if (length > HTTP_LIMITS.maxBodyBytes) throw new HttpFailure(413, 'body_too_large');
      chunks.push(value.slice());
    }
    if (expectedLength !== undefined && length !== expectedLength) throw invalid();
    const bytes = new Uint8Array(length);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    return new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes);
  } catch (error) {
    throw error instanceof HttpFailure ? error : invalid();
  } finally {
    clearTimeout(timer);
    request.signal.removeEventListener('abort', onAbort);
    if (!completed) {
      // An untrusted underlying cancel can stay pending. Observe rejection, never await it.
      try { Promise.resolve(reader.cancel()).catch(() => {}); } catch {}
    }
    try { reader.releaseLock(); } catch {}
  }
}

// Only a flat JSON object of strings is on the wire. Parsing individual JSON
// string tokens preserves normal escapes while detecting duplicate decoded keys;
// JSON.parse(object) alone would silently discard earlier duplicate fields.
function parseBody(text, fields) {
  let offset = 0;
  const result = Object.create(null), seen = new Set();
  const string = /"(?:[^"\\\u0000-\u001f]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*"/y;
  const whitespace = () => { while (/[ \t\r\n]/.test(text[offset] ?? '') && offset < text.length) offset++; };
  const take = expected => { whitespace(); if (text[offset++] !== expected) throw invalid(); };
  const readString = () => {
    whitespace(); string.lastIndex = offset;
    const match = string.exec(text);
    if (!match) throw invalid();
    offset = string.lastIndex;
    return JSON.parse(match[0]);
  };
  take('{'); whitespace();
  if (text[offset] !== '}') while (true) {
    const key = readString();
    if (!fields.includes(key) || seen.has(key)) throw invalid();
    seen.add(key); take(':'); result[key] = readString(); whitespace();
    if (text[offset] !== ',') break;
    offset++;
  }
  take('}'); whitespace();
  if (offset !== text.length) throw invalid();
  exactFields(result, fields);
  return result;
}

function snapshot(object, fields) {
  exactFields(object, fields);
  return Object.fromEntries(fields.map(field => [field, object[field]]));
}

export function createActivationHttpHandler({ enabled = false, service, entitlementID, origin, bodyTimeoutMs } = {}) {
  // Only trusted construction can opt in. No request header/body/query can enable it.
  const active = enabled === true;
  let operations;
  if (active) {
    try {
      const url = new URL(origin);
      if (url.protocol !== 'https:' || url.origin !== origin || typeof service?.begin !== 'function'
        || typeof service?.approve !== 'function' || !Number.isSafeInteger(bodyTimeoutMs)
        || bodyTimeoutMs < 1 || bodyTimeoutMs > HTTP_LIMITS.maxBodyTimeoutMs) throw invalid();
      decode(entitlementID, 16);
      operations = Object.freeze({ begin: service.begin.bind(service), approve: service.approve.bind(service) });
    } catch { throw new TypeError('invalid_adapter_configuration'); }
  }

  return async request => {
    const head = request instanceof Request && request.method === 'HEAD';
    if (!active) return failure(404, 'unavailable', head);
    try {
      if (!(request instanceof Request)) throw invalid();
      const url = new URL(request.url);
      if (url.origin !== origin || request.url.includes('?') || request.url.includes('#')) throw invalid();
      const routes = { [`${prefix}/begin`]: 'begin', [`${prefix}/approve`]: 'approve', [`${prefix}/confirmation`]: 'confirmation' };
      const operation = routes[url.pathname];
      if (!operation) return failure(404, 'not_found', head);
      const allow = operation === 'confirmation' ? 'GET, HEAD' : 'POST';
      if (!(operation === 'confirmation' ? ['GET', 'HEAD'].includes(request.method) : request.method === 'POST'))
        return failure(405, 'method_not_allowed', head, allow);
      const requestOrigin = request.headers.get('origin'), site = request.headers.get('sec-fetch-site');
      if ((requestOrigin !== null && requestOrigin !== origin) || (site !== null && !['same-origin', 'none'].includes(site)))
        return failure(403, 'forbidden', head);
      // Public, generic and entirely independent of challenge/ledger state.
      if (operation === 'confirmation') return reply(200, { ok: true, code: 'confirmation_required' }, head);
      const type = request.headers.get('content-type') ?? '', encoding = request.headers.get('content-encoding');
      if (!/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(type)
        || (encoding !== null && encoding.toLowerCase() !== 'identity'))
        return failure(415, 'unsupported_media_type');
      if (request.signal.aborted) throw new HttpFailure(400, 'request_aborted');
      const text = await readBody(request, bodyTimeoutMs, contentLength(request));
      const body = parseBody(text, operation === 'begin' ? beginFields : approvalFields);
      let device;
      if (operation === 'begin') {
        decode(body.entitlementHandle, 32); decode(body.requestID, 16);
        device = await canonicalDevice(body.devicePublicKey);
      } else {
        decode(body.challengeID, 16); decode(body.approvalToken, 32);
        decode(body.approvalRequestID, 16); decode(body.deviceSignature, 64);
      }
      if (request.signal.aborted) throw new HttpFailure(400, 'request_aborted');
      let result;
      try { result = await operations[operation]({ method: 'POST', ...body }); }
      catch (error) {
        return error instanceof ProtocolError && denied.has(error.code)
          ? failure(403, 'activation_rejected') : failure(503, 'temporarily_unavailable');
      }
      // Copy and validate only the known public result. Never stringify a dependency
      // object or expose its error, token, email or extra properties.
      try {
        if (operation === 'begin') {
          const output = snapshot(result, ['ok', 'challenge']);
          const challenge = snapshot(output.challenge, challengeFields);
          validateChallenge(challenge);
          if (output.ok !== true || challenge.entitlementID !== entitlementID
            || challenge.devicePublicKey !== device.publicKey || challenge.deviceKeyHash !== device.hash) throw invalid();
          return reply(200, { ok: true, challenge });
        }
        const output = snapshot(result, ['ok', 'code', 'receipt']);
        if (output.ok !== true || !['issued', 'already_issued'].includes(output.code)
          || parseReceipt(output.receipt).fields.entitlementID !== entitlementID) throw invalid();
        return reply(200, { ok: true, code: output.code, receipt: output.receipt });
      } catch { return failure(503, 'temporarily_unavailable'); }
    } catch (error) {
      if (error instanceof HttpFailure) return failure(error.status, error.code, head);
      if (error instanceof ProtocolError) return failure(400, 'invalid_request', head);
      return failure(503, 'temporarily_unavailable', head);
    }
  };
}
