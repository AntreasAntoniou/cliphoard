// Disabled lookup-only namespace edge. No default Worker, namespace construction,
// provisioning endpoint, request log, credentials or production configuration.
import { decode } from './protocol.mjs';
import { HTTP_LIMITS } from './http-adapter.mjs';

class EdgeError extends Error {
  constructor(code) { super(code); this.name = 'DeviceBootstrapDirectoryEdgeError'; this.code = code; }
}
const fail = code => { throw new EdgeError(code); };
const need = (condition, code = 'directory_edge_configuration') => { if (!condition) fail(code); };
function data(value, names, code) {
  need(value && typeof value === 'object' && [Object.prototype, null].includes(Object.getPrototypeOf(value)), code);
  const descriptors = Object.getOwnPropertyDescriptors(value);
  need(Reflect.ownKeys(descriptors).length === names.length
    && names.every(name => descriptors[name] && Object.hasOwn(descriptors[name], 'value')), code);
  return Object.freeze(Object.fromEntries(names.map(name => [name, descriptors[name].value])));
}
const responseHeaders = Object.freeze({ 'content-type': 'application/json; charset=utf-8',
  'cache-control': 'no-store', pragma: 'no-cache', 'referrer-policy': 'no-referrer',
  'x-content-type-options': 'nosniff', 'cross-origin-resource-policy': 'same-origin',
  'content-security-policy': "default-src 'none'; frame-ancestors 'none'" });
const reply = (status, body, head = false, allow) => new Response(head ? null : JSON.stringify(body), {
  status, headers: { ...responseHeaders, ...(allow ? { allow } : {}) },
});
const failure = (status, code, head = false, allow) => reply(status, { ok: false, code }, head, allow);
const disabled = Object.freeze({ handle: async request => failure(404, 'unavailable', request instanceof Request && request.method === 'HEAD') });

// Capture primitive acknowledgement data before releasing the RPC result.
// Cloudflare adds Symbol.dispose even to plain by-value object results.
export function captureDeviceBootstrapDirectoryRPCAcknowledgement(value) {
  if (value === null) return null;
  let dispose, result, invalid = false;
  try {
    need(value && typeof value === 'object'
      && [Object.prototype, null].includes(Object.getPrototypeOf(value)), 'directory_rpc_unavailable');
    const descriptors = Object.getOwnPropertyDescriptors(value);
    const cleanup = descriptors[Symbol.dispose];
    if (cleanup !== undefined) {
      need(Object.hasOwn(cleanup, 'value') && typeof cleanup.value === 'function', 'directory_rpc_unavailable');
      dispose = cleanup.value;
    }
    const names = ['entitlementID', 'provisioningID', 'bindingDigest'];
    need(Reflect.ownKeys(descriptors).every(key => names.includes(key) || key === Symbol.dispose), 'directory_rpc_unavailable');
    need(names.every(name => descriptors[name] && Object.hasOwn(descriptors[name], 'value')
      && typeof descriptors[name].value === 'string'), 'directory_rpc_unavailable');
    result = Object.freeze(Object.fromEntries(names.map(name => [name, descriptors[name].value])));
    decode(result.entitlementID, 16); decode(result.provisioningID, 16); decode(result.bindingDigest, 32);
  } catch { invalid = true; }
  finally {
    if (dispose) {
      try { Reflect.apply(dispose, value, []); } catch { invalid = true; }
    }
  }
  if (invalid) fail('directory_rpc_unavailable');
  return result;
}

