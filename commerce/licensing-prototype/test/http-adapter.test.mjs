import test from 'node:test';
import assert from 'node:assert/strict';
import { createActivationHttpHandler, HTTP_LIMITS } from '../http-adapter.mjs';
import { syntheticKey } from './fixtures.mjs';
import { PROTOCOL, ProtocolError, randomToken, canonicalDevice, signReceipt } from '../protocol.mjs';

const origin = 'https://licensing.example.invalid';
const base = '/device-licensing/v1';
const device = await syntheticKey(), issuer = await syntheticKey();
const entitlementID = randomToken(16), foreignID = randomToken(16);
const deviceHash = (await canonicalDevice(device.publicKey)).hash;
const challenge = Object.freeze({ purpose: PROTOCOL.approvalPurpose, version: 1,
  algorithm: PROTOCOL.algorithm, entitlementID, devicePublicKey: device.publicKey,
  deviceKeyHash: deviceHash, challengeID: randomToken(16), nonce: randomToken(32), expiresAt: 1767323645 });
const receipt = await signReceipt({ issuerKeyID: 'synthetic-http', entitlementID,
  deviceKeyHash: deviceHash, receiptID: randomToken(16), issuedAt: 1767323045 }, issuer.privateKey);
const begin = Object.freeze({ entitlementHandle: randomToken(32), devicePublicKey: device.publicKey, requestID: randomToken(16) });
const approve = Object.freeze({ challengeID: challenge.challengeID, approvalToken: randomToken(32),
  approvalRequestID: randomToken(16), deviceSignature: randomToken(64) });

function fixture(extra = {}) {
  const calls = [];
  const service = {
    async begin(input) { calls.push({ operation: 'begin', receiver: this, input }); return { ok: true, challenge }; },
    async approve(input) { calls.push({ operation: 'approve', receiver: this, input }); return { ok: true, code: 'issued', receipt }; },
    preview() { throw new Error('preview must not touch a ledger'); },
    observeEntitlement() { throw new Error('internal feed must not be exposed'); },
    observeAdmission() { throw new Error('internal feed must not be exposed'); },
    deliverOne() { throw new Error('mail must not be dispatched'); },
    snapshot() { throw new Error('ledger diagnostics must not be exposed'); },
  };
  const handler = createActivationHttpHandler({ enabled: true, service, entitlementID, origin, bodyTimeoutMs: 100, ...extra });
  return { handler, service, calls };
}
function request(path = 'begin', body = begin, options = {}) {
  return new Request(`${origin}${base}/${path}`, { method: 'POST',
    headers: { 'content-type': 'application/json' }, body: JSON.stringify(body), ...options });
}
function streamRequest(stream, options = {}) {
  return request('begin', begin, { body: stream, duplex: 'half', ...options });
}
async function rejection(handler, req, status, code) {
  const response = await handler(req);
  assert.equal(response.status, status);
  assert.deepEqual(await response.json(), { ok: false, code });
  return response;
}

test('default and non-boolean enablement stay off without inspecting body or dependencies', async () => {
  for (const enabled of [undefined, false, 'true', 1, {}]) {
    let calls = 0;
    const handler = createActivationHttpHandler({ enabled, origin: 'invalid', bodyTimeoutMs: 0,
      service: { begin() { calls++; }, approve() { calls++; } } });
    const req = request('begin', { enabled: true, ...begin });
    await rejection(handler, req, 404, 'unavailable');
    assert.equal(req.bodyUsed, false);
    assert.equal(calls, 0);
  }
  await rejection(createActivationHttpHandler(), request(), 404, 'unavailable');
});

test('enabled configuration requires explicit fixed scope, HTTPS origin, methods and bounded parsing deadline', () => {
  const valid = { enabled: true, service: { begin() {}, approve() {} }, entitlementID, origin, bodyTimeoutMs: 100 };
  for (const patch of [{ service: {} }, { entitlementID: foreignID + '=' }, { origin: 'http://licensing.example.invalid' },
    { origin: origin + '/path' }, { origin: 'https://user:password@licensing.example.invalid' },
    { bodyTimeoutMs: undefined }, { bodyTimeoutMs: 0 }, { bodyTimeoutMs: Infinity },
    { bodyTimeoutMs: HTTP_LIMITS.maxBodyTimeoutMs + 1 }]) {
    assert.throws(() => createActivationHttpHandler({ ...valid, ...patch }), { message: 'invalid_adapter_configuration' });
  }
});

