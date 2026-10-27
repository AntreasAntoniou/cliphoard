import test from 'node:test';
import assert from 'node:assert/strict';
import { createDeviceLicenceRouteTarget, createDeviceLicencePublicRouter } from '../public-router.mjs';
import { randomToken, parseReceipt } from '../protocol.mjs';
import { origin, request, scopedFixture, deferred, tick } from './bootstrap-router-fixtures.mjs';

const target = f => createDeviceLicenceRouteTarget({ enabled: true, lifecycle: f.options });
const router = (lookupTarget, maxConcurrentRequests = 2) => createDeviceLicencePublicRouter({
  enabled: true, origin, maxConcurrentRequests, lookupTarget,
});
const call = async (r, id, route, body, options) => {
  const response = await r.handle(request(id, route, body, options));
  return { status: response.status, body: await response.json(), headers: response.headers };
};

test('disabled factories never read dependencies; enabled getter is rejected without invocation', async () => {
  let reads = 0;
  for (const factory of [createDeviceLicenceRouteTarget,createDeviceLicencePublicRouter]) {
    for (const options of [{},{enabled:false},Object.create({get enabled(){reads++;return true;}})]) {
      for(const name of ['lifecycle','origin','maxConcurrentRequests','lookupTarget'])
        Object.defineProperty(options,name,{get(){reads++;throw Error('private');}});
      const value=factory(options); assert(Object.isFrozen(value));
      if(factory===createDeviceLicencePublicRouter) assert.equal((await value.handle(new Request(origin))).status,404);
      else await assert.rejects(value.alarm(),{code:'routing_disabled'});
    }
    assert.throws(()=>factory({get enabled(){reads++;return true;}}),{code:'routing_configuration'});
  }
  assert.equal(reads,0);
});

test('enabled router requires explicit finite capacity and exact captured configuration', () => {
  for(const value of [undefined,0,-1,1.5,Infinity,NaN,Number.MAX_SAFE_INTEGER+1])
    assert.throws(()=>createDeviceLicencePublicRouter({enabled:true,origin,maxConcurrentRequests:value,lookupTarget:()=>null}),{code:'routing_configuration'});
  const options={enabled:true,origin,maxConcurrentRequests:1,lookupTarget:()=>null};
  let reads=0;
  for(const name of ['origin','maxConcurrentRequests','lookupTarget']) {
    const bad={...options};Object.defineProperty(bad,name,{enumerable:true,get(){reads++;return options[name];}});
    assert.throws(()=>createDeviceLicencePublicRouter(bad),{code:'routing_configuration'});
  }
  assert.throws(()=>createDeviceLicencePublicRouter({...options,recipient:'private'}),{code:'routing_configuration'});
  assert.throws(()=>createDeviceLicencePublicRouter({...options,origin:origin+'/'}),{code:'routing_configuration'});
  assert.equal(reads,0);
});

test('router and target reject non-string origins without invoking coercion',async t=>{
  const f=await scopedFixture(t);let reads=0;
  const coercible={toString(){reads++;return origin;}};
  assert.throws(()=>createDeviceLicencePublicRouter({enabled:true,origin:coercible,maxConcurrentRequests:1,lookupTarget:()=>null}),{code:'routing_configuration'});
  assert.throws(()=>createDeviceLicenceRouteTarget({enabled:true,lifecycle:{...f.options,http:{...f.options.http,origin:coercible}}}),{code:'routing_configuration'});
  assert.equal(reads,0);assert.equal(f.state.sqlCalls,0);
});

