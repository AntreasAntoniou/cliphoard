import test from 'node:test';
import assert from 'node:assert/strict';
import { createDeviceBootstrapAdmission } from '../bootstrap-admission.mjs';
import { createDeviceLicenceAuthenticatedEdge } from '../durable-object-hosts.mjs';
import { bootstrapPayload } from '../bootstrap-protocol.mjs';
import { base64url } from '../protocol.mjs';
import { syntheticMaterial, BOOTSTRAP_FIELDS } from './host-key-consumer-fixtures.mjs';
import { reconstructHostKeyCapabilities } from '../host-key-consumer.mjs';
const origin = 'https://admission.synthetic.invalid', realm = 'synthetic-admission';
async function fixture() {
  const material = syntheticMaterial(), keys = await reconstructHostKeyCapabilities({ enabled: true, material });
  const fields = { ...BOOTSTRAP_FIELDS, bootstrapKeyID: material.bootstrapSigner.keyID };
  const payload = bootstrapPayload(fields), envelope = `CLIPB1.${base64url(payload)}.${base64url(await keys.bootstrapSigner.sign(payload))}`;
  const trust = { expectedProfileID: fields.profileID, bootstrapKeyID: fields.bootstrapKeyID,
    bootstrapPublicKey: material.bootstrapSigner.publicKey, receiptIssuerKeyIDs: [fields.receiptIssuerKeyID] };
  const config = { enabled: true, realm, origin, trust };
  const request = (setup = envelope, extra = {}) => new Request(`${origin}/device-licensing/v1/begin`, {
    method: 'POST', headers: { 'content-type': 'application/json', 'X-Cliphoard-Setup': setup, 'X-Cliphoard-Entitlement': fields.entitlementID },
    body: '{"exact":"body-and-proof"}', ...extra });
  return { fields, envelope, trust, config, request, admission: createDeviceBootstrapAdmission(config) };
}
test('default remains inert and getter-bearing trust is rejected without getter execution', async () => {
  let calls = 0; const disabled = createDeviceBootstrapAdmission({ get trust() { calls++; throw Error(); } });
  await assert.rejects(disabled.authenticate(), /disabled/); assert.equal(calls, 0);
  const f = await fixture();
  assert.throws(() => createDeviceBootstrapAdmission({ ...f.config, trust: { ...f.trust, get expectedProfileID() { calls++; return 'other'; } } }), /configuration/);
  assert.equal(calls, 0);
});
test('signed exact setup grants only pinned realm locator and leaves body untouched', async () => {
  const f = await fixture(), request = f.request();
  assert.deepEqual(await f.admission.authenticate(request, f.fields.entitlementID), { decision: 'allow', realm, entitlementID: f.fields.entitlementID });
  assert.equal(request.bodyUsed, false); assert.equal(await request.text(), '{"exact":"body-and-proof"}');
});
test('tampered missing oversized duplicate setup and wrong locator all deny', async () => {
  const f = await fixture();
  const tampered = f.envelope.slice(0, -2) + (f.envelope.at(-2) === 'A' ? 'B' : 'A') + f.envelope.at(-1);
  for (const setup of ['', 'X'.repeat(1025), `${f.envelope}, ${f.envelope}`, tampered, 'CLIPB1.invalid.invalid'])
    assert.equal((await f.admission.authenticate(f.request(setup), f.fields.entitlementID)).decision, 'deny');
  const missing = f.request(); missing.headers.delete('X-Cliphoard-Setup');
  assert.equal((await f.admission.authenticate(missing, f.fields.entitlementID)).decision, 'deny');
  assert.equal((await f.admission.authenticate(f.request(), base64url(new Uint8Array(16).fill(55)))).decision, 'deny');
});
test('untrusted profile or bootstrap pin and mutable caller trust cannot change captured admission', async () => {
  const f = await fixture();
  assert.equal((await f.admission.authenticate(f.request(undefined, { method: 'PUT' }), f.fields.entitlementID)).decision, 'deny');
  assert.equal((await createDeviceBootstrapAdmission({ ...f.config, trust: { ...f.trust, expectedProfileID: 'wrong-profile' } }).authenticate(f.request(), f.fields.entitlementID)).decision, 'deny');
  assert.equal((await createDeviceBootstrapAdmission({ ...f.config, trust: { ...f.trust, bootstrapPublicKey: syntheticMaterial().receiptSigner.publicKey } }).authenticate(f.request(), f.fields.entitlementID)).decision, 'deny');
  f.trust.expectedProfileID = 'changed'; f.trust.receiptIssuerKeyIDs[0] = 'changed';
  assert.equal((await f.admission.authenticate(f.request(), f.fields.entitlementID)).decision, 'allow');
});
test('origin path query method consumed body locked body and cancellation deny', async () => {
  const f = await fixture();
  for (const url of ['https://other.invalid/device-licensing/v1/begin', `${origin}/other`, `${origin}/device-licensing/v1/begin?x=1`]) {
    const request = new Request(url, f.request()); assert.equal((await f.admission.authenticate(request, f.fields.entitlementID)).decision, 'deny');
  }
  const consumed = f.request(); await consumed.text(); assert.equal((await f.admission.authenticate(consumed, f.fields.entitlementID)).decision, 'deny');
  const locked = f.request(), reader = locked.body.getReader(); assert.equal((await f.admission.authenticate(locked, f.fields.entitlementID)).decision, 'deny'); reader.releaseLock();
  const controller = new AbortController(), request = f.request(undefined, { signal: controller.signal });
  const pending = f.admission.authenticate(request, f.fields.entitlementID); controller.abort();
  assert.equal((await pending).decision, 'deny');
});
test('edge rejects different configured realm before directory lookup', async () => {
  const f = await fixture(); let calls = 0;
  const namespace = { idFromName: n => n, getByName: () => { calls++; throw Error('must not lookup'); } };
  const edge = createDeviceLicenceAuthenticatedEdge({ enabled: true, realm: 'other-realm', origin,
    directoryNamespace: namespace, targetNamespace: namespace, maxConcurrentRequests: 1, authenticate: f.admission.authenticate });
  assert.equal((await edge.handle(f.request())).status, 503); assert.equal(calls, 0);
});