test('begin and approval dispatch only fixed methods to the captured scoped service', async () => {
  const f = fixture();
  f.service.begin = () => { throw new Error('later replacement must not change the captured capability'); };
  const first = await f.handler(request());
  assert.equal(first.status, 200);
  assert.deepEqual(await first.json(), { ok: true, challenge });
  const second = await f.handler(request('approve', approve));
  assert.equal(second.status, 200);
  assert.deepEqual(await second.json(), { ok: true, code: 'issued', receipt });
  assert.deepEqual(f.calls.map(({ operation, input }) => ({ operation, input })), [
    { operation: 'begin', input: { method: 'POST', ...begin } },
    { operation: 'approve', input: { method: 'POST', ...approve } },
  ]);
  assert.ok(f.calls.every(call => call.receiver === f.service));
});

test('GET and HEAD confirmation are generic and dispatch no service capability', async () => {
  const f = fixture();
  for (const method of ['GET', 'HEAD']) {
    const response = await f.handler(new Request(`${origin}${base}/confirmation`, { method }));
    assert.equal(response.status, 200);
    if (method === 'HEAD') assert.equal(await response.text(), '');
    else assert.deepEqual(await response.json(), { ok: true, code: 'confirmation_required' });
  }
  assert.equal(f.calls.length, 0);
});

test('GET, HEAD and OPTIONS never call a mutation; Allow is a fixed route value', async () => {
  const f = fixture();
  for (const path of ['begin', 'approve']) for (const method of ['GET', 'HEAD', 'OPTIONS', 'PUT', 'DELETE']) {
    const response = await f.handler(new Request(`${origin}${base}/${path}`, { method }));
    assert.equal(response.status, 405);
    assert.equal(response.headers.get('allow'), 'POST');
    if (method === 'HEAD') assert.equal(await response.text(), '');
  }
  const previewPost = await f.handler(request('confirmation'));
  assert.equal(previewPost.status, 405);
  assert.equal(previewPost.headers.get('allow'), 'GET, HEAD');
  assert.equal(f.calls.length, 0);
});

test('exact paths exclude internal feeds, diagnostics, suffixes and encoded route names', async () => {
  const f = fixture();
  for (const path of ['observeEntitlement', 'observeAdmission', 'deliverOne', 'snapshot', 'begin/', '%62egin', 'Begin', 'begin/extra'])
    await rejection(f.handler, request(path), 404, 'not_found');
  assert.equal(f.calls.length, 0);
});

test('query, fragment and different URL origin are rejected before body use', async () => {
  const f = fixture();
  for (const url of [`${origin}${base}/begin?approvalToken=synthetic-secret`, `${origin}${base}/begin?`,
    `${origin}${base}/begin#synthetic-secret`, `https://foreign.example.invalid${base}/begin`]) {
    const req = new Request(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(begin) });
    await rejection(f.handler, req, 400, 'invalid_request');
    assert.equal(req.bodyUsed, false);
  }
  assert.equal(f.calls.length, 0);
});

test('origin checks do not reflect arbitrary origins or offer CORS permission', async () => {
  const f = fixture();
  for (const headers of [{ origin: 'https://foreign.example.invalid' }, { origin: 'null' },
    { 'sec-fetch-site': 'cross-site' }, { 'sec-fetch-site': 'same-site' }]) {
    const response = await rejection(f.handler, request('begin', begin, {
      headers: { 'content-type': 'application/json', ...headers } }), 403, 'forbidden');
    assert.equal(response.headers.get('access-control-allow-origin'), null);
  }
  const sameOrigin = await f.handler(request('begin', begin, { headers: { 'content-type': 'application/json', origin, 'sec-fetch-site': 'same-origin' } }));
  assert.equal(sameOrigin.status, 200);
  assert.equal(f.calls.length, 1);
});

