import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture } from './stripe-fixtures.mjs';
import { orderService } from '../src/stripe-order.mjs';
const enabled=Object.freeze({enabled:true,readiness:async()=>true});
const service=(f,deviceFulfilment=enabled)=>orderService({...f,deviceFulfilment,schedule:async at=>f.alarms.push(at)});
test('new device order never reads legacy signer, persists mode, pays and claims without CLIP1',async()=>{
 const f=await fixture();let reads=0;Object.defineProperty(f.env,'CLIPHOARD_SIGNING_SEED',{get(){reads++;throw Error('forbidden');}});
 await service(f).start(f.ref);assert.equal((await f.storage.get('order')).fulfilment,'device-v1');f.stripe.pay();
 assert.deepEqual(await service(f).paid(f.ref,f.stripe.s.id),{result:'device_pending'});
 assert.deepEqual(await service(f).claim(f.ref,f.token()),{result:'device_pending'});
 await service(f).drain();const r=await f.storage.get('order');assert.equal(r.licence,null);assert.equal(r.issued,null);assert.equal(r.mail.status,'idle');assert.equal(f.sent.length,0);assert.equal(reads,0);
});
test('device order fails closed through legacy service and cannot be silently reissued',async()=>{
 const f=await fixture();await service(f).start(f.ref);f.stripe.pay();await assert.rejects(f.service().paid(f.ref,f.stripe.s.id));assert.equal((await f.storage.get('order')).licence,null);
});
test('unready device fulfilment cannot create a checkout, including retry',async()=>{
 const f=await fixture();await assert.rejects(service(f,{enabled:true,readiness:async()=>false}).start(f.ref));assert.equal(f.stripe.creates,0);
 await service(f).start(f.ref);await assert.rejects(service(f,{enabled:true,readiness:async()=>{throw Error('private');}}).start(f.ref),e=>e.code==='device_fulfilment_unavailable');assert.equal(f.stripe.creates,1);
});
test('existing legacy orders retain CLIP1 mode even through an opted-in service',async()=>{
 const f=await fixture();await f.service().start(f.ref);f.stripe.pay();await service(f).paid(f.ref,f.stripe.s.id);assert.match((await f.storage.get('order')).licence,/^CLIP1-/);assert.equal((await f.storage.get('order')).fulfilment,undefined);
});
test('device refunds stay terminal; paused issuance and invalid claim do not disclose setup',async()=>{
 const f=await fixture();await service(f).start(f.ref);f.stripe.pay();f.env.ISSUANCE_ENABLED='false';await assert.rejects(service(f).paid(f.ref,f.stripe.s.id));
 await assert.rejects(service(f).claim(f.ref,'bad'));f.env.ISSUANCE_ENABLED='true';f.stripe.refundRows=[{id:'re_Test'}];
 assert.deepEqual(await service(f).paid(f.ref,f.stripe.s.id),{result:'payment_blocked'});f.stripe.refundRows=[];
 assert.deepEqual(await service(f).claim(f.ref,f.token()),{result:'payment_blocked'});assert.equal((await f.storage.get('order')).licence,null);
});
test('persisted device order cannot contain a legacy licence or malformed mode',async()=>{
 for(const change of [{licence:'CLIP1.invalid'},{issued:1},{mail:{status:'pending',attempts:0}},{fulfilment:'unknown'}]){
 const f=await fixture();await service(f).start(f.ref);f.stripe.pay();const r=await f.storage.get('order');await f.storage.put('order',{...r,...change});await assert.rejects(service(f).paid(f.ref,f.stripe.s.id));}
});
test('configuration getters and extra fields are rejected without invocation',async()=>{
 const f=await fixture();let calls=0;const bad={enabled:true,get readiness(){calls++;return async()=>true;}};
 assert.throws(()=>service(f,bad));assert.equal(calls,0);assert.throws(()=>service(f,{...enabled,extra:true}));
});
test('device claim page describes email setup and cannot expose a legacy key',async()=>{
 const {claimPage}=await import('../src/stripe-claim-page.mjs');const r=await claimPage({result:'device_pending',licence:'MUST_NOT_RENDER'});const html=await r.text();assert.equal(r.status,202);assert.match(html,/Payment confirmed/);assert.match(html,/Approve each new Mac/);assert.ok(!html.includes('MUST_NOT_RENDER'));assert.ok(!html.includes('id="licence-key"'));
});
