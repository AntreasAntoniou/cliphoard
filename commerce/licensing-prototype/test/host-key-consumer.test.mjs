import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { reconstructHostKeyCapabilities } from '../host-key-consumer.mjs';
import { syntheticMaterial, PRESEALED, BOOTSTRAP_FIELDS, RECEIPT_FIELDS } from './host-key-consumer-fixtures.mjs';
import { createDeviceBootstrapIssuer, verifyBootstrap, parseBootstrap, bootstrapPayload } from '../bootstrap-protocol.mjs';
import { createPinnedDeviceReceiptIssuer } from '../stripe-authority.mjs';
import { base64url, decode, parseReceipt, verifyReceiptSignature, canonicalDevice } from '../protocol.mjs';

const options = () => ({ enabled: true, material: syntheticMaterial() });
const make = () => reconstructHostKeyCapabilities(options());
const cleanError = code => error => {
  assert.equal(error.name, 'HostKeyConsumerError');
  assert.equal(error.message, code); assert.equal(error.code, code);
  assert.equal(error.cause, undefined); return true;
};
const rejectedConfiguration = input => assert.rejects(reconstructHostKeyCapabilities(input), cleanError('host_keys_configuration'));
const trust = host => ({ expectedProfileID: BOOTSTRAP_FIELDS.profileID,
  bootstrapKeyID: host.bootstrapSigner.bootstrapKeyID,
  bootstrapPublicKey: host.bootstrapSigner.bootstrapPublicKey,
  receiptIssuerKeyIDs: [host.receiptSigner.issuerKeyID] });

test('disabled import is inert before material, and enabled accessors are not evaluated', async () => {
  let reads = 0;
  for (const enabled of [undefined, false, 0, 'true']) {
    const input = { get material() { reads++; throw Error('SECRET'); } };
    if (enabled !== undefined) input.enabled = enabled;
    const host = await reconstructHostKeyCapabilities(input);
    await assert.rejects(host.bootstrapSigner.sign(new Uint8Array()), cleanError('host_keys_disabled'));
    await assert.rejects(host.receiptSigner.sign({}), cleanError('host_keys_disabled'));
    await assert.rejects(host.setupSealer.open('x', 'y'), cleanError('host_keys_disabled'));
  }
  await reconstructHostKeyCapabilities(Object.create({ enabled: true }));
  await rejectedConfiguration({ get enabled() { reads++; throw Error('SECRET'); } });
  assert.equal(reads, 0);
});

test('exact own-data records reject prototypes, symbols, missing/extra fields and getters', async () => {
  const mutations = [
    o => { o.extra = true; }, o => { delete o.material; },
    o => { o[Symbol('extra')] = true; }, o => { Object.setPrototypeOf(o, { marker: true }); },
    o => { o.material = []; }, o => { o.material.extra = true; },
    o => { delete o.material.receiptSigner; },
    o => { Object.setPrototypeOf(o.material.bootstrapSigner, { marker: true }); },
    o => { o.material.receiptSigner[Symbol('extra')] = true; },
    o => { Object.defineProperty(o.material.setupSealer, 'keyID', { get() { throw Error('SECRET'); } }); },
    o => { Object.defineProperty(o.material.bootstrapSigner.privateJWK, 'd', { get() { throw Error('SECRET'); } }); },
  ];
  for (const mutate of mutations) { const o = options(); mutate(o); await rejectedConfiguration(o); }
});

test('role and pairwise key-ID separation reject swaps and aliases', async () => {
  for (const role of ['bootstrapSigner', 'receiptSigner', 'setupSealer']) {
    const o = options(); o.material[role].role = 'other'; await rejectedConfiguration(o);
  }
  for (const id of ['', 'Upper', 'bad=', 'a'.repeat(33)]) {
    const o = options(); o.material.bootstrapSigner.keyID = id; await rejectedConfiguration(o);
  }
  for (const role of ['receiptSigner', 'setupSealer']) {
    const o = options(); o.material[role].keyID = o.material.bootstrapSigner.keyID; await rejectedConfiguration(o);
  }
  const o = options(); o.material.setupSealer.keyID = o.material.receiptSigner.keyID; await rejectedConfiguration(o);
});

