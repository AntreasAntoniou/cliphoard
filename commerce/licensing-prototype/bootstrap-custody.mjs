// Disabled cryptographic adapter. No key generation/import/export, credential or
// environment access. The host must provide and recover a separate custody key.
import { base64url, decode } from './protocol.mjs';

const encoder = new TextEncoder(), decoder = new TextDecoder('utf-8', { fatal: true });
const prefix = 'CLIPBS1', maximum = 2048;
class CustodyError extends Error {
  constructor(code) { super(code); this.name = 'DeviceBootstrapCustodyError'; this.code = code; }
}
const fail = code => { throw new CustodyError(code); };
const need = condition => { if (!condition) fail('custody_invalid'); };
const disabled = Object.freeze({ seal: async () => fail('custody_disabled'), open: async () => fail('custody_disabled') });
function textBytes(value, limit) {
  need(typeof value === 'string' && value.length > 0 && value.length <= limit);
  const bytes = encoder.encode(value);
  need(bytes.length <= limit && decoder.decode(bytes) === value);
  return bytes;
}
export function createDeviceBootstrapSealer(options = {}) {
  let key, keyID;
  try {
    need(options && typeof options === 'object' && !Array.isArray(options));
    const enabled = Object.getOwnPropertyDescriptor(options, 'enabled');
    if (enabled === undefined) return disabled;
    need(Object.hasOwn(enabled, 'value'));
    if (enabled.value !== true) return disabled;
    need([Object.prototype, null].includes(Object.getPrototypeOf(options)));
    const descriptors = Object.getOwnPropertyDescriptors(options);
    need(Reflect.ownKeys(descriptors).length === 3
      && ['enabled', 'keyID', 'key'].every(name => descriptors[name] && Object.hasOwn(descriptors[name], 'value')));
    key = descriptors.key.value; keyID = descriptors.keyID.value;
    need(typeof keyID === 'string' && /^[a-z0-9][a-z0-9_-]{0,31}$/.test(keyID));
    need(key instanceof CryptoKey && key.type === 'secret' && key.extractable === false
      && key.algorithm.name === 'AES-GCM' && key.algorithm.length === 256
      && key.usages.length === 2 && key.usages.includes('encrypt') && key.usages.includes('decrypt'));
  } catch { fail('custody_configuration'); }
  const aad = context => {
    textBytes(context, maximum);
    return encoder.encode(`cliphoard.bootstrap-custody\n1\n${keyID}\n${context}`);
  };
  return Object.freeze({
    async seal(plaintext, context) {
      try {
        const bytes = textBytes(plaintext, maximum), additionalData = aad(context);
        const iv = crypto.getRandomValues(new Uint8Array(12));
        const sealed = await crypto.subtle.encrypt({ name: 'AES-GCM', iv, additionalData, tagLength: 128 }, key, bytes);
        return `${prefix}.${keyID}.${base64url(iv)}.${base64url(new Uint8Array(sealed))}`;
      } catch { fail('custody_unavailable'); }
    },
    async open(envelope, context) {
      try {
        need(typeof envelope === 'string' && envelope.length <= 2900);
        const parts = envelope.split('.');
        need(parts.length === 4 && parts[0] === prefix && parts[1] === keyID);
        const iv = decode(parts[2], 12), ciphertext = decode(parts[3], undefined, maximum + 16);
        need(ciphertext.length > 16);
        const clear = await crypto.subtle.decrypt({ name: 'AES-GCM', iv, additionalData: aad(context), tagLength: 128 }, key, ciphertext);
        const plaintext = decoder.decode(clear); textBytes(plaintext, maximum);
        return plaintext;
      } catch { fail('custody_unavailable'); }
    },
  });
}
