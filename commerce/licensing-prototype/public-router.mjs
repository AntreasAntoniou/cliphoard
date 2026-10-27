// Disabled global edge composition. No Worker export, provisioning, registry,
// request logging, environment lookup or production bindings.
import { decode } from './protocol.mjs';
import { HTTP_LIMITS } from './http-adapter.mjs';
import { createDeviceLicenceServerLifecycle } from './server-lifecycle.mjs';

const targets = new WeakMap();
const prefix = '/device-licensing/v1';
const headerName = 'X-Cliphoard-Entitlement';
const responseHeaders = Object.freeze({ 'content-type': 'application/json; charset=utf-8',
  'cache-control': 'no-store', pragma: 'no-cache', 'referrer-policy': 'no-referrer',
  'x-content-type-options': 'nosniff', 'cross-origin-resource-policy': 'same-origin',
  'content-security-policy': "default-src 'none'; frame-ancestors 'none'" });
class RoutingError extends Error {
  constructor(code) { super(code); this.name = 'DeviceLicenceRoutingError'; this.code = code; }
}
const fail = code => { throw new RoutingError(code); };
const need = condition => { if (!condition) fail('routing_configuration'); };
function data(value, names) {
  need(value && typeof value === 'object' && [Object.prototype, null].includes(Object.getPrototypeOf(value)));
  const descriptors = Object.getOwnPropertyDescriptors(value);
  need(Reflect.ownKeys(descriptors).length === names.length
    && names.every(name => descriptors[name] && Object.hasOwn(descriptors[name], 'value')));
  return Object.freeze(Object.fromEntries(names.map(name => [name, descriptors[name].value])));
}
function configuration(options, names) {
  need(options && typeof options === 'object' && !Array.isArray(options));
  const enabled = Object.getOwnPropertyDescriptor(options, 'enabled');
  if (enabled === undefined) return null;
  need(Object.hasOwn(enabled, 'value'));
  return enabled.value === true ? data(options, ['enabled', ...names]) : null;
}
function originPin(value) {
  need(typeof value === 'string');
  const url = new URL(value);
  need(url.protocol === 'https:' && url.origin === value);
  return value;
}
const reply = (status, body, head = false, allow) => new Response(head ? null : JSON.stringify(body), {
  status, headers: { ...responseHeaders, ...(allow ? { allow } : {}) },
});
const failure = (status, code, head = false, allow) => reply(status, { ok: false, code }, head, allow);
const disabledTarget = Object.freeze(Object.fromEntries(['alarm', 'recover', 'refreshAuthority', 'refreshAdmission']
  .map(name => [name, async () => fail('routing_disabled')])));

// Only this factory can create a brand. Request values never become lifecycle
// configuration. The real facade captures every dependency; binding/origin are
// copied independently here before its opaque target is returned.
export function createDeviceLicenceRouteTarget(options = {}) {
  try {
    const supplied = configuration(options, ['lifecycle']);
    if (supplied === null) return disabledTarget;
    const lifecycle = data(supplied.lifecycle, ['enabled', 'storage', 'binding', 'inspectDeviceAuthority', 'issuer',
      'tokenCustody', 'admission', 'mail', 'alarmStorage', 'clocks', 'limits', 'operational', 'http']);
    need(lifecycle.enabled === true);
    const binding = data(lifecycle.binding, ['entitlementID', 'entitlementHandleDigest', 'accountId', 'mode',
      'orderRef', 'sessionId', 'productId', 'priceId', 'currency', 'unitAmount', 'taxBehavior']);
    const http = data(lifecycle.http, ['origin', 'bodyTimeoutMs']);
    decode(binding.entitlementID, 16); const origin = originPin(http.origin);
    const facade = createDeviceLicenceServerLifecycle({ ...lifecycle, binding, http });
    const target = Object.freeze({ alarm: facade.alarm, recover: facade.recover,
      refreshAuthority: facade.refreshAuthority, refreshAdmission: facade.refreshAdmission });
    targets.set(target, Object.freeze({ entitlementID: binding.entitlementID, origin, handle: facade.handle }));
    return target;
  } catch { fail('routing_configuration'); }
}

const disabledRouter = Object.freeze({ handle: async request =>
  failure(404, 'unavailable', request instanceof Request && request.method === 'HEAD') });
export function createDeviceLicencePublicRouter(options = {}) {
  let supplied, origin, lookupTarget, maximum;
  try {
    supplied = configuration(options, ['origin', 'maxConcurrentRequests', 'lookupTarget']);
    if (supplied === null) return disabledRouter;
    origin = originPin(supplied.origin); lookupTarget = supplied.lookupTarget; maximum = supplied.maxConcurrentRequests;
    need(typeof lookupTarget === 'function' && Number.isSafeInteger(maximum) && maximum > 0);
  } catch { fail('routing_configuration'); }
  let pending = 0;
  return Object.freeze({ async handle(request) {
    const head = request instanceof Request && request.method === 'HEAD';
    try {
      if (!(request instanceof Request)) return failure(400, 'invalid_request');
      const url = new URL(request.url);
      if (url.origin !== origin || request.url.includes('?') || request.url.includes('#')) return failure(400, 'invalid_request', head);
      const operation = url.pathname === `${prefix}/begin` ? 'begin'
        : url.pathname === `${prefix}/approve` ? 'approve'
        : url.pathname === `${prefix}/confirmation` ? 'confirmation' : null;
      if (operation === null) return failure(404, 'not_found', head);
      const allow = operation === 'confirmation' ? 'GET, HEAD' : 'POST';
      if (!(operation === 'confirmation' ? ['GET', 'HEAD'].includes(request.method) : request.method === 'POST'))
        return failure(405, 'method_not_allowed', head, allow);
      const requestOrigin = request.headers.get('origin'), site = request.headers.get('sec-fetch-site');
      if ((requestOrigin !== null && requestOrigin !== origin) || (site !== null && !['same-origin', 'none'].includes(site)))
        return failure(403, 'forbidden', head);
      if (operation === 'confirmation') return reply(200, { ok: true, code: 'confirmation_required' }, head);
      // WHATWG Headers combines duplicate values with a comma, which canonical
      // base64url rejects. Raw ingress normalization remains the host's obligation.
      const entitlementID = request.headers.get(headerName);
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
        // A trusted lookup-only capability: it must never provision a scope for
        // this locator. The router passes no body or authority facts to it.
        const target = await lookupTarget(entitlementID), bound = targets.get(target);
        if (!bound || bound.entitlementID !== entitlementID || bound.origin !== origin)
          return failure(503, 'temporarily_unavailable');
        if (request.signal.aborted) return failure(400, 'request_aborted');
        // The branded facade validates the original bounded body and exact output
        // shapes. No body cloning/re-serialization and no request-selected service.
        // Await is essential: cancellation cannot free a slot for unsettled work.
        return await bound.handle(request);
      } catch { return failure(503, 'temporarily_unavailable'); }
      finally { pending--; }
    } catch { return failure(503, 'temporarily_unavailable', head); }
  } });
}
