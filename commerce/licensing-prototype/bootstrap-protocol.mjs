// Disabled bootstrap format and trusted signer adapter. No public issuance route,
// custody, purchaser authentication, endpoint discovery or entitlement activation.
import { PROTOCOL, base64url, decode, epoch, canonicalDevice } from './protocol.mjs';

export const BOOTSTRAP = Object.freeze({ prefix: 'CLIPB1.', purpose: 'cliphoard.device-bootstrap',
  version: 1, algorithm: 'P256-SHA256', maxEnvelopeBytes: 1024, maxPayloadBytes: 512 });
const encoder = new TextEncoder(), decoder = new TextDecoder('utf-8', { fatal: true });
const fields = ['bootstrapKeyID', 'profileID', 'receiptIssuerKeyID', 'entitlementID', 'activationHandle', 'issuedAt'];
const purchaseFields = fields.filter(name => name !== 'bootstrapKeyID');
const algorithm = Object.freeze({ name: 'ECDSA', hash: 'SHA-256' });

class BootstrapError extends Error {
  constructor(code) { super(code); this.name = 'DeviceBootstrapError'; this.code = code; }
}
const fail = (code = 'bootstrap_invalid') => { throw new BootstrapError(code); };
const need = condition => { if (!condition) fail(); };
function ownData(value, names) {
  need(value && typeof value === 'object' && [Object.prototype, null].includes(Object.getPrototypeOf(value)));
  const descriptors = Object.getOwnPropertyDescriptors(value);
  need(Reflect.ownKeys(descriptors).length === names.length
    && names.every(name => descriptors[name] && Object.hasOwn(descriptors[name], 'value')));
  return Object.freeze(Object.fromEntries(names.map(name => [name, descriptors[name].value])));
}
function keyID(value) { need(typeof value === 'string' && /^[a-z0-9][a-z0-9_-]{0,31}$/.test(value)); }
function publicKey(value) { const bytes = decode(value, 65); need(bytes[0] === 4); }
function capturedIDs(value) {
  need(Array.isArray(value) && Object.getPrototypeOf(value) === Array.prototype);
  const descriptors = Object.getOwnPropertyDescriptors(value), length = descriptors.length.value;
  need(length > 0 && Reflect.ownKeys(descriptors).length === length + 1);
  const values = [];
  for (let index = 0; index < length; index++) {
    const descriptor = descriptors[index]; need(descriptor && Object.hasOwn(descriptor, 'value'));
    keyID(descriptor.value); values.push(descriptor.value);
  }
  need(new Set(values).size === values.length);
  return Object.freeze(values);
}

export function bootstrapPayload(value) {
  try {
    const data = ownData(value, fields);
    keyID(data.bootstrapKeyID); keyID(data.profileID); keyID(data.receiptIssuerKeyID);
    decode(data.entitlementID, 16); decode(data.activationHandle, 32); epoch(data.issuedAt);
    const bytes = encoder.encode([BOOTSTRAP.purpose, '1', BOOTSTRAP.algorithm, data.bootstrapKeyID,
      data.profileID, data.receiptIssuerKeyID, data.entitlementID, data.activationHandle, String(data.issuedAt), 'pro'].join('\n'));
    need(bytes.length <= BOOTSTRAP.maxPayloadBytes);
    return bytes;
  } catch { fail(); }
}

export function parseBootstrap(envelope) {
  try {
    need(typeof envelope === 'string' && encoder.encode(envelope).length <= BOOTSTRAP.maxEnvelopeBytes
      && envelope.startsWith(BOOTSTRAP.prefix));
    const parts = envelope.slice(BOOTSTRAP.prefix.length).split('.'); need(parts.length === 2);
    const payload = decode(parts[0], undefined, BOOTSTRAP.maxPayloadBytes), signature = decode(parts[1], 64);
    need(payload.every(byte => byte === 10 || (byte >= 32 && byte <= 126)));
    const lines = decoder.decode(payload).split('\n');
    need(lines.length === 10 && lines[0] === BOOTSTRAP.purpose && lines[1] === '1'
      && lines[2] === BOOTSTRAP.algorithm && lines[9] === 'pro');
    const data = Object.freeze({ bootstrapKeyID: lines[3], profileID: lines[4], receiptIssuerKeyID: lines[5],
      entitlementID: lines[6], activationHandle: lines[7], issuedAt: Number(lines[8]) });
    need(String(data.issuedAt) === lines[8] && data.issuedAt <= PROTOCOL.maxEpoch);
    need(base64url(bootstrapPayload(data)) === parts[0]);
    return Object.freeze({ fields: data, payload, signature });
  } catch { fail(); }
}

// Trust comes exclusively from the caller's independently configured profile.
// A verified descriptor carries a handle; it is neither a receipt nor payment proof.
export async function verifyBootstrap(envelope, trust) {
  try {
    const pins = ownData(trust, ['expectedProfileID', 'bootstrapKeyID', 'bootstrapPublicKey', 'receiptIssuerKeyIDs']);
    keyID(pins.expectedProfileID); keyID(pins.bootstrapKeyID); publicKey(pins.bootstrapPublicKey);
    const permitted = capturedIDs(pins.receiptIssuerKeyIDs), parsed = parseBootstrap(envelope);
    need(parsed.fields.profileID === pins.expectedProfileID && parsed.fields.bootstrapKeyID === pins.bootstrapKeyID
      && permitted.includes(parsed.fields.receiptIssuerKeyID));
    const issuer = await canonicalDevice(pins.bootstrapPublicKey);
    need(await crypto.subtle.verify(algorithm, issuer.key, parsed.signature, parsed.payload));
    return parsed.fields;
  } catch { fail(); }
}

const disabled = Object.freeze({ issue: async () => fail('bootstrap_disabled') });
export function createDeviceBootstrapIssuer(options = {}) {
  let payload, signer;
  try {
    need(options && typeof options === 'object' && !Array.isArray(options));
    const enabled = Object.getOwnPropertyDescriptor(options, 'enabled');
    if (enabled === undefined) return disabled;
    need(Object.hasOwn(enabled, 'value'));
    if (enabled.value !== true) return disabled;
    const supplied = ownData(options, ['enabled', 'fields', 'signer']);
    const purchase = ownData(supplied.fields, purchaseFields);
    signer = ownData(supplied.signer, ['bootstrapKeyID', 'bootstrapPublicKey', 'sign']);
    keyID(signer.bootstrapKeyID); publicKey(signer.bootstrapPublicKey); need(typeof signer.sign === 'function');
    payload = bootstrapPayload({ bootstrapKeyID: signer.bootstrapKeyID, ...purchase });
  } catch { fail('bootstrap_configuration'); }
  return Object.freeze({ async issue(...args) {
    if (args.length !== 0) fail('bootstrap_rejected');
    try {
      const key = await canonicalDevice(signer.bootstrapPublicKey);
      // The signer receives a copy and cannot replace the captured signed message.
      const returned = await signer.sign(payload.slice());
      need(returned instanceof Uint8Array && returned.length === 64);
      const signature = new Uint8Array(returned);
      need(await crypto.subtle.verify(algorithm, key.key, signature, payload));
      const envelope = `${BOOTSTRAP.prefix}${base64url(payload)}.${base64url(signature)}`;
      parseBootstrap(envelope);
      return envelope;
    } catch { fail('bootstrap_unavailable'); }
  } });
}
