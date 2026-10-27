import test from 'node:test';
import assert from 'node:assert/strict';
import { BOOTSTRAP, bootstrapPayload, parseBootstrap, verifyBootstrap, createDeviceBootstrapIssuer } from '../bootstrap-protocol.mjs';
import { syntheticKey } from './fixtures.mjs';
import { randomToken, base64url, decode, parseReceipt, signReceipt, PROTOCOL } from '../protocol.mjs';

async function fixture() {
  const key = await syntheticKey();
  const fields = { profileID: 'synthetic-direct', receiptIssuerKeyID: 'receipt-synthetic',
    entitlementID: randomToken(16), activationHandle: randomToken(32), issuedAt: 1767323045 };
  let calls = 0;
  const options = { enabled: true, fields: { ...fields },
    signer: { bootstrapKeyID: 'bootstrap-synthetic', bootstrapPublicKey: key.publicKey,
      sign: async payload => { calls++; return key.provider.signProof(payload); } } };
  const trust = { expectedProfileID: fields.profileID, bootstrapKeyID: 'bootstrap-synthetic',
    bootstrapPublicKey: key.publicKey, receiptIssuerKeyIDs: ['receipt-synthetic'] };
  return { key, fields, options, trust, calls: () => calls };
}

test('trusted issuer emits exact ten-line CLIPB1 and independently verifies pinned signature', async () => {
  const f = await fixture();
  const issuer = createDeviceBootstrapIssuer(f.options);
  assert.deepEqual(Object.keys(issuer), ['issue']); assert(Object.isFrozen(issuer)); assert.equal(f.calls(), 0);
  const envelope = await issuer.issue();
  const parsed = parseBootstrap(envelope);
  assert.deepEqual(parsed.fields, { bootstrapKeyID: 'bootstrap-synthetic', ...f.fields });
  const expected = ['cliphoard.device-bootstrap', '1', 'P256-SHA256', 'bootstrap-synthetic',
    f.fields.profileID, f.fields.receiptIssuerKeyID, f.fields.entitlementID, f.fields.activationHandle, '1767323045', 'pro'].join('\n');
  assert.equal(new TextDecoder().decode(parsed.payload), expected); assert.equal(parsed.signature.length, 64);
  assert.equal(envelope, `CLIPB1.${base64url(new TextEncoder().encode(expected))}.${base64url(parsed.signature)}`);
  assert.deepEqual(await verifyBootstrap(envelope, f.trust), parsed.fields);
  assert.equal(f.calls(), 1); assert.equal(BOOTSTRAP.maxEnvelopeBytes, 1024); assert.equal(BOOTSTRAP.maxPayloadBytes, 512);
});

test('disabled issuer skips inherited switches and dependency getters; enabled getters are never invoked', async () => {
  let calls = 0;
  for (const base of [{}, { enabled: false }, Object.create({ get enabled() { calls++; return true; } })]) {
    Object.defineProperty(base, 'fields', { get() { calls++; throw Error('private fields'); } });
    Object.defineProperty(base, 'signer', { get() { calls++; throw Error('private signer'); } });
    await assert.rejects(createDeviceBootstrapIssuer(base).issue(), { code: 'bootstrap_disabled', message: 'bootstrap_disabled' });
  }
  assert.throws(() => createDeviceBootstrapIssuer({ get enabled() { calls++; return true; } }), { code: 'bootstrap_configuration' });
  assert.equal(calls, 0);
});

test('issuer captures exact own-data purchase fields and signer; no later retargeting or issuance arguments', async () => {
  const f = await fixture(); const issuer = createDeviceBootstrapIssuer(f.options);
  f.options.fields.entitlementID = randomToken(16); f.options.fields.activationHandle = randomToken(32);
  f.options.signer.bootstrapKeyID = 'different'; f.options.signer.sign = () => { throw Error('changed'); };
  await assert.rejects(issuer.issue({ entitlementID: f.fields.entitlementID }), { code: 'bootstrap_rejected' });
  assert.equal(f.calls(), 0);
  assert.deepEqual((await verifyBootstrap(await issuer.issue(), f.trust)), { bootstrapKeyID: 'bootstrap-synthetic', ...f.fields });
});

test('enabled issuer rejects unknown fields, getters, inherited fields and malformed pins before signing', async () => {
  const f = await fixture(); let reads = 0;
  for (const branch of ['fields', 'signer']) for (const key of Object.keys(f.options[branch])) {
    const value = { ...f.options[branch] };
    Object.defineProperty(value, key, { enumerable: true, get() { reads++; throw Error('secret'); } });
    assert.throws(() => createDeviceBootstrapIssuer({ ...f.options, [branch]: value }), { code: 'bootstrap_configuration' });
  }
  for (const extra of ['email','endpoint','issuerPublicKey','eligible','paymentStatus'])
    assert.throws(() => createDeviceBootstrapIssuer({ ...f.options, fields: { ...f.fields, [extra]: 'private' } }), { code: 'bootstrap_configuration' });
  assert.throws(() => createDeviceBootstrapIssuer({ ...f.options, fields: Object.create(f.fields) }), { code: 'bootstrap_configuration' });
  assert.throws(() => createDeviceBootstrapIssuer({ ...f.options, signer: { ...f.options.signer, bootstrapPublicKey: 'bad' } }), { code: 'bootstrap_configuration' });
  assert.equal(reads, 0); assert.equal(f.calls(), 0);
});

