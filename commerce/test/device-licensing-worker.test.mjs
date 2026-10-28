import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Miniflare, Log, LogLevel } from 'miniflare';
import { FakeStripe, event, webhookRequest } from './stripe-fixtures.mjs';
import { syntheticMaterial } from '../licensing-prototype/test/host-key-consumer-fixtures.mjs';
import { verifyBootstrap } from '../licensing-prototype/bootstrap-protocol.mjs';
import { digest, randomToken, tokenDigest, approvalMessage, base64url, verifyReceiptSignature } from '../licensing-prototype/protocol.mjs';
import { deviceConfiguration, deviceKeys, guardedDeviceMail } from '../src/device-licensing-config.mjs';

async function fixture() {
  const material = syntheticMaterial(), ref = '00000000-0000-4000-8000-000000000001', now = Math.floor(Date.now() / 1000);
  const policy = { maximumAttemptsPerInvocation: 4, maxPendingOperations: 4, invocationBudgetMilliseconds: 5000,
    prearmDelayMilliseconds: 1000, retryDelayMilliseconds: 1000, continuationDelayMilliseconds: 1000 };
  const config = { version: 1, realm: 'synthetic-whole', selection: { profileID: 'synthetic-profile',
    bootstrapKeyID: material.bootstrapSigner.keyID, bootstrapPublicKey: material.bootstrapSigner.publicKey,
    receiptIssuerKeyID: material.receiptSigner.keyID, receiptIssuerPublicKey: material.receiptSigner.publicKey },
    sealerKeyID: material.setupSealer.keyID, sealerCommitment: await digest(material.setupSealer.keyBytes),
    qualification: { recipient: 'iam@antreas.io', orderRefs: [ref], startsAt: now - 1, endsAt: now + 300 },
    operational: { bootstrap: { ...policy, deliveryLeaseSeconds: 60 }, activation: policy,
      limits: { challengeTTLSeconds: 120, deliveryLeaseSeconds: 60 }, httpBodyTimeoutMilliseconds: 3000, mailTimeoutMilliseconds: 3000,
      maxConcurrentRequests: 4, alarmRecoveryDelayMilliseconds: 1000, orderRetrySeconds: 1 } };
  const env = { STRIPE_ACCOUNT_ID: 'acct_TestAccount', STRIPE_MODE: 'test', STRIPE_PRODUCT_ID: 'prod_Cliphoard', STRIPE_PRICE_ID: 'price_Pro',
    STRIPE_CURRENCY: 'gbp', STRIPE_UNIT_AMOUNT: '1000', PUBLIC_ORIGIN: 'https://purchase.example', CANCEL_URL: 'https://purchase.example/?cancelled=1',
    DOWNLOAD_URL: 'https://download.example/cliphoard.dmg', CHECKOUT_ENABLED: 'true', ISSUANCE_ENABLED: 'true', DELIVERY_ENABLED: 'true', EMAIL_DELIVERY_ENABLED: 'true',
    EXPECTED_PUBLIC_KEY_HEX: '00'.repeat(32), CLAIM_ENCRYPTION_KEY: base64url(new Uint8Array(32).fill(42)), CLAIM_KEY_ID: 'synthetic-claim',
    STRIPE_WEBHOOK_SECRET: 'whsec_syntheticSecret012345678901', STRIPE_API_KEY: 'sk_test_syntheticSecret012345678901', EMAIL_FROM: 'support@cliphoard.dev',
    DEVICE_FULFILMENT_ENABLED: 'true', DEVICE_LICENCE_CONFIG_V1: JSON.stringify(config),
    DEVICE_LICENCE_CUSTODY_V1: JSON.stringify({ ...material, setupSealer: { ...material.setupSealer, keyBytes: Array.from(material.setupSealer.keyBytes) } }) };
  return { env, config, material, ref, stripe: new FakeStripe(env) };
}

