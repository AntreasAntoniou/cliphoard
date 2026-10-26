// DISABLED experiment: no imports from shipping workers and no production trust keys.
// Web Crypto only; private keys are supplied in memory by synthetic tests.
const encoder = new TextEncoder();
const decoder = new TextDecoder('utf-8', { fatal: true });
export const PROTOCOL = Object.freeze({
  prefix: 'CLIPD1.', version: 1, algorithm: 'P256-SHA256',
  receiptPurpose: 'cliphoard.device-receipt',
  approvalPurpose: 'cliphoard.device-approval',
  localPurpose: 'cliphoard.device-local-proof',
  maxEnvelopeBytes: 1024, maxPayloadBytes: 512, maxEpoch: 253402300799,
});
const ecdsa = Object.freeze({ name: 'ECDSA', hash: 'SHA-256' });
const curve = Object.freeze({ name: 'ECDSA', namedCurve: 'P-256' });

export class ProtocolError extends Error {
  constructor(code) { super(code); this.name = 'ProtocolError'; this.code = code; }
}
export function need(condition, code = 'malformed') { if (!condition) throw new ProtocolError(code); }
export function exactFields(object, fields) {
  need(object !== null && typeof object === 'object' && !Array.isArray(object));
  const actual = Object.keys(object).sort();
  need(actual.length === fields.length && actual.every((key, i) => key === [...fields].sort()[i]));
}
export function base64url(bytes) {
  return btoa(String.fromCharCode(...new Uint8Array(bytes))).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
}
export function decode(value, exactBytes, maximumBytes = 512) {
  need(typeof value === 'string' && value.length > 0 && value.length <= Math.ceil((exactBytes ?? maximumBytes) * 8 / 6));
  need(/^[A-Za-z0-9_-]+$/.test(value));
  let bytes;
  try {
    bytes = Uint8Array.from(atob(value.replaceAll('-', '+').replaceAll('_', '/') + '='.repeat((4 - value.length % 4) % 4)), c => c.charCodeAt(0));
  } catch { throw new ProtocolError('malformed'); }
  need(bytes.length <= maximumBytes && (exactBytes === undefined || bytes.length === exactBytes) && base64url(bytes) === value);
  return bytes;
}
export function epoch(value) {
  need(Number.isSafeInteger(value) && value > 0 && value <= PROTOCOL.maxEpoch);
  return value;
}
export function randomToken(length) { return base64url(crypto.getRandomValues(new Uint8Array(length))); }
export async function digest(bytes) { return base64url(await crypto.subtle.digest('SHA-256', bytes)); }
export async function tokenDigest(token) { return digest(decode(token, 32)); }

export async function canonicalDevice(publicKey) {
  const raw = decode(publicKey, 65);
  need(raw[0] === 4, 'invalid_device_key');
  try {
    const key = await crypto.subtle.importKey('raw', raw, curve, true, ['verify']);
    need(base64url(await crypto.subtle.exportKey('raw', key)) === publicKey, 'invalid_device_key');
    return { key, publicKey, hash: await digest(raw) };
  } catch { throw new ProtocolError('invalid_device_key'); }
}
function keyID(value) { need(typeof value === 'string' && /^[a-z0-9][a-z0-9_-]{0,31}$/.test(value)); }
export function receiptPayload(fields) {
  exactFields(fields, ['issuerKeyID', 'entitlementID', 'deviceKeyHash', 'receiptID', 'issuedAt']);
  keyID(fields.issuerKeyID);
  decode(fields.entitlementID, 16); decode(fields.deviceKeyHash, 32); decode(fields.receiptID, 16); epoch(fields.issuedAt);
  return encoder.encode([PROTOCOL.receiptPurpose, '1', PROTOCOL.algorithm, fields.issuerKeyID,
    fields.entitlementID, fields.deviceKeyHash, fields.receiptID, String(fields.issuedAt), 'pro', 'perpetual'].join('\n'));
}
export async function signReceipt(fields, privateKey) {
  need(privateKey?.algorithm?.name === 'ECDSA' && privateKey.algorithm.namedCurve === 'P-256', 'invalid_signer');
  const payload = receiptPayload(fields);
  const signature = await crypto.subtle.sign(ecdsa, privateKey, payload);
  need(signature.byteLength === 64, 'invalid_signature');
  return `${PROTOCOL.prefix}${base64url(payload)}.${base64url(signature)}`;
}
export function parseReceipt(envelope) {
  need(typeof envelope === 'string' && envelope.length <= PROTOCOL.maxEnvelopeBytes && envelope.startsWith(PROTOCOL.prefix));
  const parts = envelope.slice(PROTOCOL.prefix.length).split('.');
  need(parts.length === 2);
  const payload = decode(parts[0], undefined, PROTOCOL.maxPayloadBytes);
  const signature = decode(parts[1], 64);
  need(payload.every(byte => byte === 10 || (byte >= 32 && byte <= 126)));
  const lines = decoder.decode(payload).split('\n');
  need(lines.length === 10);
  need(lines[0] === PROTOCOL.receiptPurpose && lines[1] === '1' && lines[2] === PROTOCOL.algorithm
    && lines[8] === 'pro' && lines[9] === 'perpetual', 'unsupported_protocol');
  const fields = { issuerKeyID: lines[3], entitlementID: lines[4], deviceKeyHash: lines[5], receiptID: lines[6], issuedAt: Number(lines[7]) };
  need(String(fields.issuedAt) === lines[7]);
  // Round-trip every byte. No whitespace, duplicate fields, integer aliases or extensions.
  need(base64url(receiptPayload(fields)) === parts[0]);
  return { fields, payload, signature };
}