test('known route, origin, method, header and media rejections plus confirmation never look up a target', async () => {
  let lookups=0; const r=router(()=>{lookups++;throw Error('private');}); const id=randomToken(16);
  const body={entitlementHandle:randomToken(32),devicePublicKey:'bad',requestID:randomToken(16)};
  const variants=[
    new Request(origin+'/other'),
    new Request(origin+'/device-licensing/v1/begin',{method:'GET'}),
    new Request(origin+'/device-licensing/v1/approve',{method:'OPTIONS'}),
    request(id,'begin?x=1',body),request(id,'begin#x',body),
    new Request('https://other.invalid/device-licensing/v1/begin',{method:'POST',body:'{}'}),
    request(id,'begin',body,{headers:{'content-type':'application/json'}}),
    request(id,'begin',body,{headers:{'content-type':'application/json','X-Cliphoard-Entitlement':id+','+id}}),
    request(id,'begin',body,{headers:{'content-type':'application/json','X-Cliphoard-Entitlement':id+'='}}),
    request(id,'begin',body,{headers:{'content-type':'text/plain','X-Cliphoard-Entitlement':id}}),
    request(id,'begin',body,{headers:{'content-type':'application/json','content-encoding':'gzip','X-Cliphoard-Entitlement':id}}),
    request(id,'begin',body,{headers:{'content-type':'application/json','origin':'https://other.invalid','X-Cliphoard-Entitlement':id}}),
    request(id,'begin',body,{headers:{'content-type':'application/json','sec-fetch-site':'same-site','X-Cliphoard-Entitlement':id}}),
    request(id,'begin',body,{headers:{'content-type':'application/json','content-length':'2049','X-Cliphoard-Entitlement':id}}),
    request(id,'begin',body,{headers:{'content-type':'application/json','content-length':'01','X-Cliphoard-Entitlement':id}}),
    request(id,'begin',body,{headers:{'content-type':'application/json','content-length':'0','X-Cliphoard-Entitlement':id}}),
    request(id,'begin',body,{body:undefined}),
  ];
  for(const input of variants) {
    const response=await r.handle(input);assert(response.status>=400);
    assert.equal(response.headers.get('cache-control'),'no-store');assert.equal(response.headers.get('referrer-policy'),'no-referrer');
    assert.equal(response.headers.get('access-control-allow-origin'),null);
    assert.doesNotMatch(await response.text(),/private|entitlementHandle/);
  }
  for(const method of ['GET','HEAD']) {
    const response=await r.handle(new Request(origin+'/device-licensing/v1/confirmation',{method}));
    assert.equal(response.status,200);assert.equal(await response.text(),method==='HEAD'?'':'{"ok":true,"code":"confirmation_required"}');
  }
  const duplicate=new Headers([['content-type','application/json'],['X-Cliphoard-Entitlement',id],['x-cliphoard-entitlement',id]]);
  assert.equal((await r.handle(request(id,'begin',body,{headers:duplicate}))).status,400);
  assert.equal(lookups,0);
});

test('unknown, forged, foreign-origin and mismatched branded targets fail before ledger work',async t=>{
  const a=await scopedFixture(t), b=await scopedFixture(t), foreign=await scopedFixture(t,{origin:'https://foreign.synthetic.invalid'});
  const ta=target(a),tb=target(b),tf=target(foreign);let getters=0;
  const fake={get handle(){getters++;throw Error('private');}};
  for(const value of [null,undefined,{},fake,tb,tf,Object.create(ta),new Proxy(ta,{})]) {
    const response=await call(router(()=>value),a.id,'begin',a.begin());
    assert.equal(response.status,503);assert.deepEqual(response.body,{ok:false,code:'temporarily_unavailable'});
  }
  assert.equal(getters,0);assert.equal(a.state.sqlCalls+b.state.sqlCalls+foreign.state.sqlCalls,0);
  assert.equal((await call(router(()=>{throw Error('private-directory-detail');}),a.id,'begin',a.begin())).status,503);
});

test('target freezes real lifecycle binding, same origin and capabilities before returning its brand',async t=>{
  const f=await scopedFixture(t),ta=target(f);assert(Object.isFrozen(ta));assert.equal(f.state.sqlCalls,0);
  assert.deepEqual(Object.keys(ta).sort(),['alarm','recover','refreshAdmission','refreshAuthority']);
  f.options.binding.entitlementID=randomToken(16);f.options.binding.entitlementHandleDigest=randomToken(32);
  f.options.http.origin='https://mutated.invalid';f.options.inspectDeviceAuthority=()=>{throw Error('mutated');};
  const options={enabled:true,origin,maxConcurrentRequests:1,lookupTarget:id=>id===f.id?ta:null};
  const r=createDeviceLicencePublicRouter(options);options.lookupTarget=()=>({});options.origin='https://mutated.invalid';
  const response=await call(r,f.id,'begin',f.begin());assert.equal(response.status,200);assert.equal(response.body.challenge.entitlementID,f.id);
  assert.equal(f.db.prepare('SELECT entitlement_id FROM device_licence_meta').get().entitlement_id,f.id);
});