export function createDeviceBootstrapDirectoryEdge(options = {}) {
  let origin, maximum, lookupReady, forward;
  try {
    need(options && typeof options === 'object' && !Array.isArray(options));
    const enabled = Object.getOwnPropertyDescriptor(options, 'enabled');
    if (enabled === undefined) return disabled;
    need(Object.hasOwn(enabled, 'value'));
    if (enabled.value !== true) return disabled;
    const supplied = data(options, ['enabled', 'origin', 'maxConcurrentRequests', 'lookupReady', 'forward']);
    need(typeof supplied.origin === 'string'); const parsed = new URL(supplied.origin);
    need(parsed.protocol === 'https:' && parsed.origin === supplied.origin);
    need(Number.isSafeInteger(supplied.maxConcurrentRequests) && supplied.maxConcurrentRequests > 0
      && typeof supplied.lookupReady === 'function' && typeof supplied.forward === 'function');
    origin = supplied.origin; maximum = supplied.maxConcurrentRequests;
    lookupReady = supplied.lookupReady; forward = supplied.forward;
  } catch { fail('directory_edge_configuration'); }
  let pending = 0;
  return Object.freeze({ async handle(request) {
    const head = request instanceof Request && request.method === 'HEAD';
    try {
      if (!(request instanceof Request)) return failure(400, 'invalid_request');
      const url = new URL(request.url);
      if (url.origin !== origin || request.url.includes('?') || request.url.includes('#')) return failure(400, 'invalid_request', head);
      const operation = url.pathname === '/device-licensing/v1/begin' ? 'begin'
        : url.pathname === '/device-licensing/v1/approve' ? 'approve'
        : url.pathname === '/device-licensing/v1/confirmation' ? 'confirmation' : null;
      if (operation === null) return failure(404, 'not_found', head);
      const allow = operation === 'confirmation' ? 'GET, HEAD' : 'POST';
      if (!(operation === 'confirmation' ? ['GET', 'HEAD'].includes(request.method) : request.method === 'POST'))
        return failure(405, 'method_not_allowed', head, allow);
      const requestOrigin = request.headers.get('origin'), site = request.headers.get('sec-fetch-site');
      if ((requestOrigin !== null && requestOrigin !== origin) || (site !== null && !['same-origin', 'none'].includes(site)))
        return failure(403, 'forbidden', head);
      if (operation === 'confirmation') return reply(200, { ok: true, code: 'confirmation_required' }, head);
      const entitlementID = request.headers.get('X-Cliphoard-Entitlement');
      try { decode(entitlementID, 16); } catch { return failure(400, 'invalid_request'); }
      const type = request.headers.get('content-type') ?? '', encoding = request.headers.get('content-encoding');
      if (!/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(type)
        || (encoding !== null && encoding.toLowerCase() !== 'identity')) return failure(415, 'unsupported_media_type');
      const contentLength = request.headers.get('content-length');
      if (contentLength !== null) {
        if (!/^(0|[1-9][0-9]*)$/.test(contentLength) || !Number.isSafeInteger(Number(contentLength))) return failure(400, 'invalid_request');
        if (Number(contentLength) === 0) return failure(400, 'invalid_request');
        if (Number(contentLength) > HTTP_LIMITS.maxBodyBytes) return failure(413, 'body_too_large');
      }
      if (request.body === null || request.bodyUsed || request.body.locked) return failure(400, 'invalid_request');
      if (request.signal.aborted) return failure(400, 'request_aborted');
      if (pending >= maximum) return failure(503, 'temporarily_unavailable');
      pending++;
      try {
        const record = data(await lookupReady(entitlementID), ['entitlementID', 'provisioningID', 'bindingDigest'], 'directory_edge_unavailable');
        need(record.entitlementID === entitlementID, 'directory_edge_unavailable');
        decode(record.provisioningID, 16); decode(record.bindingDigest, 32);
        if (request.signal.aborted) return failure(400, 'request_aborted');
        // Only a ready directory result reaches the captured namespace adapter.
        // Its target must reconstruct the actual local branded lifecycle, check
        // the persisted entitlement, and apply current authority to this request.
        const response = await forward(record, request);
        need(response instanceof Response, 'directory_edge_unavailable');
        return response;
      } catch { return failure(503, 'temporarily_unavailable'); }
      finally { pending--; }
    } catch { return failure(503, 'temporarily_unavailable', head); }
  } });
}
