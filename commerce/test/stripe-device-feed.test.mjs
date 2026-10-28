import test from 'node:test';
import assert from 'node:assert/strict';
import { createStripeDeviceFeed } from '../src/stripe-device-feed.mjs';
import { fixture } from './stripe-fixtures.mjs';
import { orderService } from '../src/stripe-order.mjs';

const scope = Object.freeze({ accountId: 'acct_Test', mode: 'test', orderRef: '12345678-1234-4234-8234-123456789abc',
  sessionId: 'cs_test_Test', productId: 'prod_Test', priceId: 'price_Test', currency: 'gbp', unitAmount: 1000, taxBehavior: 'inclusive' });
function storage() {
  const data = new Map(); let tail = Promise.resolve();
  const s = { get: async k => structuredClone(data.get(k)), put: async (k,v) => data.set(k,structuredClone(v)),
    sync: async () => {}, transaction(fn) { const p=tail.then(()=>fn(s)); tail=p.catch(()=>{}); return p; }, data };
  return s;
}
function setup(overrides={}) {
  const events=[], db=storage(); let state='active';
  const options={ enabled:true, scope, storage:db, now:()=>1000, retrySeconds:60,
    schedule:async at=>events.push(['schedule',at]),
    inspectDeviceAuthority:async()=>{events.push(['inspect']); return {...scope,state,ownerEmail:state==='active'?'owned@example.invalid':null};},
    processPurchase:async s=>{events.push(['process',s]);return true;},
    refreshPurchase:async s=>{events.push(['refresh',s]);return true;}, ...overrides };
  return {options,events,db,setState:s=>state=s,make:()=>createStripeDeviceFeed(options)};
}
test('disabled feed touches no dependencies and rejects supplied arguments',async()=>{
  let calls=0; const o={enabled:false}; Object.defineProperty(o,'storage',{get(){calls++;throw Error();}});
  await assert.rejects(createStripeDeviceFeed(o).wake(),/feed_disabled/); assert.equal(calls,0);
  const f=setup(),feed=f.make(); await assert.rejects(feed.wake({state:'active'}),/feed_arguments/); assert.equal(f.db.data.size,0);
});
test('wake persists before scheduling; reconstruction drains exact original scope',async()=>{
  const f=setup(); await f.make().wake(); assert.equal(f.db.data.size,1);
  assert.equal(await f.make().drain(),true); assert.deepEqual(f.events.map(e=>e[0]),['schedule','schedule','inspect','process']);
  const bytes=JSON.stringify([...f.db.data]); assert.ok(!bytes.includes('owned@'));
  assert.equal(await f.make().drain(),false); assert.equal(f.events.length,4);
});
test('lost acknowledgement remains pending and retry uses same scope',async()=>{
  let calls=0; const f=setup({processPurchase:async s=>{assert.deepEqual(s,scope); if(++calls===1)throw Error('private');return true;}});
  await f.make().wake(); await assert.rejects(f.make().drain(),e=>e.message==='feed_delivery_unavailable');
  assert.equal(await f.make().drain(),true); assert.equal(calls,2);
});
test('refund after a paid wake routes lookup-only refresh from fresh authority',async()=>{
  const f=setup(); await f.make().wake(); f.setState('blocked'); await f.make().drain();
  assert.deepEqual(f.events.map(e=>e[0]),['schedule','schedule','inspect','refresh']);
});
test('wake arriving during remote work cannot be acknowledged by older drain',async()=>{
  let release,entered; const enteredPromise=new Promise(r=>entered=r), wait=new Promise(r=>release=r);
  const f=setup({processPurchase:async()=>{entered();await wait;return true;}}),feed=f.make();
  await feed.wake(); const run=feed.drain(); await enteredPromise; await feed.wake(); release(); await run;
  f.setState('blocked'); await feed.drain(); assert.equal(f.events.filter(e=>e[0]==='refresh').length,1);
});
test('coalesced drains and synchronous reentry perform one authority read',async()=>{
  let feed,reads=0,reentered; const f=setup({inspectDeviceAuthority:async()=>{reads++;reentered=feed.drain();return {...scope,state:'active',ownerEmail:'a@b.invalid'};}});
  feed=f.make();await feed.wake();await Promise.all([feed.drain(),feed.drain()]);await reentered;assert.equal(reads,1);
});
test('wrong scope and getter-bearing authority never dispatch; corrupt stored state fails closed',async()=>{
  for(const kind of ['scope','getter']) {
    let getters=0;const f=setup({inspectDeviceAuthority:async()=>{const v={...scope,state:'active',ownerEmail:'a@b.invalid'};if(kind==='scope')v.priceId='price_Wrong';else Object.defineProperty(v,'state',{get(){getters++;return 'active';},enumerable:true});return v;}});
    await f.make().wake();await assert.rejects(f.make().drain(),/feed_authority_unavailable/);assert.equal(getters,0);assert.ok(!f.events.some(e=>['process','refresh'].includes(e[0])));
  }
  const f=setup();await f.make().wake(); const [key,row]=[...f.db.data][0];row.revision=-1;f.db.data.set(key,row);await assert.rejects(f.make().drain(),/feed_storage_unavailable/);
});
test('schedule failure leaves durable work and never invokes remote work',async()=>{
  const f=setup({schedule:async()=>{throw Error('secret');}});await assert.rejects(f.make().wake(),/feed_schedule_unavailable/);assert.equal(f.db.data.size,1);
  await assert.rejects(f.make().drain(),/feed_schedule_unavailable/);assert.equal(f.events.length,0);
});
test('actual existing order authority detects provider refund before feed dispatch',async()=>{
  const f=await fixture();await f.service().start(f.ref);f.stripe.pay();await f.service().paid(f.ref,f.stripe.s.id);
  const bound={accountId:f.env.STRIPE_ACCOUNT_ID,mode:'test',orderRef:f.ref,sessionId:f.stripe.s.id,productId:f.env.STRIPE_PRODUCT_ID,
    priceId:f.env.STRIPE_PRICE_ID,currency:'gbp',unitAmount:1000,taxBehavior:'inclusive'};
  const authority=orderService({...f,deviceAuthority:{enabled:true,orderRef:f.ref,sessionId:f.stripe.s.id}});
  let issued=0,refreshed=0;const x=setup({scope:bound,inspectDeviceAuthority:()=>authority.inspectDeviceAuthority(),processPurchase:async()=>{issued++;return true;},refreshPurchase:async()=>{refreshed++;return true;}});
  await x.make().wake();f.stripe.refundRows=[{id:'re_Test'}];await x.make().drain();assert.equal(issued,0);assert.equal(refreshed,1);
});