test('target rejects accessor binding and origin without reading either',async t=>{
  const f=await scopedFixture(t);let reads=0;
  for(const [branch,key] of [['binding','entitlementID'],['http','origin']]){
    const lifecycle={...f.options,[branch]:{...f.options[branch]}};
    Object.defineProperty(lifecycle[branch],key,{enumerable:true,get(){reads++;return 'private';}});
    assert.throws(()=>createDeviceLicenceRouteTarget({enabled:true,lifecycle}),{code:'routing_configuration'});
  }
  assert.throws(()=>createDeviceLicenceRouteTarget({enabled:true,lifecycle:{...f.options,enabled:false}}),{code:'routing_configuration'});
  assert.equal(reads,0);assert.equal(f.state.sqlCalls,0);
});

test('two actual SQLite lifecycles route independent begin/approve and retain exact issued retries',async t=>{
  const a=await scopedFixture(t),b=await scopedFixture(t),ta=target(a),tb=target(b);
  const directory=new Map([[a.id,ta],[b.id,tb]]),r=router(id=>directory.get(id));
  const inputA=a.begin(),inputB=b.begin();
  const firstA=await call(r,a.id,'begin',inputA),firstB=await call(r,b.id,'begin',inputB);
  assert.equal(firstA.status,200);assert.equal(firstB.status,200);
  assert.equal(firstA.body.challenge.entitlementID,a.id);assert.equal(firstB.body.challenge.entitlementID,b.id);
  assert.deepEqual((await call(r,a.id,'begin',inputA)).body,firstA.body);
  await ta.alarm();await tb.alarm();assert.equal(a.sends.length,1);assert.equal(b.sends.length,1);
  const proofA=await a.approval(firstA.body.challenge),proofB=await b.approval(firstB.body.challenge);
  const issuedA=await call(r,a.id,'approve',proofA),issuedB=await call(r,b.id,'approve',proofB);
  assert.equal(issuedA.status,200);assert.equal(issuedB.status,200);
  assert.equal(parseReceipt(issuedA.body.receipt).fields.entitlementID,a.id);assert.equal(parseReceipt(issuedB.body.receipt).fields.entitlementID,b.id);
  a.state.milliseconds+=3600_000;a.state.admission='hold';a.state.revision++;
  const retry=await call(r,a.id,'approve',proofA);assert.equal(retry.status,200);assert.equal(retry.body.code,'already_issued');assert.equal(retry.body.receipt,issuedA.body.receipt);
  assert.equal(a.signatures.length,1);assert.equal(b.signatures.length,1);
});

test('locator cannot supply handle, payment, issuer, recipient or admission authority',async t=>{
  const a=await scopedFixture(t),b=await scopedFixture(t),ta=target(a),tb=target(b);
  const r=router(id=>new Map([[a.id,ta],[b.id,tb]]).get(id));
  assert.equal((await call(r,b.id,'begin',a.begin())).status,503);
  assert.equal(b.db.prepare('SELECT count(*) AS n FROM device_licence_challenges').get().n,0);
  for(const field of ['entitlementID','issuerKeyID','issuerPublicKey','ownerEmail','paymentStatus','admitted'])
    assert.equal((await call(r,a.id,'begin',{...a.begin(),[field]:'attacker-value'})).status,400);
  assert.equal(a.signatures.length+b.signatures.length,0);assert.equal(a.sends.length+b.sends.length,0);
  b.state.status='blocked';assert.equal((await call(r,b.id,'begin',b.begin())).status,503);
  assert.equal(b.signatures.length,0);
});