test('explicit canonical configuration and key reconstruction reject mismatched custody; synchronous mail kill fence covers both shapes', async () => {
  const f = await fixture(), c = deviceConfiguration(f.env); assert.equal((await deviceKeys(f.env, c)).bootstrapSigner.bootstrapKeyID, f.material.bootstrapSigner.keyID);
  const bad = { ...f.env, DEVICE_LICENCE_CUSTODY_V1: f.env.DEVICE_LICENCE_CUSTODY_V1.replace('synthetic-sealer', 'wrong-sealer') };
  await assert.rejects(deviceKeys(bad, deviceConfiguration(bad)));
  assert.throws(() => deviceConfiguration({ ...f.env, DEVICE_LICENCE_CONFIG_V1: ' ' + f.env.DEVICE_LICENCE_CONFIG_V1 }));
  const sent = []; f.env.EMAIL = { send: m => { sent.push(m); return { messageId: 'synthetic-id' }; } };
  const send = guardedDeviceMail(f.env, c, `${f.env.PUBLIC_ORIGIN}/pro/claim?order=${f.ref}&token=${randomToken(32)}`);
  const message = { from: 'support@cliphoard.dev', to: 'iam@antreas.io', replyTo: 'support@cliphoard.dev', subject: 'Synthetic', text: 'Synthetic only' };
  await send({ deliveryID: `${randomToken(16)}.initial`, message }); await send(message); assert.equal(sent.length, 2);
  assert(sent[0].text.includes('Private setup recovery')); assert.equal(sent[1].text, message.text);
  f.env.EMAIL_DELIVERY_ENABLED = 'false'; assert.throws(() => send(message)); assert.throws(() => send({ deliveryID: `${randomToken(16)}.initial`, message }));
  assert.equal(sent.length, 2); assert.throws(() => send({ ...message, to: 'someone@example.invalid' }));
});