test('content type and content encoding are narrow; no form or compressed body reaches service', async () => {
  const f = fixture();
  for (const headers of [{}, { 'content-type': 'text/plain' }, { 'content-type': 'application/x-www-form-urlencoded' },
    { 'content-type': 'application/json; charset=iso-8859-1' }, { 'content-type': 'application/json', 'content-encoding': 'gzip' }])
    await rejection(f.handler, request('begin', begin, { headers }), 415, 'unsupported_media_type');
  assert.equal(f.calls.length, 0);
  assert.equal((await f.handler(request('begin', begin, { headers: { 'content-type': 'application/json; charset=UTF-8' } }))).status, 200);
});

test('flat exact schema rejects caller authority, method injection and nested or non-string data', async () => {
  const f = fixture();
  for (const body of [{ ...begin, entitlementID: foreignID }, { ...begin, method: 'GET' },
    { ...begin, email: 'synthetic-secret@example.invalid' }, { ...begin, eligible: true },
    { ...begin, requestID: null }, { ...begin, requestID: {} }, [], null, { requestID: begin.requestID },
    { ...approve, proofVerified: true }]) await rejection(f.handler, request('begin', body), 400, 'invalid_request');
  assert.equal(f.calls.length, 0);
});

test('duplicate JSON keys, including escaped aliases and overwritten nested values, are rejected', async () => {
  const f = fixture();
  for (const raw of [JSON.stringify(begin).replace('{', `{"requestID":"${begin.requestID}",`),
    JSON.stringify(begin).replace('{', `{"request\\u0049D":"${begin.requestID}",`),
    JSON.stringify(begin).replace('{', '{"requestID":{"hidden":"synthetic-secret"},')])
    await rejection(f.handler, request('begin', begin, { body: raw }), 400, 'invalid_request');
  assert.equal(f.calls.length, 0);
});

test('invalid JSON, invalid UTF-8, BOM and malformed protocol values have zero service calls', async () => {
  const f = fixture();
  for (const body of ['', '{', JSON.stringify(begin) + ' trailing', '\ufeff' + JSON.stringify(begin),
    new Uint8Array([0xc3, 0x28]), JSON.stringify({ ...begin, entitlementHandle: begin.entitlementHandle + '=' }),
    JSON.stringify({ ...begin, devicePublicKey: randomToken(65) })])
    await rejection(f.handler, request('begin', begin, { body }), 400, 'invalid_request');
  await rejection(f.handler, request('approve', { ...approve, deviceSignature: 'short' }), 400, 'invalid_request');
  assert.equal(f.calls.length, 0);
});

test('body size is enforced without Content-Length and when its value lies', async () => {
  const f = fixture();
  for (const headers of [{ 'content-type': 'application/json' }, { 'content-type': 'application/json', 'content-length': '1' }]) {
    let cancelled = 0;
    const stream = new ReadableStream({ start(c) { c.enqueue(new Uint8Array(HTTP_LIMITS.maxBodyBytes + 1)); }, cancel() { cancelled++; } });
    const req = streamRequest(stream, { headers });
    await rejection(f.handler, req, 413, 'body_too_large');
    assert.equal(cancelled, 1);
    assert.equal(req.body.locked, false);
  }
  assert.equal(f.calls.length, 0);
});

test('accumulated streamed chunks are capped before parsing and cancelled on overflow', async () => {
  const f = fixture();
  let cancelled = 0;
  const stream = new ReadableStream({ start(c) {
    c.enqueue(new Uint8Array(HTTP_LIMITS.maxBodyBytes)); c.enqueue(new Uint8Array(1));
  }, cancel() { cancelled++; } });
  await rejection(f.handler, streamRequest(stream), 413, 'body_too_large');
  assert.equal(cancelled, 1);
  assert.equal(f.calls.length, 0);
});

test('Content-Length is validated but never trusted over actual bytes', async () => {
  const f = fixture();
  for (const value of ['-1', '1, 1', 'abc', '01', '9007199254740992'])
    await rejection(f.handler, request('begin', begin, { headers: { 'content-type': 'application/json', 'content-length': value } }), 400, 'invalid_request');
  await rejection(f.handler, request('begin', begin, { headers: { 'content-type': 'application/json', 'content-length': String(HTTP_LIMITS.maxBodyBytes + 1) } }), 413, 'body_too_large');
  await rejection(f.handler, request('begin', begin, { headers: { 'content-type': 'application/json', 'content-length': '1' } }), 400, 'invalid_request');
  assert.equal(f.calls.length, 0);
});