test('private JWK exact encoding, curve, extractability and usages are enforced', async () => {
  const mutations = [
    j => { j.kty = 'RSA'; }, j => { j.crv = 'P-384'; }, j => { j.ext = true; },
    j => { j.key_ops = ['sign', 'verify']; }, j => { j.key_ops = ['verify']; },
    j => { j.key_ops.extra = true; }, j => { j.key_ops = Object.assign([], { length: 1 }); },
    j => { Object.defineProperty(j.key_ops, '0', { get() { throw Error('SECRET'); } }); },
    j => { j.d += '='; }, j => { j.x = 'AA'; }, j => { j.y = 'AA'; },
    j => { j.d = 'AA'; }, j => { j.alg = 'ES256'; }, j => { delete j.d; },
    j => { j[Symbol('extra')] = 1; },
  ];
  for (const mutate of mutations) { const o = options(); mutate(o.material.bootstrapSigner.privateJWK); await rejectedConfiguration(o); }
});

test('signer coordinate/public-pin mismatch and shared signer keys refuse', async () => {
  const o = options(); o.material.bootstrapSigner.publicKey = o.material.receiptSigner.publicKey;
  await rejectedConfiguration(o);
  const same = options();
  same.material.receiptSigner.publicKey = same.material.bootstrapSigner.publicKey;
  same.material.receiptSigner.privateJWK = structuredClone(same.material.bootstrapSigner.privateJWK);
  await rejectedConfiguration(same);
  const invalid = options(); invalid.material.bootstrapSigner.publicKey = base64url(new Uint8Array(65));
  await rejectedConfiguration(invalid);
});

test('a mismatched private scalar fails the reconstruction probe', async () => {
  const o = options(); o.material.bootstrapSigner.privateJWK.d = o.material.receiptSigner.privateJWK.d;
  await assert.rejects(reconstructHostKeyCapabilities(o), cleanError('host_keys_unavailable'));
});

test('AES source is an exact unextended ordinary private-buffer Uint8Array of 32 bytes', async () => {
  for (const bytes of [new Uint8Array(31), new Uint8Array(33), [], new ArrayBuffer(32),
    new Uint8Array(new SharedArrayBuffer(32)), Object.assign(new Uint8Array(32), { extra: 1 })]) {
    const o = options(); o.material.setupSealer.keyBytes = bytes; await rejectedConfiguration(o);
  }
});

test('own typed-array accessors refuse without invocation at both byte boundaries', async t => {
  for (const property of ['buffer', 'length']) {
    await t.test(`sealer ${property}`, async () => {
      const o = options(), bytes = o.material.setupSealer.keyBytes;
      const original = bytes[property]; let reads = 0;
      Object.defineProperty(bytes, property, { get() { reads++; return original; } });
      await rejectedConfiguration(o); assert.equal(reads, 0);
    });
    await t.test(`bootstrap ${property}`, async () => {
      const host = await make();
      const bytes = bootstrapPayload({ ...BOOTSTRAP_FIELDS, bootstrapKeyID: host.bootstrapSigner.bootstrapKeyID });
      const original = bytes[property]; let reads = 0;
      Object.defineProperty(bytes, property, { get() { reads++; return original; } });
      await assert.rejects(host.bootstrapSigner.sign(bytes), cleanError('host_keys_unavailable'));
      assert.equal(reads, 0);
    });
  }
});

test('all input records, JWKs and AES bytes are captured before the first await', async () => {
  const o = options(), pending = reconstructHostKeyCapabilities(o);
  o.material.bootstrapSigner.privateJWK.d = 'SECRET';
  o.material.receiptSigner.publicKey = 'SECRET';
  o.material.setupSealer.keyBytes.fill(255);
  o.material.setupSealer.keyID = 'changed';
  o.material = null;
  const host = await pending;
  assert.equal(host.bootstrapSigner.bootstrapKeyID, 'synthetic-bootstrap');
  assert.equal(host.receiptSigner.issuerKeyID, 'synthetic-receipt');
  assert.equal(host.setupSealer.keyID, 'synthetic-sealer');
  assert.equal(await host.setupSealer.open(PRESEALED.envelope, PRESEALED.context), PRESEALED.plaintext);
});