test('whole exported candidate: checkout, paid feed, setup, durable hold/allow, signed activation, recovery and refund across persisted workerd', { timeout: 60000 }, async () => {
  const f = await fixture(), mail = [], disk = await mkdtemp(join(tmpdir(), 'cliphoard-whole-worker-')); let runtime, unexpected = 0;
  const outbound = async request => {
    const url = new URL(request.url);
    if (url.origin === 'https://mail.synthetic.invalid') { mail.push(await request.json()); return Response.json({ messageId: `synthetic-${mail.length}` }); }
    if (url.origin !== 'https://api.stripe.com') { unexpected++; throw Error('Unexpected Worker egress'); }
    const p = url.pathname, s = f.stripe; let value;
    if (p === '/v1/account') value = await s.account();
    else if (p.startsWith('/v1/prices/')) value = await s.price();
    else if (p === '/v1/checkout/sessions' && request.method === 'POST') value = await s.createCheckout(Object.fromEntries(new URLSearchParams(await request.text())), request.headers.get('idempotency-key'));
    else if (p === '/v1/checkout/sessions') value = await s.sessionsForPayment();
    else if (p.endsWith('/line_items')) value = await s.lineItems();
    else if (p.startsWith('/v1/checkout/sessions/')) value = await s.session(p.split('/').at(-1));
    else if (p.startsWith('/v1/payment_intents/')) value = await s.paymentIntent();
    else if (p.startsWith('/v1/charges/')) value = await s.charge();
    else if (p === '/v1/refunds') value = await s.refunds();
    else { unexpected++; throw Error('Unexpected Stripe endpoint'); }
    return Response.json(value);
  };
  const options = { cf: false, host: '127.0.0.1', port: 0, log: new Log(LogLevel.NONE), durableObjectsPersist: disk,
    workers: [{ name: 'candidate', modules: true, compatibilityDate: '2026-07-01',
      scriptPath: fileURLToPath(new URL('./device-licensing-runtime-harness.mjs', import.meta.url)), bindings: f.env,
      durableObjects: { STRIPE_ORDERS: { className: 'StripeOrder', useSQLite: true }, DEVICE_LICENCE_DIRECTORY: { className: 'DeviceLicenceDirectory', useSQLite: true },
        DEVICE_LICENCE_ENTITLEMENTS: { className: 'DeviceLicenceEntitlement', useSQLite: true } },
      serviceBindings: { EMAIL: { name: 'bindings', entrypoint: 'SyntheticEmail' }, CHECKOUT_RATE_LIMITER: { name: 'bindings', entrypoint: 'SyntheticRateLimit' } }, outboundService: outbound },
    { name: 'bindings', modules: true, compatibilityDate: '2026-07-01', scriptPath: fileURLToPath(new URL('./device-licensing-bindings-harness.mjs', import.meta.url)), outboundService: outbound }] };
  const post = (path, value, headers = {}) => runtime.dispatchFetch(f.env.PUBLIC_ORIGIN + path, { method: 'POST',
    headers: { 'content-type': 'application/json', origin: f.env.PUBLIC_ORIGIN, 'CF-Connecting-IP': '192.0.2.1', ...headers }, body: JSON.stringify(value) });
  const waitMail = async count => { const deadline = Date.now() + 12000; while (mail.length < count && Date.now() < deadline) await new Promise(r => setTimeout(r, 100)); assert.equal(mail.length,count,'mail count'); };
  const hook = async payload => { const req = webhookRequest(f, payload); const res = await runtime.dispatchFetch(req.url, { method: req.method, headers: req.headers, body: await req.text() }); assert.equal(res.status, 200, await res.clone().text()); };
  try {
    assert.equal(Object.hasOwn(f.env, 'CLIPHOARD_SIGNING_SEED'), false);
    runtime = new Miniflare(options);
    assert.equal((await post('/checkout/stripe', { orderRef: '00000000-0000-4000-8000-000000000099' })).status, 503); assert.equal(f.stripe.creates, 0);
    const checkout = await post('/checkout/stripe', { orderRef: f.ref }); assert.equal(checkout.status, 200, await checkout.clone().text()); assert.equal(f.stripe.creates, 1);
    f.stripe.pay(); f.stripe.s.customer_details.email = 'iam@antreas.io'; await hook(event(f));
    await waitMail(1);
    const setup = mail[0].text.match(/CLIPB1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/)[0];
    const verified = await verifyBootstrap(setup, { expectedProfileID: 'synthetic-profile', bootstrapKeyID: f.material.bootstrapSigner.keyID,
      bootstrapPublicKey: f.material.bootstrapSigner.publicKey, receiptIssuerKeyIDs: [f.material.receiptSigner.keyID] });
    const headers = { 'X-Cliphoard-Setup': setup, 'X-Cliphoard-Entitlement': verified.entitlementID };
    const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
    const begin = () => ({ entitlementHandle: verified.activationHandle, devicePublicKey: base64url(publicBytes), requestID: randomToken(16) });
    const publicBytes = new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey));
    assert.equal((await post('/device-licensing/v1/begin', begin(), headers)).status, 503); assert.equal(mail.length, 1);
    const allowed = await runtime.dispatchFetch('https://control.synthetic.invalid', { method: 'POST', body: JSON.stringify({ entitlementID: verified.entitlementID, expectedRevision: 1, decision: 'allow' }) });
    assert.equal(allowed.status, 200, await allowed.clone().text()); assert.equal((await allowed.json()).revision, 2);
    const begun = await post('/device-licensing/v1/begin', begin(), headers); assert.equal(begun.status, 200, await begun.clone().text()); const challenge = (await begun.json()).challenge;
    await waitMail(2);
    const approvalToken = mail[1].text.match(/Approval code:\n([A-Za-z0-9_-]{43})\n/)[1], approvalRequestID = randomToken(16);
    const proof = { challengeID: challenge.challengeID, approvalToken, approvalRequestID,
      deviceSignature: base64url(new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, pair.privateKey, approvalMessage(challenge, await tokenDigest(approvalToken), approvalRequestID)))) };
    const approved = await post('/device-licensing/v1/approve', proof, headers); assert.equal(approved.status, 200, await approved.clone().text());
    const receipt = (await approved.json()).receipt; await verifyReceiptSignature(receipt, new Map([[f.material.receiptSigner.keyID, f.material.receiptSigner.publicKey]]));
    await runtime.dispose(); runtime = undefined; runtime = new Miniflare(options);
    const retry = await post('/device-licensing/v1/approve', proof, headers); assert.equal(retry.status, 200); assert.equal((await retry.json()).receipt, receipt);
    const token = new URL(f.stripe.s.success_url).searchParams.get('token');
    assert.notEqual((await post('/pro/recover', { orderRef: f.ref, token: randomToken(32), requestID: randomToken(16) })).status, 202); assert.equal(mail.length, 2);
    const recovery = { orderRef: f.ref, token, requestID: randomToken(16) };
    const recovered = await post('/pro/recover', recovery); assert.equal(recovered.status, 202, await recovered.clone().text());
    const recoveryDeadline = Date.now() + 12000;
    while (mail.filter(m => m.text.includes('CLIPB1.')).length < 2 && Date.now() < recoveryDeadline) await new Promise(r => setTimeout(r,100));
    const setupMessages = mail.filter(m => m.text.includes('CLIPB1.'));
    assert.equal(setupMessages.length,2); assert(setupMessages.every(m=>m.text.includes(setup)));
    // Receipt notification is a separate legitimate outbox message. Any repeated
    // approval must retain the exact code, and receipt mail must match the reply.
    assert(mail.filter(m=>!m.text.includes('CLIPB1.')).every(m=>
      m.subject==='Approve this Mac for Cliphoard Pro' ? m.text===mail[1].text
        : m.subject==='Your Mac approval for Cliphoard Pro' && m.text.includes(receipt)));
    assert(mail.some(m=>m.subject==='Your Mac approval for Cliphoard Pro' && m.text.includes(receipt)));
    assert.equal((await post('/pro/recover', recovery)).status,202);
    assert.equal(f.stripe.creates, 1);
    await runtime.dispose(); runtime = undefined;
    for (const key of ['DEVICE_FULFILMENT_ENABLED','CHECKOUT_ENABLED','ISSUANCE_ENABLED','DELIVERY_ENABLED','EMAIL_DELIVERY_ENABLED']) f.env[key]='false';
    runtime = new Miniflare(options);
    assert.equal((await post('/checkout/stripe',{orderRef:f.ref})).status,503);
    f.stripe.ch.amount_refunded = 1000; f.stripe.ch.refunded = true;
    f.stripe.refundRows = [{ id: 're_Refund1', object: 'refund', status: 'succeeded', amount: 1000, currency: 'gbp', charge: 'ch_Charge1', payment_intent: 'pi_Payment1' }];
    await hook({ ...event(f, 'charge.refunded'), id: 'evt_RefundEvent' });
    const authority = await runtime.dispatchFetch('https://control.synthetic.invalid',{method:'POST',body:JSON.stringify({action:'authority'})});
    assert.equal((await authority.json()).state,'blocked');
    assert.equal((await post('/device-licensing/v1/begin', begin(), headers)).status, 503);
    assert.notEqual((await post('/pro/recover', { orderRef: f.ref, token, requestID: randomToken(16) })).status, 202);
    await verifyReceiptSignature(receipt, new Map([[f.material.receiptSigner.keyID, f.material.receiptSigner.publicKey]]));
    assert.equal(unexpected, 0); assert.equal(mail.filter(m=>m.text.includes('CLIPB1.')).length,2);
  } finally { await runtime?.dispose(); await rm(disk, { recursive: true, force: true }); }
});
