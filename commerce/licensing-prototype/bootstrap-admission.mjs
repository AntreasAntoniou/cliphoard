// Opt-in setup-possession admission. This grants neither payment nor Pro/device
// approval. A pinned profile must belong exclusively to this configured realm;
// global uniqueness cannot be established by a local verifier.
import { BOOTSTRAP, verifyBootstrap } from './bootstrap-protocol.mjs';
import { decode } from './protocol.mjs';
const fail = () => { throw new Error('bootstrap_admission_configuration'); };
const need = condition => { if (!condition) fail(); };
function data(value, names) {
  need(value && typeof value === 'object' && [Object.prototype, null].includes(Object.getPrototypeOf(value)));
  const d = Object.getOwnPropertyDescriptors(value);
  need(Reflect.ownKeys(d).length === names.length && names.every(n => d[n] && Object.hasOwn(d[n], 'value')));
  return Object.freeze(Object.fromEntries(names.map(n => [n, d[n].value])));
}
const keyID = value => typeof value === 'string' && /^[a-z0-9][a-z0-9_-]{0,31}$/.test(value);
const disabled = Object.freeze({ authenticate: async () => { throw new Error('bootstrap_admission_disabled'); } });
export function createDeviceBootstrapAdmission(options = {}) {
  let c, trust;
  try {
    need(options && typeof options === 'object');
    const enabled = Object.getOwnPropertyDescriptor(options, 'enabled');
    if (enabled === undefined) return disabled;
    need(Object.hasOwn(enabled, 'value')); if (enabled.value !== true) return disabled;
    c = data(options, ['enabled', 'realm', 'origin', 'trust']);
    need(typeof c.realm === 'string' && /^[a-z0-9][a-z0-9_-]{0,63}$/.test(c.realm));
    need(typeof c.origin === 'string'); const origin = new URL(c.origin);
    need(origin.protocol === 'https:' && origin.origin === c.origin);
    const raw = data(c.trust, ['expectedProfileID', 'bootstrapKeyID', 'bootstrapPublicKey', 'receiptIssuerKeyIDs']);
    need(keyID(raw.expectedProfileID) && keyID(raw.bootstrapKeyID));
    const publicBytes = decode(raw.bootstrapPublicKey, 65); need(publicBytes[0] === 4);
    need(Array.isArray(raw.receiptIssuerKeyIDs) && Object.getPrototypeOf(raw.receiptIssuerKeyIDs) === Array.prototype);
    const d = Object.getOwnPropertyDescriptors(raw.receiptIssuerKeyIDs), n = d.length.value;
    need(n > 0 && n <= 64 && Reflect.ownKeys(d).length === n + 1);
    const ids = [];
    for (let i = 0; i < n; i++) { need(d[i] && Object.hasOwn(d[i], 'value') && keyID(d[i].value)); ids.push(d[i].value); }
    need(new Set(ids).size === ids.length);
    trust = Object.freeze({ ...raw, receiptIssuerKeyIDs: Object.freeze(ids) });
  } catch { fail(); }
  return Object.freeze({ async authenticate(request, entitlementID) {
    const denied = () => Object.freeze({ decision: 'deny', realm: c.realm, entitlementID: '' });
    try {
      decode(entitlementID, 16);
      if (!(request instanceof Request) || request.signal.aborted || request.method !== 'POST') return denied();
      const url = new URL(request.url);
      if (url.origin !== c.origin || request.url.includes('?') || request.url.includes('#')
        || !['/device-licensing/v1/begin', '/device-licensing/v1/approve'].includes(url.pathname)
        || request.headers.get('X-Cliphoard-Entitlement') !== entitlementID
        || request.body === null || request.bodyUsed || request.body.locked) return denied();
      const envelope = request.headers.get('X-Cliphoard-Setup');
      // ASCII and exact parser rules also reject comma-joined duplicate headers.
      // Never trim, normalize or report the handle-bearing value.
      if (typeof envelope !== 'string' || envelope.length > BOOTSTRAP.maxEnvelopeBytes
        || !/^[\x21-\x7e]+$/.test(envelope)) return denied();
      const fields = await verifyBootstrap(envelope, trust);
      if (request.signal.aborted || request.bodyUsed || request.body.locked || fields.entitlementID !== entitlementID) return denied();
      return Object.freeze({ decision: 'allow', realm: c.realm, entitlementID });
    } catch { return denied(); }
  } });
}
