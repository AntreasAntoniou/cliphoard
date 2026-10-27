// Disabled host seam: imports only explicitly supplied trusted in-memory material.
// No secret acquisition, generation, export, persistence, IO or shipping caller.
// Clearing owned copies is best effort; JS strings and crypto internals cannot be
// physically zeroized here. Trusted realm intrinsics/Proxy callbacks are assumed.
import { base64url, decode, canonicalDevice, signReceipt } from './protocol.mjs';
import { BOOTSTRAP, parseBootstrap } from './bootstrap-protocol.mjs';
import { createDeviceBootstrapSealer } from './bootstrap-custody.mjs';

const encoder = new TextEncoder();
const curve = Object.freeze({ name: 'ECDSA', namedCurve: 'P-256' });
const signatureAlgorithm = Object.freeze({ name: 'ECDSA', hash: 'SHA-256' });
const receiptFields = ['issuerKeyID', 'entitlementID', 'deviceKeyHash', 'receiptID', 'issuedAt'];
class HostKeyConsumerError extends Error {
  constructor(code) { super(code); this.name = 'HostKeyConsumerError'; this.code = code; }
}
const fail = code => { throw new HostKeyConsumerError(code); };
const need = condition => { if (!condition) fail('host_keys_configuration'); };
const unavailable = async () => fail('host_keys_disabled');
const disabled = Object.freeze({
  bootstrapSigner: Object.freeze({ sign: unavailable }),
  receiptSigner: Object.freeze({ sign: unavailable }),
  setupSealer: Object.freeze({ seal: unavailable, open: unavailable }),
});

