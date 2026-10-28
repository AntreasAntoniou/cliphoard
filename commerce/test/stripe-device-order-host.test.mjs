import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { createStripeDeviceOrderHost } from '../src/stripe-device-order-host.mjs';
import { fixture } from './stripe-fixtures.mjs';
const key='cliphoard_device_feed_v1';
const token=(n,v)=>Buffer.alloc(n,v).toString('base64url');
class Base {}
async function setup(t,options={}) {
  const f=await fixture(),db=new DatabaseSync(':memory:');t.after(()=>db.close());
  const events=[], backgrounds=[];let physical=null,kvTail=Promise.resolve(),host;
  const originalPut=f.storage.put.bind(f.storage);
  Object.assign(f.storage,{
    sql:{exec:(q,...a)=>db.prepare(q).all(...a)},
    transactionSync(fn){db.exec('BEGIN IMMEDIATE');try{const v=fn();db.exec('COMMIT');return v;}catch(e){db.exec('ROLLBACK');throw e;}},
    transaction(fn){const p=kvTail.then(()=>fn(f.storage));kvTail=p.catch(()=>{});return p;},sync:async()=>{},
    getAlarm:async()=>physical,setAlarm:async at=>{events.push('physical');physical=at;},deleteAlarm:async()=>{physical=null;},
    put:async(k,v)=>{events.push(k===key?'feed-write':v.blocked?'blocked-write':v.licence?'licence-write':'order-write');return originalPut(k,v);},
  });
  const state={process:0,refresh:0,dispose:0,inspect:0,lost:false,bad:false};
  const directory={
    async processPurchase(scope){state.process++;const fact=await host.inspectDeviceAuthority();state.inspect++;
      assert.equal(fact.orderRef,scope.orderRef);assert.equal(fact.state,'active');
      if(state.lost){state.lost=false;throw Error('lost-ack');}
      return {entitlementID:token(16,1),provisioningID:token(16,2),bindingDigest:token(32,3),ok:true,
        code:state.bad?'unexpected':'issued',[Symbol.dispose](){state.dispose++;}};},
    async refreshPurchase(scope){state.refresh++;const fact=await host.inspectDeviceAuthority();state.inspect++;assert.equal(fact.orderRef,scope.orderRef);
      return {ok:true,code:'authority_refreshed',[Symbol.dispose](){state.dispose++;}};},
  };
  const name=`${f.env.STRIPE_ACCOUNT_ID}:test:${f.ref}`,ctx={id:{toString:()=>options.wrongId?'wrong':name},storage:f.storage,
    waitUntil:p=>backgrounds.push(p),blockConcurrencyWhile:fn=>fn()};
  const Host=createStripeDeviceOrderHost({enabled:true,DurableObject:Base,configure:()=>({
    orderNamespace:{idFromName:n=>({toString:()=>n})},directoryNamespace:{getByName:n=>{assert.equal(n,'synthetic:directory');return directory;}},
    deviceFulfilment:options.deviceFulfilment??{enabled:false},directoryName:'synthetic:directory',stripe:f.stripe,deliver:undefined,now:f.now,retrySeconds:5,alarmRecoveryDelayMilliseconds:1000,
  })});
  function recreate(){host=new Host(ctx,f.env);return host;}
  recreate();
  const call=async(action,value={})=>{const response=await host.fetch(new Request('https://order.internal/',{method:'POST',body:JSON.stringify({action,orderRef:f.ref,...value})}));return {status:response.status,body:await response.json()};};
  const tick=async()=>{f.advance(10);await host.alarm();};
  return {...f,db,events,state,directory,call,tick,recreate,host:()=>host,physical:()=>physical};
}
test('disabled host does not read trusted dependencies',()=>{
 let calls=0;assert.throws(()=>createStripeDeviceOrderHost({get configure(){calls++;throw Error();}}),/order_host_disabled/);assert.equal(calls,0);
});
test('absent order keeps original checkout and exact ctx identity rejects wrong host',async t=>{
 const f=await setup(t);assert.equal((await f.call('start')).status,200);assert.equal(f.stripe.creates,1);assert.equal(await f.storage.get(key),undefined);
 const wrong=await setup(t,{wrongId:true});assert.equal((await wrong.call('start')).status,503);assert.equal(wrong.stripe.creates,0);
});
test('paid wake is durable before original licence mutation and directory callback does not deadlock', {timeout:3000},async t=>{
 const f=await setup(t);await f.call('start');f.stripe.pay();f.events.length=0;
 const paid=await f.call('paid',{sessionId:f.stripe.s.id});assert.equal(paid.body.result,'issued');
 assert.ok(f.events.indexOf('physical')<f.events.indexOf('feed-write'));assert.ok(f.events.indexOf('feed-write')<f.events.indexOf('licence-write'));
 assert.equal(f.state.process,0);await f.tick();assert.ok(f.state.process>=1);assert.equal(f.sent.length,1);assert.ok(f.state.dispose>=1);
 for(let n=0;n<3&&f.physical()!==null;n++)await f.tick();
 assert.equal(f.physical(),null);const previous=f.state.process;await f.tick();assert.equal(f.state.process,previous);
});
test('refund before feed drain uses fresh blocked authority and separate legacy channel',async t=>{
 const f=await setup(t);await f.call('start');f.stripe.pay();await f.call('paid',{sessionId:f.stripe.s.id});
 f.stripe.refundRows=[{id:'re_synthetic'}];const refund=await f.call('refund',{sessionId:f.stripe.s.id});assert.equal(refund.body.result,'payment_blocked');
 await f.tick();assert.equal(f.state.process,0);assert.equal(f.state.refresh,1);assert.equal(f.sent.length,0);
 assert.equal((await f.storage.get('order')).blocked,true);
});
test('lost ACK reconstructs original host and retries same durable scope',async t=>{
 const f=await setup(t);await f.call('start');f.stripe.pay();await f.call('paid',{sessionId:f.stripe.s.id});f.state.lost=true;
 await assert.rejects(f.tick(),/alarm_dispatch_failed/);assert.equal((await f.storage.get(key)).pending,true);
 const original=await f.storage.get('order'), row=await f.storage.get(key);f.recreate();await f.tick();
 assert.equal(f.state.process,2);assert.equal((await f.storage.get(key)).scope,row.scope);
 assert.equal((await f.storage.get('order')).licence,original.licence);assert.equal(f.stripe.creates,1);
});
test('wrong session, original scope, ctx identity and inspector arguments fail closed',async t=>{
 const f=await setup(t);await f.call('start');f.stripe.pay();
 assert.equal((await f.call('paid',{sessionId:'cs_wrong'})).status,503);assert.equal(await f.storage.get(key),undefined);
 await assert.rejects(f.host().inspectDeviceAuthority({state:'active'}));
 assert.equal((await f.call('inspectDeviceAuthority')).status,404);
 const row=await f.storage.get('order');await f.storage.put('order',{...row,scope:'wrong'});
 await assert.rejects(f.host().inspectDeviceAuthority());assert.equal(await f.storage.get(key),undefined);
});
test('prearm or durable wake failure prevents original paid mutation',async t=>{
 for(const fault of ['alarm','feed']){
  const f=await setup(t);await f.call('start');f.stripe.pay();const put=f.storage.put;
  if(fault==='alarm')f.storage.setAlarm=async()=>{throw Error('unavailable');};
  else f.storage.put=async(k,v)=>{if(k===key)throw Error('unavailable');return put(k,v);};
  assert.equal((await f.call('paid',{sessionId:f.stripe.s.id})).status,503);
  assert.equal((await f.storage.get('order')).licence,null);assert.equal(f.state.process,0);
  if(fault==='feed')assert.notEqual(f.physical(),null);
 }
});
test('RPC ACK getters are not executed, disposal runs on rejection and durable retry stays pending',async t=>{
 const f=await setup(t);await f.call('start');f.stripe.pay();await f.call('paid',{sessionId:f.stripe.s.id});
 let getters=0,disposals=0;
 f.directory.processPurchase=async()=>({entitlementID:token(16,1),provisioningID:token(16,2),bindingDigest:token(32,3),ok:true,
  get code(){getters++;return 'issued';},[Symbol.dispose](){disposals++;}});
 await assert.rejects(f.tick(),/alarm_dispatch_failed/);assert.equal(getters,0);assert.equal(disposals,1);
 assert.equal((await f.storage.get(key)).pending,true);assert.notEqual(f.physical(),null);
});
test('paused issuance leaves active feed pending while blocked refresh still works',async t=>{
 const f=await setup(t);await f.call('start');f.stripe.pay();f.env.ISSUANCE_ENABLED='false';
 assert.equal((await f.call('paid',{sessionId:f.stripe.s.id})).status,503);await assert.rejects(f.tick(),/alarm_dispatch_failed/);
 assert.equal(f.state.process,0);assert.equal((await f.storage.get(key)).pending,true);
 f.stripe.refundRows=[{id:'re_synthetic'}];await f.call('refund',{sessionId:f.stripe.s.id});await f.tick();
 assert.equal(f.state.process,0);assert.equal(f.state.refresh,1);
});
test('claim refund discovery wakes before tombstone and invalid bearer never wakes',async t=>{
 const f=await setup(t);await f.call('start');f.stripe.pay();await f.call('paid',{sessionId:f.stripe.s.id});
 for(let n=0;n<3&&f.physical()!==null;n++)await f.tick();
 const revision=(await f.storage.get(key)).revision;
 assert.equal((await f.call('claim',{token:token(32,9)})).status,404);assert.equal((await f.storage.get(key)).revision,revision);
 f.stripe.refundRows=[{id:'re_synthetic'}];f.events.length=0;
 assert.equal((await f.call('claim',{token:f.token()})).body.result,'payment_blocked');
 assert.ok(f.events.indexOf('feed-write')<f.events.indexOf('blocked-write'));await f.tick();assert.equal(f.state.refresh,1);
});
test('legacy pending mail drain discovers refund and does not overwrite licensing retry',async t=>{
 const f=await setup(t);await f.call('start');f.stripe.pay();await f.call('paid',{sessionId:f.stripe.s.id});
 f.stripe.refundRows=[{id:'re_synthetic'}];await f.tick();
 assert.equal((await f.storage.get('order')).blocked,true);assert.equal(f.sent.length,0);assert.equal(f.state.process,0);assert.equal(f.state.refresh,1);
 for(let n=0;n<3&&f.physical()!==null;n++)await f.tick();assert.equal(f.physical(),null);
});
test('pending checkout without session preserves original pending claim semantics',async t=>{
 const f=await setup(t);await f.call('start');const original=await f.storage.get('order');await f.storage.put('order',{...original,sessionId:null});
 const claim=await f.call('claim',{token:f.token()});assert.equal(claim.status,200);assert.equal(claim.body.result,'payment_pending');
 assert.equal(await f.storage.get(key),undefined);
});
test('explicit device-only new order uses captured readiness without CLIP1 seed and feeds original authority',async t=>{
 let readiness=0,seedReads=0;
 const f=await setup(t,{deviceFulfilment:{enabled:true,readiness:async()=>{readiness++;return true;}}});
 Object.defineProperty(f.env,'CLIPHOARD_SIGNING_SEED',{get(){seedReads++;throw Error('no legacy seed');}});
 assert.equal((await f.call('start')).status,200);assert.equal(readiness,1);assert.equal((await f.storage.get('order')).fulfilment,'device-v1');
 f.stripe.pay();assert.equal((await f.call('paid',{sessionId:f.stripe.s.id})).body.result,'device_pending');
 await f.tick();assert.equal(f.state.process,1);assert.equal(f.sent.length,0);assert.equal(seedReads,0);
 const row=await f.storage.get('order');assert.equal(row.licence,null);assert.equal(row.issued,null);assert.equal(row.mail.status,'idle');
 const wake=(await f.storage.get(key)).revision;
 f.stripe.refundRows=[{id:'re_synthetic'}];assert.equal((await f.call('claim',{token:f.token()})).body.result,'payment_blocked');
 assert.ok((await f.storage.get(key)).revision>wake);await f.tick();assert.equal(f.state.refresh,1);assert.equal(seedReads,0);
});
test('device readiness refusal creates no checkout and cannot touch legacy seed',async t=>{
 const f=await setup(t,{deviceFulfilment:{enabled:true,readiness:async()=>false}});
 Object.defineProperty(f.env,'CLIPHOARD_SIGNING_SEED',{get(){throw Error('no seed');}});
 assert.equal((await f.call('start')).status,503);assert.equal(f.stripe.creates,0);assert.equal(await f.storage.get('order'),undefined);
});