// Signature inspection alone grants nothing: an offline client MUST also prove possession.
export async function verifyReceiptSignature(envelope, trustedIssuers) {
  const parsed = parseReceipt(envelope);
  need(trustedIssuers instanceof Map && trustedIssuers.has(parsed.fields.issuerKeyID), 'untrusted_issuer');
  const issuer = await canonicalDevice(trustedIssuers.get(parsed.fields.issuerKeyID));
  need(await crypto.subtle.verify(ecdsa, issuer.key, parsed.signature, parsed.payload), 'invalid_signature');
  return parsed;
}
export async function verifyOffline(envelope, device, trustedIssuers) {
  const parsed = await verifyReceiptSignature(envelope, trustedIssuers);
  const local = await canonicalDevice(await device.publicKey());
  need(local.hash === parsed.fields.deviceKeyHash, 'wrong_device');
  const message = encoder.encode([PROTOCOL.localPurpose, '1', await digest(parsed.payload), randomToken(32)].join('\n'));
  const signature = await device.signProof(message);
  need(signature instanceof Uint8Array && signature.length === 64
    && await crypto.subtle.verify(ecdsa, local.key, signature, message), 'invalid_possession');
  return parsed.fields;
}

export function validateChallenge(challenge) {
  exactFields(challenge, ['purpose', 'version', 'algorithm', 'entitlementID', 'devicePublicKey', 'deviceKeyHash', 'challengeID', 'nonce', 'expiresAt']);
  need(challenge.purpose === PROTOCOL.approvalPurpose && challenge.version === 1 && challenge.algorithm === PROTOCOL.algorithm, 'unsupported_protocol');
  decode(challenge.entitlementID, 16); decode(challenge.devicePublicKey, 65); decode(challenge.deviceKeyHash, 32);
  decode(challenge.challengeID, 16); decode(challenge.nonce, 32); epoch(challenge.expiresAt);
}
export function approvalMessage(challenge, approvalTokenHash, approvalRequestID) {
  validateChallenge(challenge); decode(approvalTokenHash, 32); decode(approvalRequestID, 16);
  return encoder.encode([PROTOCOL.approvalPurpose, '1', PROTOCOL.algorithm, challenge.entitlementID,
    challenge.devicePublicKey, challenge.deviceKeyHash, challenge.challengeID, challenge.nonce,
    String(challenge.expiresAt), approvalTokenHash, approvalRequestID].join('\n'));
}
export async function verifyApprovalProof(challenge, approvalTokenHash, approvalRequestID, signature) {
  const device = await canonicalDevice(challenge.devicePublicKey);
  need(device.hash === challenge.deviceKeyHash, 'invalid_device_key');
  const rawSignature = decode(signature, 64);
  return crypto.subtle.verify(ecdsa, device.key, rawSignature, approvalMessage(challenge, approvalTokenHash, approvalRequestID));
}
// The hash inputs have fixed length. This portable comparison avoids an early-exit
// string comparison; JS/JIT timing guarantees are not claimed. HTTP rate limiting remains required.
export function sameTokenHash(a, b) {
  const left = decode(a, 32); const right = decode(b, 32);
  let different = 0;
  for (let i = 0; i < 32; i++) different |= left[i] ^ right[i];
  return different === 0;
}
