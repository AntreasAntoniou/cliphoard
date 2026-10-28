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
test('setup recovery releases original gate, uses original scope, disposes ACK and never provisions', {timeout:3000},async t=>{
 const f=await setup(t,{deviceFulfilment:{enabled:true,readiness:async()=>true}});await f.call('start');f.stripe.pay();
 let recovered=0,disposed=0;
 f.directory.requestRecovery=async(scope,id)=>{recovered++;assert.equal(scope.orderRef,f.ref);assert.equal(id,token(16,7));assert.equal((await f.host().inspectDeviceAuthority()).state,'active');return {ok:true,code:'delivery_requested',[Symbol.dispose](){disposed++;}};};
 assert.deepEqual(await f.host().setupRecoveryLink(),{claimURL:f.stripe.s.success_url});
 const input={orderRef:f.ref,token:f.token(),requestID:token(16,7)};
 assert.deepEqual(await f.host().requestSetupRecovery(input),{ok:true,code:'delivery_requested'});assert.equal(recovered,1);assert.equal(disposed,1);assert.equal(f.state.process,0);assert.equal(await f.storage.get(key),undefined);
 await assert.rejects(f.host().requestSetupRecovery({...input,token:token(32,3)}));assert.equal(recovered,1);
 f.directory.requestRecovery=async()=>{throw Error('missing reservation');};await assert.rejects(f.host().requestSetupRecovery(input));assert.equal(f.state.process,0);assert.equal(await f.storage.get(key),undefined);
});
test('setup recovery fails closed on accessor ACK without invoking getter and refunds enqueue only terminal refresh', {timeout:3000},async t=>{
 const f=await setup(t,{deviceFulfilment:{enabled:true,readiness:async()=>true}});await f.call('start');f.stripe.pay();let getters=0,disposed=0,calls=0;
 f.directory.requestRecovery=async()=>{calls++;return {ok:true,get code(){getters++;return 'delivery_requested';},[Symbol.dispose](){disposed++;}};};
 const input={orderRef:f.ref,token:f.token(),requestID:token(16,7)};await assert.rejects(f.host().requestSetupRecovery(input));assert.equal(getters,0);assert.equal(disposed,1);
 f.stripe.refundRows=[{id:'re_test'}];await assert.rejects(f.host().requestSetupRecovery(input));assert.equal(calls,1);assert.equal((await f.storage.get('order')).blocked,true);assert.equal((await f.storage.get(key)).pending,true);await f.tick();assert.equal(f.state.process,0);assert.equal(f.state.refresh,1);
});
