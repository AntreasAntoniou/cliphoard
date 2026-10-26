import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { base64url, decode, signReceipt, parseReceipt, verifyReceiptSignature, verifyOffline,
  canonicalDevice, receiptPayload, PROTOCOL } from '../protocol.mjs';
import { receiptFixture, syntheticKey } from './fixtures.mjs';

const rejectsCode = (action, code) => assert.rejects(action, error => error.code === code);

test('P-256 signed receipt grants only after fresh receipt-bound device possession', async () => {
  const f = await receiptFixture();
  const messages = [];
  const device = { publicKey: f.device.provider.publicKey,
    signProof: async bytes => { messages.push(bytes); return f.device.provider.signProof(bytes); } };
  assert.deepEqual(await verifyOffline(f.receipt, device, f.trust), f.fields);
  assert.deepEqual(await verifyOffline(f.receipt, device, f.trust), f.fields);
  assert.notDeepEqual(messages[0], messages[1]);
  assert.match(new TextDecoder().decode(messages[0]), /^cliphoard\.device-local-proof\n1\n/);
});

test('copied receipt, spoofed public key, stale proof and another trusted signer fail', async () => {
  const f = await receiptFixture(); const other = await syntheticKey();
  await rejectsCode(() => verifyOffline(f.receipt, other.provider, f.trust), 'wrong_device');
  await rejectsCode(() => verifyOffline(f.receipt,
    { publicKey: f.device.provider.publicKey, signProof: other.provider.signProof }, f.trust), 'invalid_possession');
  let previous;
  await verifyOffline(f.receipt, { publicKey: f.device.provider.publicKey,
    signProof: async bytes => { previous = await f.device.provider.signProof(bytes); return previous; } }, f.trust);
  await rejectsCode(() => verifyOffline(f.receipt,
    { publicKey: f.device.provider.publicKey, signProof: async () => previous }, f.trust), 'invalid_possession');
  await rejectsCode(() => verifyReceiptSignature(f.receipt, new Map()), 'untrusted_issuer');
  await rejectsCode(() => verifyReceiptSignature(f.receipt, new Map([['synthetic-1', other.publicKey]])), 'invalid_signature');
});

test('signed future version, alternate purpose, product, lease, algorithm and unknown fields fail', async () => {
  const f = await receiptFixture();
  const lines = new TextDecoder().decode(receiptPayload(f.fields)).split('\n');
  for (const [index, value] of [[0, 'cliphoard.device-approval'], [1, '2'], [1, '01'], [2, 'Ed25519'], [8, 'free'], [9, 'lease']]) {
    const changed = [...lines]; changed[index] = value;
    const payload = new TextEncoder().encode(changed.join('\n'));
    const signature = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, f.signer.privateKey, payload);
    await rejectsCode(() => verifyReceiptSignature(`CLIPD1.${base64url(payload)}.${base64url(signature)}`, f.trust), 'unsupported_protocol');
  }
  assert.throws(() => receiptPayload({ ...f.fields, ignored: 'extra' }));
  for (const issuedAt of [0, -1, Infinity, NaN, 1.5, PROTOCOL.maxEpoch + 1, '1767323045']) {
    assert.throws(() => receiptPayload({ ...f.fields, issuedAt }));
  }
});

test('malformed, oversized, noncanonical encodings, tampered payload and DER signatures fail', async () => {
  const f = await receiptFixture(); const [, payload, signature] = f.receipt.split('.');
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  const alias = signature.slice(0, -1) + alphabet[alphabet.indexOf(signature.at(-1)) | 1];
  for (const input of ['', 'CLIPD1.', 'CLIPD1..', f.receipt + '.extra', f.receipt + '=', ' ' + f.receipt,
    f.receipt + '\n', 'CLIPD1.💥.💥', 'CLIPD2.' + f.receipt.slice(7), 'CLIP1-' + f.receipt.slice(7),
    'CLIPD1.' + 'A'.repeat(2048) + '.AA', `CLIPD1.${payload}=.${signature}`, `CLIPD1.${payload}.${alias}`,
    `CLIPD1.${payload}.${base64url(new Uint8Array(72))}`]) {
    assert.throws(() => parseReceipt(input));
  }
  const mutated = await signReceipt({ ...f.fields, receiptID: base64url(new Uint8Array(16)) }, f.signer.privateKey);
  await rejectsCode(() => verifyReceiptSignature(mutated.split('.').slice(0, 2).join('.') + '.' + signature, f.trust), 'invalid_signature');
  for (const invalidKey of ['A', base64url(new Uint8Array(65)), base64url(Uint8Array.from([4, ...new Uint8Array(64)])),
    base64url(new Uint8Array(33))]) await assert.rejects(() => canonicalDevice(invalidKey));
});

test('verification uses no network, clock, storage, token analytics or production keys', async () => {
  const f = await receiptFixture(); const savedFetch = globalThis.fetch;
  globalThis.fetch = () => { throw new Error('network forbidden in receipt verification'); };
  try { assert.deepEqual(await verifyOffline(f.receipt, f.device.provider, f.trust), f.fields); }
  finally { globalThis.fetch = savedFetch; }
  for (const module of ['protocol.mjs', 'activation-state.mjs', 'in-memory-service.mjs']) {
    const source = await readFile(new URL('../' + module, import.meta.url), 'utf8');
    const code = source.split('\n').filter(line => !line.trim().startsWith('//')).join('\n');
    assert.doesNotMatch(code, /\b(?:fetch|console\.[a-z]+|AnalyticsEngine|localStorage|process\.env)\s*\(/);
  }
});

test('shipping app, legacy licence, StoreKit and deployment manifests do not enable the prototype', async () => {
  const root = new URL('../../../', import.meta.url);
  for (const name of ['Package.swift', 'Makefile', 'commerce/package.json', 'commerce/wrangler.example.toml',
    'commerce/wrangler.stripe.example.toml', 'commerce/src/worker.mjs', 'commerce/src/stripe-worker.mjs',
    'Sources/Cliphoard/App/AppDelegate.swift', 'Sources/Cliphoard/UI/SettingsView.swift',
    'Sources/Cliphoard/Support/Licence.swift', 'Sources/Cliphoard/Support/StorePurchase.swift']) {
    const source = await readFile(new URL(name, root), 'utf8');
    assert.doesNotMatch(source, /CLIPHOARD_DEVICE_LICENSING_PROTOTYPE|DeviceLicenceVerifier|licensing-prototype/, name);
  }
});