test('two reconstructed hosts compose with actual bootstrap issuer and signature verification', async () => {
  const first = await make(), second = await make();
  assert.equal(first.bootstrapSigner.bootstrapPublicKey, second.bootstrapSigner.bootstrapPublicKey);
  const envelope = await createDeviceBootstrapIssuer({ enabled: true,
    fields: { ...BOOTSTRAP_FIELDS }, signer: second.bootstrapSigner }).issue();
  const verified = await verifyBootstrap(envelope, trust(first));
  assert.equal(verified.entitlementID, BOOTSTRAP_FIELDS.entitlementID);
  assert.equal(parseBootstrap(envelope).signature.length, 64);
  await assert.rejects(verifyBootstrap(envelope, { ...trust(first), bootstrapPublicKey: first.receiptSigner.issuerPublicKey }));
  assert.throws(() => parseReceipt(envelope));
});

test('receipt callback composes with the actual pinned issuer and returns a verified CLIPD1', async () => {
  const first = await make(), second = await make();
  assert.equal(first.receiptSigner.issuerPublicKey, second.receiptSigner.issuerPublicKey);
  const issuer = createPinnedDeviceReceiptIssuer({ enabled: true,
    entitlementID: RECEIPT_FIELDS.entitlementID, ...second.receiptSigner });
  const envelope = await issuer({ ...RECEIPT_FIELDS });
  const parsed = await verifyReceiptSignature(envelope,
    new Map([[first.receiptSigner.issuerKeyID, first.receiptSigner.issuerPublicKey]]));
  assert.deepEqual(parsed.fields, RECEIPT_FIELDS);
  await assert.rejects(verifyReceiptSignature(envelope,
    new Map([[first.receiptSigner.issuerKeyID, first.bootstrapSigner.bootstrapPublicKey]])));
  assert.throws(() => parseBootstrap(envelope));
});

test('bootstrap callback refuses other protocol bytes and mismatched captured signer IDs', async () => {
  const host = await make();
  for (const fields of [{ ...BOOTSTRAP_FIELDS, bootstrapKeyID: 'wrong' },
    { ...BOOTSTRAP_FIELDS, bootstrapKeyID: host.bootstrapSigner.bootstrapKeyID, receiptIssuerKeyID: 'wrong' }]) {
    await assert.rejects(host.bootstrapSigner.sign(bootstrapPayload(fields)), cleanError('host_keys_unavailable'));
  }
  await assert.rejects(host.bootstrapSigner.sign(new TextEncoder().encode('cliphoard.device-receipt\n1')), cleanError('host_keys_unavailable'));
  await assert.rejects(host.bootstrapSigner.sign('payload'), cleanError('host_keys_unavailable'));
  const payload = bootstrapPayload({ ...BOOTSTRAP_FIELDS, bootstrapKeyID: host.bootstrapSigner.bootstrapKeyID });
  await assert.rejects(host.bootstrapSigner.sign(payload, true), cleanError('host_keys_unavailable'));
  const mutable = payload.slice(), pending = host.bootstrapSigner.sign(mutable); mutable.fill(0);
  const key = await canonicalDevice(host.bootstrapSigner.bootstrapPublicKey);
  assert(await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key.key, await pending, payload));
});

test('receipt callback captures exact own data and refuses foreign issuer IDs and extra arguments', async () => {
  const host = await make();
  await assert.rejects(host.receiptSigner.sign({ ...RECEIPT_FIELDS, issuerKeyID: 'wrong' }), cleanError('host_keys_unavailable'));
  await assert.rejects(host.receiptSigner.sign({ ...RECEIPT_FIELDS, extra: true }), cleanError('host_keys_unavailable'));
  await assert.rejects(host.receiptSigner.sign({ ...RECEIPT_FIELDS, get issuedAt() { throw Error('SECRET'); } }), cleanError('host_keys_unavailable'));
  await assert.rejects(host.receiptSigner.sign({ ...RECEIPT_FIELDS }, true), cleanError('host_keys_unavailable'));
  const fields = { ...RECEIPT_FIELDS }, pending = host.receiptSigner.sign(fields); fields.receiptID = 'SECRET';
  assert.deepEqual(parseReceipt(await pending).fields, RECEIPT_FIELDS);
});

test('fresh host recovers a presealed envelope and another reconstructed host opens newly sealed data', async () => {
  const first = await make(), second = await make();
  assert.equal(await second.setupSealer.open(PRESEALED.envelope, PRESEALED.context), PRESEALED.plaintext);
  const envelope = await first.setupSealer.seal('SYNTHETIC ONLY', 'synthetic-new-context');
  assert.equal(await second.setupSealer.open(envelope, 'synthetic-new-context'), 'SYNTHETIC ONLY');
});