test('wrong-ledger approve fails even with forced identical challenge ID, token, nonce, key and time',async t=>{
  const a=await scopedFixture(t),b=await scopedFixture(t,{device:a.device}),ta=target(a),tb=target(b);
  const r=router(id=>new Map([[a.id,ta],[b.id,tb]]).get(id));
  const inputA=a.begin(),inputB=b.begin(),original=crypto.getRandomValues.bind(crypto);
  const mock=t.mock.method(crypto,'getRandomValues',bytes=>(bytes.length===16||bytes.length===32)?bytes.fill(bytes.length):original(bytes));
  let firstA,firstB;
  try{firstA=await call(r,a.id,'begin',inputA);firstB=await call(r,b.id,'begin',inputB);}finally{mock.mock.restore();}
  assert.equal(firstA.status,200);assert.equal(firstB.status,200);
  assert.equal(firstA.body.challenge.challengeID,firstB.body.challenge.challengeID);
  assert.equal(firstA.body.challenge.nonce,firstB.body.challenge.nonce);
  await ta.alarm();await tb.alarm();
  const proofA=await a.approval(firstA.body.challenge),proofB=await b.approval(firstB.body.challenge);
  assert.equal(proofA.approvalToken,proofB.approvalToken);
  assert.equal((await call(r,b.id,'approve',proofA)).status,503);assert.equal(b.signatures.length,0);
  assert.equal((await call(r,a.id,'approve',proofA)).status,200);
  assert.equal((await call(r,b.id,'approve',proofB)).status,200);
});

test('malformed bodies stay bounded by the existing facade and cannot initialize its ledger',async t=>{
  const f=await scopedFixture(t),ta=target(f),r=router(()=>ta);
  for(const body of ['{}','{"requestID":"a","requestID":"b"}','x'.repeat(2049)]){
    const response=await r.handle(request(f.id,'begin',{}, {body}));assert([400,413].includes(response.status));
  }
  const stalled=new ReadableStream({pull(){return new Promise(()=>{});},cancel(){return new Promise(()=>{});}});
  const pending=r.handle(request(f.id,'begin',{}, {body:stalled,duplex:'half'}));
  assert.equal((await pending).status,408);assert.equal(f.state.sqlCalls,0);assert.equal(f.state.reads,0);
  assert.equal((await call(r,f.id,'begin',f.begin())).status,200);
});

test('capacity is held for unsettled lookup after caller abort and only released on actual settlement',async t=>{
  const f=await scopedFixture(t),ta=target(f),wait=deferred(),entered=deferred();let lookups=0;
  const r=router(async()=>{lookups++;entered.resolve();await wait.promise;return ta;},1),abort=new AbortController();
  const first=r.handle(request(f.id,'begin',f.begin(),{signal:abort.signal}));await entered.promise;abort.abort();await tick();
  const rejected=await call(r,f.id,'begin',f.begin());assert.equal(rejected.status,503);assert.equal(lookups,1);assert.equal(f.state.sqlCalls,0);
  wait.resolve();assert.equal((await first).status,400);
  assert.equal((await call(r,f.id,'begin',f.begin())).status,200);assert.equal(lookups,2);
});

test('capacity holds through an aborted real lifecycle command until trusted authority settles; no rollback claim',async t=>{
  const f=await scopedFixture(t),ta=target(f),wait=deferred(),entered=deferred();
  f.state.readGate=async()=>{entered.resolve();await wait.promise;};const r=router(()=>ta,1),abort=new AbortController();
  const input=f.begin(),first=r.handle(request(f.id,'begin',input,{signal:abort.signal}));await entered.promise;abort.abort();await tick();
  assert.equal((await call(r,f.id,'begin',input)).status,503);
  wait.resolve();const completed=await first;assert.equal(completed.status,200);
  assert.deepEqual((await call(r,f.id,'begin',input)).body,await completed.json());
  assert.equal(f.db.prepare('SELECT count(*) AS n FROM device_licence_challenges').get().n,1);
});

test('lookup rejection releases its slot only on settlement and never exposes the dependency error',async()=>{
  const wait=deferred();const r=router(()=>wait.promise,1),id=randomToken(16),body={};
  const first=r.handle(request(id,'begin',body));await tick();
  assert.equal((await r.handle(request(id,'begin',body))).status,503);
  wait.reject(Error('secret-directory-handle-and-token'));const response=await first;
  assert.deepEqual(await response.json(),{ok:false,code:'temporarily_unavailable'});
  assert.equal((await r.handle(request(id,'begin',body))).status,503);
});
