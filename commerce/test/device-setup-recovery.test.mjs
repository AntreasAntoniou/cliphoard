import test from 'node:test';import assert from 'node:assert/strict';
import {fixture} from './stripe-fixtures.mjs';import {orderService} from '../src/stripe-order.mjs';
import {createDeviceSetupRecoveryRoute} from '../src/device-setup-recovery.mjs';
import {deviceSetupRecoveryClient} from '../src/device-setup-recovery-client.mjs';
import {claimPage} from '../src/stripe-claim-page.mjs';
const enabled={enabled:true,readiness:async()=>true};const svc=f=>orderService({...f,deviceFulfilment:enabled,deviceAuthority:{enabled:true,orderRef:f.ref,sessionId:f.stripe.s?.id??'cs_test_unstarted'}});
test('private claim token authorizes only existing active device scope; trusted recovery link is original',async()=>{const f=await fixture();await svc(f).start(f.ref);f.stripe.pay();const scope=await svc(f).authorizeSetupRecovery(f.ref,f.token());assert.equal(scope.orderRef,f.ref);assert.equal(scope.sessionId,f.stripe.s.id);assert.deepEqual(await svc(f).setupRecoveryLink(),{claimURL:f.stripe.s.success_url});await assert.rejects(svc(f).authorizeSetupRecovery(f.ref,'bad'));f.stripe.refundRows=[{id:'re_X'}];await assert.rejects(svc(f).authorizeSetupRecovery(f.ref,f.token()));assert.deepEqual(await svc(f).setupRecoveryLink(),{claimURL:f.stripe.s.success_url});});
test('legacy claim token cannot request device setup',async()=>{const f=await fixture();await f.service().start(f.ref);f.stripe.pay();await f.service().paid(f.ref,f.stripe.s.id);await assert.rejects(svc(f).authorizeSetupRecovery(f.ref,f.token()));});
test('recovery is explicit same-origin POST and exact bounded payload, never GET',async()=>{
 let calls=0;const input={orderRef:'12345678-1234-4234-8234-123456789abc',token:'A'.repeat(43),requestID:Buffer.alloc(16,7).toString('base64url')};
 const route=createDeviceSetupRecoveryRoute({enabled:true,origin:'https://purchase.example',bodyTimeoutMilliseconds:100,admit:async()=>true,requestRecovery:async v=>{assert.deepEqual(v,input);calls++;return {ok:true,code:'delivery_requested'};}});
 const req=(method='POST',origin='https://purchase.example',body=input)=>new Request('https://purchase.example/pro/recover',{method,headers:{Origin:origin,'Content-Type':'application/json'},...(method==='POST'?{body:JSON.stringify(body)}:{})});
 assert.equal((await route.handle(req())).status,202);assert.equal(calls,1);assert.notEqual((await route.handle(req('GET'))).status,202);assert.notEqual((await route.handle(req('POST','https://else.example'))).status,202);assert.notEqual((await route.handle(req('POST',undefined,{...input,extra:1}))).status,202);assert.equal(calls,1);
});
test('unavailable admission and malformed acknowledgement are never claimed as delivery',async()=>{for(const admit of [async()=>false,async()=>true]){const route=createDeviceSetupRecoveryRoute({enabled:true,origin:'https://purchase.example',bodyTimeoutMilliseconds:100,admit,requestRecovery:async()=>({ok:true,code:'wrong'})});const r=await route.handle(new Request('https://purchase.example/pro/recover',{method:'POST',headers:{Origin:'https://purchase.example','Content-Type':'application/json'},body:JSON.stringify({orderRef:'12345678-1234-4234-8234-123456789abc',token:'A'.repeat(43),requestID:Buffer.alloc(16,7).toString('base64url')})}));assert.notEqual(r.status,202);assert.ok(!(await r.text()).includes('AAAAA'));}});
test('body bounds, malformed UTF-8 and a stalled stream reject before trusted work',async()=>{
 let calls=0,cancelled=0;
 const route=createDeviceSetupRecoveryRoute({enabled:true,origin:'https://purchase.example',bodyTimeoutMilliseconds:20,admit:async()=>{calls++;return true;},requestRecovery:async()=>{calls++;}});
 for(const body of ['x'.repeat(513),new Uint8Array([0xff]),new ReadableStream({cancel(){cancelled++;}})]){
  const r=await route.handle(new Request('https://purchase.example/pro/recover',{method:'POST',headers:{Origin:'https://purchase.example','Content-Type':'application/json'},body,duplex:'half'}));assert.notEqual(r.status,202);
 }
 assert.equal(calls,0);assert.equal(cancelled,1);
});
test('browser recovery is click-only and retries uncertain outcome with the same private in-memory request ID',async()=>{
 const node=()=>({hidden:true,disabled:false,textContent:'',addEventListener(_e,fn){this.click=fn;}}),button=node(),status=node(),requests=[];
 let fail=true;
 const runtime={document:{getElementById:id=>id==='recover-setup'?button:status},location:{href:'https://purchase.example/pro/claim?order=12345678-1234-4234-8234-123456789abc&token='+'A'.repeat(43)},crypto, btoa, AbortController,setTimeout,clearTimeout,
 fetch:async(url,options)=>{requests.push({url,options});if(fail){fail=false;throw Error('lost ACK');}return Response.json({result:'delivery_requested'},{status:202});}};
 deviceSetupRecoveryClient(runtime);assert.equal(requests.length,0);await button.click();assert.equal(button.disabled,false);assert.match(status.textContent,/couldn’t confirm/);
 await button.click();assert.equal(requests.length,2);assert.deepEqual(JSON.parse(requests[0].options.body),JSON.parse(requests[1].options.body));assert.equal(requests[0].options.referrerPolicy,'no-referrer');assert.equal(requests[0].options.redirect,'error');assert.equal(requests[0].url,'/pro/recover');assert.equal(button.disabled,true);assert.match(status.textContent,/requested/);await button.click();assert.equal(requests.length,2);
});
test('only the device page exposes recovery and allows the same-origin POST',async()=>{
 for(const result of ['device_pending','pending','ready','payment_blocked']){
  const r=await claimPage({result,licence:'synthetic',download:'https://cliphoard.dev'}),html=await r.text();
  assert.equal(html.includes('id="recover-setup"'),result==='device_pending');assert.equal(r.headers.get('Content-Security-Policy').includes("connect-src 'self'"),result==='device_pending');
  assert.equal(html.includes('function deviceSetupRecoveryClient'),result==='device_pending');
 }
});