test('AES recovery rejects changed context, key ID, ciphertext and replacement key under the same ID', async () => {
  const host = await make();
  await assert.rejects(host.setupSealer.open(PRESEALED.envelope, 'wrong'), cleanError('host_keys_unavailable'));
  await assert.rejects(host.setupSealer.open(PRESEALED.envelope.replace('synthetic-sealer', 'wrong'), PRESEALED.context), cleanError('host_keys_unavailable'));
  const parts = PRESEALED.envelope.split('.'), bytes = decode(parts[3]); bytes[0] ^= 1;
  await assert.rejects(host.setupSealer.open([...parts.slice(0, 3), base64url(bytes)].join('.'), PRESEALED.context), cleanError('host_keys_unavailable'));
  const o = options(); o.material.setupSealer.keyBytes.fill(255);
  const replacement = await reconstructHostKeyCapabilities(o);
  await assert.rejects(replacement.setupSealer.open(PRESEALED.envelope, PRESEALED.context), cleanError('host_keys_unavailable'));
});

test('only frozen protocol-specific capabilities and public IDs/pins escape reconstruction', async () => {
  const host = await make();
  assert.deepEqual(Reflect.ownKeys(host).sort(), ['bootstrapSigner', 'receiptSigner', 'setupSealer']);
  const visit = value => {
    assert(!(value instanceof CryptoKey)); assert(!(value instanceof Uint8Array));
    if (typeof value === 'object' && value) {
      assert(Object.isFrozen(value));
      for (const key of Reflect.ownKeys(value)) {
        assert(!/private|jwk|bytes|export|material/i.test(String(key))); visit(value[key]);
      }
    }
  };
  visit(host);
  assert.deepEqual(Reflect.ownKeys(host.bootstrapSigner).sort(), ['bootstrapKeyID', 'bootstrapPublicKey', 'sign']);
  assert.deepEqual(Reflect.ownKeys(host.receiptSigner).sort(), ['issuerKeyID', 'issuerPublicKey', 'sign']);
  assert.deepEqual(Reflect.ownKeys(host.setupSealer).sort(), ['keyID', 'open', 'seal']);
});

test('runtime imports both private signers and AES with nonextractable least usages', async t => {
  const original = crypto.subtle.importKey.bind(crypto.subtle), seen = [];
  t.mock.method(crypto.subtle, 'importKey', async (...args) => {
    const key = await original(...args);
    if (key.type === 'private' || key.type === 'secret') {
      seen.push({ type: key.type, algorithm: key.algorithm.name, extractable: key.extractable, usages: [...key.usages] });
      await assert.rejects(crypto.subtle.exportKey(key.type === 'private' ? 'jwk' : 'raw', key));
    }
    return key;
  });
  await make();
  assert.deepEqual(seen, [
    { type: 'private', algorithm: 'ECDSA', extractable: false, usages: ['sign'] },
    { type: 'private', algorithm: 'ECDSA', extractable: false, usages: ['sign'] },
    { type: 'secret', algorithm: 'AES-GCM', extractable: false, usages: ['encrypt', 'decrypt'] },
  ]);
});

test('null-prototype data records work and import failures expose only a fixed sanitized error', async t => {
  const o = options();
  Object.setPrototypeOf(o, null); Object.setPrototypeOf(o.material, null);
  Object.setPrototypeOf(o.material.bootstrapSigner, null);
  Object.setPrototypeOf(o.material.bootstrapSigner.privateJWK, null);
  const host = await reconstructHostKeyCapabilities(o); assert.equal(host.setupSealer.keyID, 'synthetic-sealer');
  t.mock.method(crypto.subtle, 'importKey', async () => { throw Error('SECRET PROVIDER DETAILS'); });
  await assert.rejects(make(), cleanError('host_keys_unavailable'));
});

test('consumer has only local protocol/custody imports and no IO, generation or key-export surface', async () => {
  const source = await readFile(new URL('../host-key-consumer.mjs', import.meta.url), 'utf8');
  const imports = [...source.matchAll(/from ['"]([^'"]+)['"]/g)].map(m => m[1]);
  assert.deepEqual(imports.sort(), ['./bootstrap-custody.mjs', './bootstrap-protocol.mjs', './protocol.mjs']);
  assert(!/\b(?:fetch|console|process|require|generateKey|exportKey|eval)\s*[.(]/.test(source));
  assert(!/import\s*\(/.test(source));
});
