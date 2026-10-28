// Explicit customer action only; no GET/preview sends and no provisioning.
import {ORDER_REF,TOKEN,need,response,failure} from './stripe-security.mjs';
import {decode} from '../licensing-prototype/protocol.mjs';
function data(v,names){need(v&&[Object.prototype,null].includes(Object.getPrototypeOf(v)),400,'invalid_request');const d=Object.getOwnPropertyDescriptors(v);need(Reflect.ownKeys(d).length===names.length&&names.every(k=>d[k]&&Object.hasOwn(d[k],'value')),400,'invalid_request');return Object.fromEntries(names.map(k=>[k,d[k].value]));}
async function read(request,ms){
 need(request.body&&!request.body.locked,400,'invalid_request');const reader=request.body.getReader();let timer,size=0;const chunks=[];
 try {
  return await Promise.race([(async()=>{for(;;){const {done,value}=await reader.read();if(done)break;size+=value.length;need(size<=512,413,'body_too_large');chunks.push(value);}const bytes=new Uint8Array(size);let offset=0;for(const c of chunks){bytes.set(c,offset);offset+=c.length;}try{return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));}catch{need(false,400,'invalid_request');}})(),new Promise((_,reject)=>{timer=setTimeout(()=>{reject(Error('body_timeout'));void reader.cancel().catch(()=>{});},ms);})]);
 }finally{clearTimeout(timer);void reader.cancel().catch(()=>{});try{reader.releaseLock();}catch{}}
}
export function createDeviceSetupRecoveryRoute(options={}){
 const flag=Object.getOwnPropertyDescriptor(options,'enabled');if(!flag)return Object.freeze({handle:async()=>response(404,'not_found')});need(Object.hasOwn(flag,'value'),503,'recovery_configuration');if(flag.value!==true)return Object.freeze({handle:async()=>response(404,'not_found')});
 const o=data(options,['enabled','origin','bodyTimeoutMilliseconds','admit','requestRecovery']);const url=new URL(o.origin);need(url.protocol==='https:'&&url.origin===o.origin&&Number.isSafeInteger(o.bodyTimeoutMilliseconds)&&o.bodyTimeoutMilliseconds>0&&o.bodyTimeoutMilliseconds<=30000&&typeof o.admit==='function'&&typeof o.requestRecovery==='function',503,'recovery_configuration');
 return Object.freeze({async handle(request){try{
  need(request instanceof Request&&!request.signal.aborted,400,'invalid_request');const u=new URL(request.url);
  need(u.origin===o.origin&&u.pathname==='/pro/recover'&&!u.search&&!u.hash,404,'not_found');need(request.method==='POST',405,'method_not_allowed');need(request.headers.get('Origin')===o.origin&&['same-origin',null].includes(request.headers.get('Sec-Fetch-Site')),403,'origin_mismatch');need(/^application\/json(?:\s*;|$)/i.test(request.headers.get('Content-Type')??'')&&!request.headers.get('Content-Encoding'),415,'json_required');
  const v=data(await read(request,o.bodyTimeoutMilliseconds),['orderRef','token','requestID']);need(typeof v.orderRef==='string'&&ORDER_REF.test(v.orderRef)&&typeof v.token==='string'&&TOKEN.test(v.token),400,'invalid_request');decode(v.requestID,16);
  need(await o.admit(request,v.orderRef)===true&&!request.signal.aborted,429,'try_later');
  const ack=data(await o.requestRecovery(Object.freeze(v)),['ok','code']);need(ack.ok===true&&ack.code==='delivery_requested',503,'recovery_unavailable');return response(202,'delivery_requested');
 }catch(e){return failure(e);}}});
}
