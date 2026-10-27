// DISABLED adapter: no environment/binding lookup, Worker export or production sender.
import { decode, epoch, verifyReceiptSignature } from './protocol.mjs';

class MailError extends Error {
  constructor(code) { super(code); this.name = 'DeviceMailError'; this.code = code; }
}
const fail = code => { throw new MailError(code); };
const require = (condition, code) => { if (!condition) fail(code); };
function dataRecord(value, keys) {
  require(value && typeof value === 'object'
    && [Object.prototype, null].includes(Object.getPrototypeOf(value)), 'delivery_rejected');
  const descriptors = Object.getOwnPropertyDescriptors(value), actual = Reflect.ownKeys(descriptors);
  require(actual.length === keys.length && keys.every(key => descriptors[key]
    && Object.hasOwn(descriptors[key], 'value')), 'delivery_rejected');
  return Object.fromEntries(keys.map(key => [key, descriptors[key].value]));
}
function address(value) {
  // One bare mailbox only; never a display name, list, header or structured address.
  return typeof value === 'string' && value.length <= 254
    && /^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/.test(value);
}
const disabled = Object.freeze({
  async deliverApproval() { fail('delivery_disabled'); },
  async deliverReceipt() { fail('delivery_disabled'); },
  hasUnsettledSend: () => false,
});

export function createNativeMailDelivery(options = {}) {
  // Do not traverse any dependency when the explicit own-data switch is absent/off.
  if (Object.getOwnPropertyDescriptor(options, 'enabled')?.value !== true) return disabled;
  let entitlementID, trust, from, replyTo, send, timeoutMilliseconds, setTimer, clearTimer;
  try {
    const descriptors = Object.getOwnPropertyDescriptors(options);
    const required = ['enabled', 'entitlementID', 'trustedIssuers', 'from', 'replyTo', 'send', 'timeoutMilliseconds'];
    const allowed = [...required, 'setTimer', 'clearTimer'];
    require(Reflect.ownKeys(descriptors).every(key => allowed.includes(key))
      && required.every(key => descriptors[key])
      && Object.values(descriptors).every(value => Object.hasOwn(value, 'value')), 'delivery_configuration');
    const value = Object.fromEntries(Object.entries(descriptors).map(([key, entry]) => [key, entry.value]));
    ({ entitlementID, from, replyTo, send, timeoutMilliseconds } = value);
    decode(entitlementID, 16);
    require(address(from) && address(replyTo) && typeof send === 'function'
      && Number.isSafeInteger(timeoutMilliseconds) && timeoutMilliseconds > 0
      && timeoutMilliseconds <= 60000, 'delivery_configuration');
    trust = new Map(Map.prototype.entries.call(value.trustedIssuers));
    require(trust.size > 0 && trust.size <= 8, 'delivery_configuration');
    for (const [id, key] of trust) {
      require(typeof id === 'string' && /^[a-z0-9][a-z0-9_-]{0,31}$/.test(id), 'delivery_configuration');
      require(decode(key, 65)[0] === 4, 'delivery_configuration');
    }
    setTimer = value.setTimer ?? setTimeout; clearTimer = value.clearTimer ?? clearTimeout;
    require(typeof setTimer === 'function' && typeof clearTimer === 'function', 'delivery_configuration');
  } catch { fail('delivery_configuration'); }

  let unsettled = false;
  function context(raw, kind) {
    try {
      const value = dataRecord(raw, ['to', 'deliveryID', 'challengeID', 'entitlementID',
        'entitlementRevision', 'deviceKeyHash', 'authorizeDispatch', ...(kind === 'approval' ? ['token', 'expiresAt'] : ['receipt'])]);
      require(address(value.to) && value.entitlementID === entitlementID
        && Number.isSafeInteger(value.entitlementRevision) && value.entitlementRevision > 0
        && typeof value.authorizeDispatch === 'function', 'delivery_rejected');
      decode(value.challengeID, 16); decode(value.deviceKeyHash, 32);
      require(value.deliveryID === `${value.challengeID}.${kind}`, 'delivery_rejected');
      if (kind === 'approval') { decode(value.token, 32); epoch(value.expiresAt); }
      // Receipt parsing/signature checking happens in the bounded operation below.
      return Object.freeze(value);
    } catch { fail('delivery_rejected'); }
  }
  async function deliver(raw, kind) {
    if (unsettled) fail('delivery_busy');
    const value = context(raw, kind);
    unsettled = true;
    let expired = false, timer;
    const work = Promise.resolve().then(async () => {
      let text, subject;
      if (kind === 'approval') {
        subject = 'Approve this Mac for Cliphoard Pro';
        text = `A Mac requested approval for your Cliphoard Pro purchase.\n\nApproval code:\n${value.token}\n\nEnter this code in the approval panel on the same Mac that requested it. It expires at ${new Date(value.expiresAt * 1000).toISOString()}. The code alone cannot approve a different Mac.\n\nYour purchase covers your personally owned Macs, with email approval for each new Mac and no fixed device cap. Once approved, that Mac can keep using its saved approval offline indefinitely.\n\nIf you did not request this, ignore this email. No approval occurs by opening this message. Keep this code private. The Mac App Store edition uses its separate purchase.`;
      } else {
        const receipt = await verifyReceiptSignature(value.receipt, trust);
        require(receipt.fields.entitlementID === entitlementID
          && receipt.fields.deviceKeyHash === value.deviceKeyHash, 'delivery_unavailable');
        subject = 'Your Mac approval for Cliphoard Pro';
        text = `Your requesting Mac has been approved for Cliphoard Pro.\n\nKeep this complete approval receipt:\n${value.receipt}\n\nIf the approval was not saved in the app, paste this receipt into the approval panel's recovery field on the same Mac. Recovery checks that Mac's existing identity; this receipt cannot approve a different Mac.\n\nApproved Macs can use their saved approval offline indefinitely. Your purchase covers your personally owned Macs with email approval for each new Mac and no fixed device cap. Keep this receipt private. The Mac App Store edition uses its separate purchase.`;
      }
      require(!expired, 'delivery_unavailable');
      const message = Object.freeze({ from, to: value.to, replyTo, subject, text });
      // This private capability rechecks the exact lease and same-database authority
      // after WebCrypto. No await may separate this check from the native send call.
      require(value.authorizeDispatch() === undefined, 'delivery_unavailable');
      const native = send(message);
      const result = dataRecord(await native, ['messageId']);
      require(typeof result.messageId === 'string' && result.messageId.length > 0
        && result.messageId.length < 256 && !/[\x00-\x1f\x7f]/.test(result.messageId), 'delivery_unavailable');
      return Object.freeze({ accepted: true });
    });
    // A caller deadline is not cancellation. Retain the slot until actual settlement,
    // and consume both late resolutions/rejections without mutating any ledger state.
    const settled = work.then(value => { unsettled = false; return value; }, () => {
      unsettled = false; fail('delivery_unavailable');
    });
    const deadline = new Promise((_, reject) => {
      try { timer = setTimer(() => { expired = true; reject(new MailError('delivery_timeout')); }, timeoutMilliseconds); }
      catch { expired = true; reject(new MailError('delivery_unavailable')); }
    });
    try { return await Promise.race([settled, deadline]); }
    finally { try { clearTimer(timer); } catch { /* Never expose injected cleanup/provider errors. */ } }
  }
  return Object.freeze({
    deliverApproval: value => deliver(value, 'approval'),
    deliverReceipt: value => deliver(value, 'receipt'),
    hasUnsettledSend: () => unsettled,
  });
}