function ownData(value, names) {
  need(value !== null && typeof value === 'object'
    && [Object.prototype, null].includes(Object.getPrototypeOf(value)));
  const descriptors = Object.getOwnPropertyDescriptors(value);
  need(Reflect.ownKeys(descriptors).length === names.length
    && names.every(name => descriptors[name] && Object.hasOwn(descriptors[name], 'value')));
  return Object.fromEntries(names.map(name => [name, descriptors[name].value]));
}
function identifier(value) {
  need(typeof value === 'string' && /^[a-z0-9][a-z0-9_-]{0,31}$/.test(value));
  return value;
}
function exactBytes(value, minimum, maximum = minimum) {
  need(value instanceof Uint8Array && Object.getPrototypeOf(value) === Uint8Array.prototype);
  // Read native internal slots, never caller-defined length/buffer properties.
  const prototype = Object.getPrototypeOf(Uint8Array.prototype);
  const length = Object.getOwnPropertyDescriptor(prototype, 'length').get.call(value);
  const buffer = Object.getOwnPropertyDescriptor(prototype, 'buffer').get.call(value);
  need(buffer instanceof ArrayBuffer && length >= minimum && length <= maximum);
  const descriptors = Object.getOwnPropertyDescriptors(value);
  need(Reflect.ownKeys(descriptors).length === length);
  for (let index = 0; index < length; index++)
    need(descriptors[index] && Object.hasOwn(descriptors[index], 'value'));
  return new Uint8Array(value);
}
function signingUsage(value) {
  need(Array.isArray(value) && Object.getPrototypeOf(value) === Array.prototype);
  const descriptors = Object.getOwnPropertyDescriptors(value);
  need(Reflect.ownKeys(descriptors).length === 2 && descriptors.length?.value === 1
    && descriptors[0] && Object.hasOwn(descriptors[0], 'value') && descriptors[0].value === 'sign');
  return ['sign'];
}
function captureSigner(value, role) {
  const signer = ownData(value, ['role', 'keyID', 'publicKey', 'privateJWK']);
  need(signer.role === role); identifier(signer.keyID);
  const jwk = ownData(signer.privateJWK, ['kty', 'crv', 'x', 'y', 'd', 'ext', 'key_ops']);
  need(jwk.kty === 'EC' && jwk.crv === 'P-256' && jwk.ext === false);
  jwk.key_ops = signingUsage(jwk.key_ops);
  let x, y, scalar, pin;
  try {
    x = decode(jwk.x, 32); y = decode(jwk.y, 32); scalar = decode(jwk.d, 32);
    pin = decode(signer.publicKey, 65);
    need(pin[0] === 4 && base64url(new Uint8Array([4, ...x, ...y])) === signer.publicKey);
  } finally {
    x?.fill(0); y?.fill(0); scalar?.fill(0); pin?.fill(0);
  }
  return { keyID: signer.keyID, publicKey: signer.publicKey, privateJWK: jwk };
}
function captureMaterial(value) {
  const material = ownData(value, ['bootstrapSigner', 'receiptSigner', 'setupSealer']);
  const bootstrap = captureSigner(material.bootstrapSigner, 'clipb1-bootstrap-signer');
  const receipt = captureSigner(material.receiptSigner, 'clipd1-receipt-signer');
  const sealer = ownData(material.setupSealer, ['role', 'keyID', 'keyBytes']);
  need(sealer.role === 'clipbs1-setup-sealer'); identifier(sealer.keyID);
  need(new Set([bootstrap.keyID, receipt.keyID, sealer.keyID]).size === 3
    && bootstrap.publicKey !== receipt.publicKey);
  return { bootstrap, receipt, sealer: { keyID: sealer.keyID, keyBytes: exactBytes(sealer.keyBytes, 32) } };
}
async function importSigner(captured, role) {
  const verifier = await canonicalDevice(captured.publicKey);
  const key = await crypto.subtle.importKey('jwk', captured.privateJWK, curve, false, ['sign']);
  const probe = encoder.encode(`cliphoard.host-key-reconstruction\n1\n${role}\n${captured.keyID}\n${captured.publicKey}`);
  try {
    const signature = await crypto.subtle.sign(signatureAlgorithm, key, probe);
    need(signature.byteLength === 64
      && await crypto.subtle.verify(signatureAlgorithm, verifier.key, signature, probe));
  } finally { probe.fill(0); }
  return key;
}
function bootstrapCapability(key, bootstrapKeyID, bootstrapPublicKey, receiptIssuerKeyID) {
  return Object.freeze({ bootstrapKeyID, bootstrapPublicKey, async sign(...args) {
    let bytes;
    try {
      need(args.length === 1);
      bytes = exactBytes(args[0], 1, BOOTSTRAP.maxPayloadBytes);
      // Reuse the existing canonical parser for unsigned payload validation;
      // the dummy signature is never returned or treated as a verified envelope.
      const parsed = parseBootstrap(`${BOOTSTRAP.prefix}${base64url(bytes)}.${base64url(new Uint8Array(64))}`);
      need(parsed.fields.bootstrapKeyID === bootstrapKeyID && parsed.fields.receiptIssuerKeyID === receiptIssuerKeyID);
      const result = new Uint8Array(await crypto.subtle.sign(signatureAlgorithm, key, bytes));
      need(result.length === 64); return result;
    } catch { fail('host_keys_unavailable'); }
    finally { bytes?.fill(0); }
  } });
}
function receiptCapability(key, issuerKeyID, issuerPublicKey) {
  return Object.freeze({ issuerKeyID, issuerPublicKey, async sign(...args) {
    try {
      need(args.length === 1);
      const fields = ownData(args[0], receiptFields);
      need(fields.issuerKeyID === issuerKeyID);
      return await signReceipt(fields, key);
    } catch { fail('host_keys_unavailable'); }
  } });
}
function sealerCapability(key, keyID) {
  const sealer = createDeviceBootstrapSealer({ enabled: true, keyID, key });
  return Object.freeze({ keyID, async seal(...args) {
    try { need(args.length === 2); return await sealer.seal(...args); }
    catch { fail('host_keys_unavailable'); }
  }, async open(...args) {
    try { need(args.length === 2); return await sealer.open(...args); }
    catch { fail('host_keys_unavailable'); }
  } });
}

export async function reconstructHostKeyCapabilities(options = {}) {
  let captured;
  try {
    need(options !== null && typeof options === 'object' && !Array.isArray(options));
    const enabled = Object.getOwnPropertyDescriptor(options, 'enabled');
    if (enabled === undefined) return disabled;
    need(Object.hasOwn(enabled, 'value'));
    if (enabled.value !== true) return disabled;
    const input = ownData(options, ['enabled', 'material']);
    // Capture every field and byte source before the first asynchronous import.
    captured = captureMaterial(input.material);
  } catch { fail('host_keys_configuration'); }
  try {
    const bootstrapKey = await importSigner(captured.bootstrap, 'clipb1-bootstrap-signer');
    const receiptKey = await importSigner(captured.receipt, 'clipd1-receipt-signer');
    const sealerKey = await crypto.subtle.importKey('raw', captured.sealer.keyBytes, { name: 'AES-GCM' }, false, ['encrypt', 'decrypt']);
    return Object.freeze({
      bootstrapSigner: bootstrapCapability(bootstrapKey, captured.bootstrap.keyID, captured.bootstrap.publicKey, captured.receipt.keyID),
      receiptSigner: receiptCapability(receiptKey, captured.receipt.keyID, captured.receipt.publicKey),
      setupSealer: sealerCapability(sealerKey, captured.sealer.keyID),
    });
  } catch { fail('host_keys_unavailable'); }
  finally {
    captured.sealer.keyBytes.fill(0);
    captured.bootstrap.privateJWK.d = ''; captured.receipt.privateJWK.d = '';
  }
}