test('issuer verifies returned signature against captured payload and explicit bootstrap pin; fixed errors only', async () => {
  const f = await fixture(), other = await syntheticKey();
  const signers = [async () => { throw Error('private provider exception'); },
    payload => other.provider.signProof(payload), async () => new Uint8Array(63),
    async payload => { payload[0] ^= 1; return f.key.provider.signProof(payload); },
    async () => ({ signature: 'secret', recipient: 'private@example.invalid' })];
  for (const sign of signers) {
    const issuer = createDeviceBootstrapIssuer({ ...f.options, signer: { ...f.options.signer, sign } });
    await assert.rejects(issuer.issue(), { code: 'bootstrap_unavailable', message: 'bootstrap_unavailable' });
  }
});

test('different purposes, profiles, unknown keys and receipt issuer allowlists cannot substitute trust', async () => {
  const f = await fixture(), other = await syntheticKey(), envelope = await createDeviceBootstrapIssuer(f.options).issue();
  for (const trust of [{ ...f.trust, expectedProfileID: 'different' }, { ...f.trust, bootstrapKeyID: 'different' },
    { ...f.trust, bootstrapPublicKey: other.publicKey }, { ...f.trust, receiptIssuerKeyIDs: ['different'] }])
    await assert.rejects(verifyBootstrap(envelope, trust));
  assert.throws(() => parseReceipt(envelope));
  const receipt = await signReceipt({ issuerKeyID: 'receipt-synthetic', entitlementID: f.fields.entitlementID,
    deviceKeyHash: randomToken(32), receiptID: randomToken(16), issuedAt: f.fields.issuedAt }, f.key.privateKey);
  assert.throws(() => parseBootstrap(receipt));
  await assert.rejects(verifyBootstrap(`CLIP1-${envelope}`, f.trust));
});

test('parser rejects tampering, padding, whitespace, extras, noncanonical epochs, ASCII violations and bounds', async () => {
  const f = await fixture(), envelope = await createDeviceBootstrapIssuer(f.options).issue();
  const parsed = parseBootstrap(envelope), lines = new TextDecoder().decode(parsed.payload).split('\n');
  const wrap = payload => `CLIPB1.${base64url(new TextEncoder().encode(payload))}.${base64url(parsed.signature)}`;
  const malformed = [envelope+'=', ' '+envelope, envelope+'\n', envelope+'.extra',
    envelope.replace('CLIPB1.','CLIPD1.'), 'x'.repeat(1025), wrap(lines.join('\n')+'\n'), wrap(lines.join('\r\n')),
    wrap(lines.map((x,i)=>i===8?'01767323045':x).join('\n')), wrap(lines.map((x,i)=>i===8?'0':x).join('\n')),
    wrap(lines.map((x,i)=>i===8?String(PROTOCOL.maxEpoch+1):x).join('\n')),
    wrap(lines.map((x,i)=>i===4?'é':x).join('\n')), wrap(lines.map((x,i)=>i===9?'free':x).join('\n')),
    wrap('a'.repeat(513)), wrap(lines.map((x,i)=>i===3?'Uppercase':x).join('\n')),
    wrap(lines.map((x,i)=>i===6?x+'=':x).join('\n'))];
  for (const value of malformed) assert.throws(() => parseBootstrap(value), undefined, value.slice(0,30));
  const changed = wrap(lines.map((x,i)=>i===6?randomToken(16):x).join('\n'));
  assert.equal(parseBootstrap(changed).fields.profileID, f.fields.profileID);
  await assert.rejects(verifyBootstrap(changed, f.trust));
  for (const value of [0,-1,NaN,Infinity,1.5,PROTOCOL.maxEpoch+1])
    assert.throws(() => bootstrapPayload({ ...parsed.fields, issuedAt: value }));
});

test('verification consumes immutable trust fields without getters and creates no issuer action', async () => {
  const f = await fixture(), envelope = await createDeviceBootstrapIssuer(f.options).issue(); let reads = 0;
  for (const name of Object.keys(f.trust)) {
    const trust = { ...f.trust }; Object.defineProperty(trust, name, { enumerable: true, get() { reads++; return f.trust[name]; } });
    await assert.rejects(verifyBootstrap(envelope, trust));
  }
  const issuers = ['receipt-synthetic']; Object.defineProperty(issuers,'0',{get(){reads++;return 'receipt-synthetic';}});
  await assert.rejects(verifyBootstrap(envelope,{...f.trust,receiptIssuerKeyIDs:issuers}));
  const result = await verifyBootstrap(envelope,f.trust); assert(Object.isFrozen(result));
  assert.equal(reads,0); assert.equal(f.calls(),1);
  assert.equal(result.endpoint,undefined); assert.equal(result.publicKey,undefined); assert.equal(result.isProApproved,undefined);
});
