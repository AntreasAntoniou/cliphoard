// Opt-in order-owned durable wake queue. No default Worker, route or provider binding.
import { identifier, ORDER_REF } from './stripe-security.mjs';

const KEY = 'cliphoard_device_feed_v1';
const fields = ['accountId','mode','orderRef','sessionId','productId','priceId','currency','unitAmount','taxBehavior'];
const fail = code => { throw new Error(code); };
const need = (ok,code) => { if (!ok) fail(code); };
function data(value, names, code) {
  need(value && [Object.prototype,null].includes(Object.getPrototypeOf(value)),code);
  const d=Object.getOwnPropertyDescriptors(value);
  need(Reflect.ownKeys(d).length===names.length && names.every(k=>d[k] && Object.hasOwn(d[k],'value')),code);
  return Object.fromEntries(names.map(k=>[k,d[k].value]));
}
function captureScope(value) {
  const s=data(value,fields,'feed_configuration');
  need(identifier(s.accountId,'acct') && ['test','live'].includes(s.mode) && typeof s.orderRef==='string' && ORDER_REF.test(s.orderRef)
    && identifier(s.sessionId,'cs') && identifier(s.productId,'prod') && identifier(s.priceId,'price')
    && typeof s.currency==='string' && /^[a-z]{3}$/.test(s.currency) && Number.isSafeInteger(s.unitAmount)
    && s.unitAmount>0 && s.taxBehavior==='inclusive','feed_configuration');
  return Object.freeze(s);
}
const disabled=Object.freeze({wake:async()=>fail('feed_disabled'),drain:async()=>fail('feed_disabled')});

/** Construct only inside the original order host. wake() carries no payment fact:
 * it follows authenticated purchase/refund processing and durably requests a fresh
 * original orderService.inspectDeviceAuthority read. Remote calls must run outside
 * the order host serial gate, because the directory can call that host back. */
export function createStripeDeviceFeed(options={}) {
  const enabled=Object.getOwnPropertyDescriptor(options,'enabled');
  if (!enabled) return disabled;
  need(Object.hasOwn(enabled,'value'),'feed_configuration');
  if (enabled.value!==true) return disabled;
  const o=data(options,['enabled','scope','storage','now','retrySeconds','schedule','inspectDeviceAuthority','processPurchase','refreshPurchase'],'feed_configuration');
  const scope=captureScope(o.scope), scopeJSON=JSON.stringify(scope),storage=o.storage;
  need(storage && ['get','put','transaction','sync'].every(k=>typeof storage[k]==='function')
    && ['now','schedule','inspectDeviceAuthority','processPurchase','refreshPurchase'].every(k=>typeof o[k]==='function')
    && Number.isSafeInteger(o.retrySeconds) && o.retrySeconds>0,'feed_configuration');
  // Capture trusted host methods once. No operational retry value is defaulted here.
  const get=storage.get.bind(storage),put=storage.put.bind(storage),transaction=storage.transaction.bind(storage),sync=storage.sync.bind(storage);
  function validate(raw,optional=false) {
    if (raw===undefined && optional) return null;
    const row=data(raw,['version','scope','revision','pending'],'feed_storage_unavailable');
    need(row.version===1 && row.scope===scopeJSON && Number.isSafeInteger(row.revision) && row.revision>0
      && typeof row.pending==='boolean','feed_storage_unavailable');
    return row;
  }
  async function read() {
    try { return validate(await get(KEY),true); } catch { fail('feed_storage_unavailable'); }
  }
  async function schedule() {
    try {
      const now=o.now();need(Number.isSafeInteger(now) && now>=0 && Number.isSafeInteger(now+o.retrySeconds),'feed_schedule_unavailable');
      await o.schedule(now+o.retrySeconds);
    } catch { fail('feed_schedule_unavailable'); }
  }
  async function wake(...args) {
    need(args.length===0,'feed_arguments');
    try {
      await transaction(async tx=>{
        const old=validate(await tx.get(KEY),true),revision=(old?.revision??0)+1;
        need(Number.isSafeInteger(revision),'feed_storage_unavailable');
        await tx.put(KEY,{version:1,scope:scopeJSON,revision,pending:true});
      });
      await sync();
    } catch { fail('feed_storage_unavailable'); }
    await schedule();return true;
  }
  async function run() {
    const row=await read();if (!row?.pending) return false;
    // Arm BEFORE provider/remote work. A lost acknowledgement preserves this row.
    await schedule();
    let fact;
    try {
      fact=data(await o.inspectDeviceAuthority(),[...fields,'state','ownerEmail'],'feed_authority_unavailable');
      need(fields.every(k=>fact[k]===scope[k]) && ['active','pending','blocked'].includes(fact.state),'feed_authority_unavailable');
      if (fact.state==='active') need(typeof fact.ownerEmail==='string' && fact.ownerEmail.length<=254
        && /^[^\s@<>\r\n]+@[^\s@<>\r\n]+\.[^\s@<>\r\n]+$/.test(fact.ownerEmail),'feed_authority_unavailable');
      else need(fact.ownerEmail===null,'feed_authority_unavailable');
    } catch { fail('feed_authority_unavailable'); }
    try {
      const callback=fact.state==='active'?o.processPurchase:o.refreshPurchase;
      fact=null;
      // Host adapters acknowledge only after their existing directory operation
      // succeeds; inactive refresh must be lookup-only and may find no reservation.
      need(await callback(scope)===true,'feed_delivery_unavailable');
    } catch { fail('feed_delivery_unavailable'); }
    try {
      await transaction(async tx=>{
        const current=validate(await tx.get(KEY));
        if (current.revision===row.revision) await tx.put(KEY,{...current,pending:false});
      });
      await sync();
    } catch { fail('feed_storage_unavailable'); }
    return true;
  }
  let inFlight;
  function drain(...args) {
    if(args.length) return Promise.reject(new Error('feed_arguments'));
    if(inFlight) return inFlight;
    const promise=Promise.resolve().then(run);inFlight=promise;
    promise.then(()=>{if(inFlight===promise)inFlight=undefined;},()=>{if(inFlight===promise)inFlight=undefined;});
    return promise;
  }
  return Object.freeze({wake,drain});
}