test('stalled body has a request-local deadline even if cancellation never settles', { timeout: 1500 }, async () => {
  const f = fixture({ bodyTimeoutMs: 20 });
  let cancelled = 0;
  const req = streamRequest(new ReadableStream({ cancel() { cancelled++; return new Promise(() => {}); } }));
  const start = performance.now();
  await rejection(f.handler, req, 408, 'request_timeout');
  assert.ok(performance.now() - start < 750);
  assert.equal(cancelled, 1);
  assert.equal(req.body.locked, false);
  assert.equal(f.calls.length, 0);
});

test('abort while reading cancels/releases the stream without waiting for cancellation', { timeout: 1500 }, async () => {
  const f = fixture({ bodyTimeoutMs: 1000 }), controller = new AbortController();
  let cancelled = 0;
  const req = streamRequest(new ReadableStream({ cancel() { cancelled++; return new Promise(() => {}); } }), { signal: controller.signal });
  const pending = f.handler(req);
  controller.abort();
  await rejection(() => pending, req, 400, 'request_aborted');
  assert.equal(cancelled, 1);
  assert.equal(req.body.locked, false);
  assert.equal(f.calls.length, 0);
});

test('already aborted input and stream errors never dispatch or expose their error text', async () => {
  const f = fixture(), controller = new AbortController(); controller.abort();
  await rejection(f.handler, request('begin', begin, { signal: controller.signal }), 400, 'request_aborted');
  await rejection(f.handler, streamRequest(new ReadableStream({ start(c) { c.error(new Error('synthetic-private-stream-data')); } })), 400, 'invalid_request');
  assert.equal(f.calls.length, 0);
});

test('empty or non-byte stream chunks cannot create an unbounded read loop', { timeout: 1500 }, async () => {
  const f = fixture();
  for (const chunk of [new Uint8Array(0), 'synthetic-private-data']) {
    const req = streamRequest(new ReadableStream({ pull(c) { c.enqueue(chunk); } }));
    await rejection(f.handler, req, 400, 'invalid_request');
    assert.equal(req.body.locked, false);
  }
  assert.equal(f.calls.length, 0);
});

test('owned parsing timers and abort listeners are removed after success, rejection and timeout', { timeout: 1500 }, async () => {
  const actualSet = globalThis.setTimeout, actualClear = globalThis.clearTimeout;
  const activeTimers = new Set();
  globalThis.setTimeout = (...args) => { const timer = actualSet(...args); activeTimers.add(timer); return timer; };
  globalThis.clearTimeout = timer => { activeTimers.delete(timer); return actualClear(timer); };
  try {
    const f = fixture({ bodyTimeoutMs: 20 });
    for (const [req, status] of [[request(), 200], [request('begin', begin, { body: '{' }), 400],
      [streamRequest(new ReadableStream({ start(c) { c.error(new Error('synthetic stream error')); } })), 400],
      [streamRequest(new ReadableStream()), 408]]) {
      let added = 0, removed = 0;
      const signal = req.signal, add = signal.addEventListener.bind(signal), remove = signal.removeEventListener.bind(signal);
      signal.addEventListener = (...args) => { if (args[0] === 'abort') added++; return add(...args); };
      signal.removeEventListener = (...args) => { if (args[0] === 'abort') removed++; return remove(...args); };
      assert.equal((await f.handler(req)).status, status);
      assert.equal(added, 1);
      assert.equal(removed, added);
      assert.equal(activeTimers.size, 0);
    }
  } finally {
    globalThis.setTimeout = actualSet; globalThis.clearTimeout = actualClear;
    for (const timer of activeTimers) actualClear(timer);
  }
});

test('an exactly capped valid body and single-byte chunks are accepted', async () => {
  const f = fixture({ bodyTimeoutMs: 1000 });
  const raw = JSON.stringify(begin).padEnd(HTTP_LIMITS.maxBodyBytes, ' ');
  const bytes = new TextEncoder().encode(raw);
  const req = streamRequest(new ReadableStream({ start(c) { for (const byte of bytes) c.enqueue(new Uint8Array([byte])); c.close(); } }));
  assert.equal((await f.handler(req)).status, 200);
  assert.equal(f.calls.length, 1);
  assert.equal(req.body.locked, false);
});

