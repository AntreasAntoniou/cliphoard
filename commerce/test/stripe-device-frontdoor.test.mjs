import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {fixture,wireOrders} from './stripe-fixtures.mjs';
import {purchasePage} from '../src/stripe-frontdoor.mjs';
async function setup() { const f=await fixture();wireOrders(f);f.env.STRIPE_API_KEY='rk_test_synthetic0123456789012345';f.env.CANCEL_URL=f.env.PUBLIC_ORIGIN+'/?cancelled=1';return f; }
test('legacy default pages retain exact pre-change HTML',async()=>{
  const f=await setup();
  for(const [path,hash] of [['/','dd74bd7ec9960860364b6c9246e659624383d1eb21ae522328933a787fbcab38'],['/?cancelled=1','e6ec7c2829d1f228737dd5afeb94b77d589ee4c4d3857fdfc16bdd3fdfbf4508']]){
    const html=await (await purchasePage(f.env,new URL(f.env.PUBLIC_ORIGIN+path))).text();
    assert.equal(createHash('sha256').update(html).digest('hex'),hash);
  }
});
test('configured device page uses readiness without accessing legacy signer',async()=>{
  const f=await setup();f.env.DEVICE_FULFILMENT_ENABLED='true';let reads=0,calls=0;
  Object.defineProperty(f.env,'CLIPHOARD_SIGNING_SEED',{get(){reads++;throw Error('legacy seed forbidden');}});
  const r=await purchasePage(f.env,new URL(f.env.CANCEL_URL),{deviceFulfilment:{enabled:true,readiness:async()=>{calls++;return true;}}});
  const html=await r.text();assert.equal(reads,0);assert.equal(calls,1);assert.ok(html.includes('id="checkout"'));
  for(const text of ['Approve each new Mac by email','All the Macs you own','setup instructions','Pro works offline after approval'])assert.ok(html.includes(text),text);
  assert.ok(!html.includes('One offline key'));assert.ok(!html.includes('This key does not'));
});
test('device configuration and readiness must explicitly agree; no legacy fallback',async()=>{
  for(const kind of ['no-flag','no-capability','false','throw']){
    const f=await setup();let seed=0;Object.defineProperty(f.env,'CLIPHOARD_SIGNING_SEED',{get(){seed++;throw Error('forbidden');}});
    if(kind!=='no-flag') f.env.DEVICE_FULFILMENT_ENABLED='true';
    const options=kind==='no-capability'?undefined:{deviceFulfilment:{enabled:true,readiness:async()=>{if(kind==='throw')throw Error('private');return kind!=='false';}}};
    const html=await (await purchasePage(f.env,new URL(f.env.PUBLIC_ORIGIN),options)).text();
    assert.ok(!html.includes('id="checkout"'),kind);assert.equal(seed,0);assert.ok(!html.includes('private'));
  }
});
test('configuration getters are not invoked and readiness callback is captured',async()=>{
  const f=await setup();f.env.DEVICE_FULFILMENT_ENABLED='true';let getters=0;
  const malformed={get deviceFulfilment(){getters++;throw Error('getter');}};
  const html=await (await purchasePage(f.env,new URL(f.env.PUBLIC_ORIGIN),malformed)).text();
  assert.equal(getters,0);assert.ok(!html.includes('id="checkout"'));
  let calls=0;const capability={enabled:true,readiness:async()=>{calls++;return true;}};
  const pending=purchasePage(f.env,new URL(f.env.PUBLIC_ORIGIN),{deviceFulfilment:capability});
  capability.readiness=()=>{throw Error('replacement');};
  assert.ok((await (await pending).text()).includes('id="checkout"'));assert.equal(calls,1);
});
test('device page retains all payment delivery switches',async()=>{
  for(const field of ['CHECKOUT_ENABLED','ISSUANCE_ENABLED','DELIVERY_ENABLED','EMAIL_DELIVERY_ENABLED']){
    const f=await setup();f.env.DEVICE_FULFILMENT_ENABLED='true';f.env[field]='false';let calls=0;
    const html=await (await purchasePage(f.env,new URL(f.env.PUBLIC_ORIGIN),{deviceFulfilment:{enabled:true,readiness:async()=>{calls++;return true;}}})).text();
    assert.ok(!html.includes('id="checkout"'),field);assert.equal(calls,0);
  }
});