test('dependency throws are fixed responses even with secret-bearing messages and properties', async () => {
  for (const error of [new Error('synthetic-private-issuer-or-token'),
    Object.assign(new Error('synthetic-private-object'), { token: begin.entitlementHandle, code: 'synthetic-private-code' }),
    new ProtocolError('synthetic-private-code')]) {
    const f = fixture({ service: { begin() { throw error; }, approve() { throw error; } } });
    await rejection(f.handler, request(), 503, 'temporarily_unavailable');
    await rejection(f.handler, request('approve', approve), 503, 'temporarily_unavailable');
  }
});

test('known proof, eligibility and idempotency failures share a generic denial', async () => {
  for (const code of ['unknown_challenge', 'approval_rejected', 'entitlement_ineligible', 'challenge_expired',
    'held_for_review', 'idempotency_conflict', 'challenge_consumed', 'approval_in_progress']) {
    const f = fixture({ service: { begin() { throw new ProtocolError(code); }, approve() { throw new ProtocolError(code); } } });
    await rejection(f.handler, request('approve', approve), 403, 'activation_rejected');
  }
});

test('arbitrary dependency output and foreign-scope challenges or receipts never leave the adapter', async () => {
  const foreignReceipt = await signReceipt({ issuerKeyID: 'synthetic-http', entitlementID: foreignID,
    deviceKeyHash: deviceHash, receiptID: randomToken(16), issuedAt: 1767323045 }, issuer.privateKey);
  for (const result of [{ ok: true, challenge, token: 'synthetic-secret' },
    { ok: true, challenge: { ...challenge, email: 'synthetic-secret@example.invalid' } },
    { ok: true, challenge: { ...challenge, entitlementID: foreignID } },
    { ok: true, challenge: { ...challenge, deviceKeyHash: randomToken(32) } }]) {
    const f = fixture({ service: { begin: async () => result, approve: async () => result } });
    await rejection(f.handler, request(), 503, 'temporarily_unavailable');
  }
  for (const result of [{ ok: true, code: 'issued', receipt, token: 'synthetic-secret' },
    { ok: true, code: 'issued', receipt: foreignReceipt }, { ok: true, code: 'issued', receipt: 'synthetic-secret' },
    { ok: true, code: 'ready', receipt }]) {
    const f = fixture({ service: { begin: async () => result, approve: async () => result } });
    await rejection(f.handler, request('approve', approve), 503, 'temporarily_unavailable');
  }
});

test('existing committed receipt is returned unchanged with already_issued', async () => {
  const f = fixture({ service: { begin() {}, approve: async () => ({ ok: true, code: 'already_issued', receipt }) } });
  const response = await f.handler(request('approve', approve));
  assert.deepEqual(await response.json(), { ok: true, code: 'already_issued', receipt });
});

test('body deadline does not invent cancellation or rollback of an already-dispatched approval', async () => {
  let finish;
  const pending = new Promise(resolve => { finish = resolve; });
  const f = fixture({ bodyTimeoutMs: 20, service: { begin() {}, approve: () => pending } });
  const controller = new AbortController();
  const responsePromise = f.handler(request('approve', approve, { signal: controller.signal }));
  await new Promise(resolve => setTimeout(resolve, 40));
  controller.abort();
  finish({ ok: true, code: 'issued', receipt });
  assert.equal((await responsePromise).status, 200);
});

test('all responses carry conservative fixed headers and never CORS credentials or Set-Cookie', async () => {
  const f = fixture();
  const responses = [await f.handler(request()), await f.handler(request('unknown')),
    await createActivationHttpHandler()(request()),
    await f.handler(new Request(`${origin}${base}/confirmation`, { method: 'HEAD' }))];
  for (const response of responses) {
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.equal(response.headers.get('referrer-policy'), 'no-referrer');
    assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
    assert.equal(response.headers.get('cross-origin-resource-policy'), 'same-origin');
    assert.equal(response.headers.get('access-control-allow-origin'), null);
    assert.equal(response.headers.get('access-control-allow-credentials'), null);
    assert.equal(response.headers.get('set-cookie'), null);
  }
});
