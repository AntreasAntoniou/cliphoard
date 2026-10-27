// Disabled bootstrap-only mail boundary. No provider, environment, route or keys.
import {
  decode,
  digest
} from './protocol.mjs';
import {
  parseBootstrap,
  verifyBootstrap
} from './bootstrap-protocol.mjs';

class MailError extends Error {
  constructor(code) {
    super(code);
    this.code = code;
    this.name = 'BootstrapMailError';
  }
}
const fail = code => {
  throw new MailError(code);
};
const need = value => {
  if (!value)
    fail('bootstrap_mail_configuration');
};
function data(value, keys) {
  need(value && typeof value === 'object' && [
    Object.prototype,
    null
  ].includes(Object.getPrototypeOf(value)));
  const ds = Object.getOwnPropertyDescriptors(value);
  need(Reflect.ownKeys(ds).length === keys.length && keys.every(key => ds[key] && Object.hasOwn(ds[key], 'value')));
  return Object.freeze(Object.fromEntries(keys.map(key => [
    key,
    ds[key].value
  ])));
}
const address = value => typeof value === 'string' && value.length <= 254 && /^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/.test(value);
const disabled = Object.freeze({
  deliverBootstrap: async () => fail('bootstrap_mail_disabled'),
  hasUnsettledSend: () => false
});

export function createDeviceBootstrapMail(options = {}) {
  let pin, trust, from, replyTo, send, timeout;
  try {
    need(options && typeof options === 'object' && !Array.isArray(options));
    const enabled = Object.getOwnPropertyDescriptor(options, 'enabled');
    if (!enabled)
      return disabled;
    need(Object.hasOwn(enabled, 'value'));
    if (enabled.value !== true)
      return disabled;
    const v = data(options, [
      'enabled',
      'entitlementID',
      'trust',
      'from',
      'replyTo',
      'send',
      'timeoutMilliseconds'
    ]);
    ({
      entitlementID: pin,
      from,
      replyTo,
      send,
      timeoutMilliseconds: timeout
    } = v);
    decode(pin, 16);
    need(address(from) && address(replyTo) && typeof send === 'function' && Number.isSafeInteger(timeout) && timeout > 0 && timeout <= 60000);
    const p = data(v.trust, [
      'expectedProfileID',
      'bootstrapKeyID',
      'bootstrapPublicKey',
      'receiptIssuerKeyIDs'
    ]);
    need(Array.isArray(p.receiptIssuerKeyIDs) && Object.getPrototypeOf(p.receiptIssuerKeyIDs) === Array.prototype);
    const ds = Object.getOwnPropertyDescriptors(p.receiptIssuerKeyIDs), n = ds.length.value;
    need(n > 0 && Reflect.ownKeys(ds).length === n + 1);
    const ids = [];
    for (let i = 0; i < n; i++) {
      need(ds[i] && Object.hasOwn(ds[i], 'value'));
      ids.push(ds[i].value);
    }
    need([
      p.expectedProfileID,
      p.bootstrapKeyID,
      ...ids
    ].every(x => typeof x === 'string' && /^[a-z0-9][a-z0-9_-]{0,31}$/.test(x)) && new Set(ids).size === ids.length);
    need(decode(p.bootstrapPublicKey, 65)[0] === 4);
    trust = Object.freeze({
      ...p,
      receiptIssuerKeyIDs: Object.freeze(ids)
    });
  } catch {
    fail('bootstrap_mail_configuration');
  }
  let unsettled = false;
  return Object.freeze({
    hasUnsettledSend: () => unsettled,
    async deliverBootstrap(raw) {
      if (unsettled)
        fail('bootstrap_mail_busy');
      let v;
      try {
        v = data(raw, [
          'to',
          'deliveryID',
          'entitlementID',
          'envelope',
          'payloadHash',
          'authorizeDispatch'
        ]);
        need(address(v.to) && v.entitlementID === pin && typeof v.deliveryID === 'string' && /^[A-Za-z0-9_-]{22}\.(?:initial|[A-Za-z0-9_-]{22})$/.test(v.deliveryID));
        decode(v.payloadHash, 32);
        need(typeof v.authorizeDispatch === 'function');
      } catch {
        fail('bootstrap_mail_rejected');
      }
      unsettled = true;
      let expired = false, timer;
      const work = Promise.resolve().then(async () => {
        const fields = await verifyBootstrap(v.envelope, trust), parsed = parseBootstrap(v.envelope);
        need(fields.entitlementID === pin && await digest(parsed.payload) === v.payloadHash && !expired);
        const message = Object.freeze({
          from,
          to: v.to,
          replyTo,
          subject: 'Set up Cliphoard Pro on your Macs',
          text: `Your private Cliphoard setup descriptor:\n${ v.envelope }\n\nImport this descriptor in the direct-download Cliphoard setup panel. Each new Mac still requires approval by email. This descriptor alone does not approve a Mac or unlock Pro. Keep it private. The Mac App Store edition uses its separate purchase.`
        });
        need(!expired && v.authorizeDispatch() === undefined);
        // Nothing asynchronous may separate the final authority/lease fence and send.
        const native = send(Object.freeze({
          deliveryID: v.deliveryID,
          message
        }));
        const accepted = data(await native, ['messageId']);
        need(typeof accepted.messageId === 'string' && accepted.messageId.length > 0 && accepted.messageId.length < 256 && !/[\x00-\x1f\x7f]/.test(accepted.messageId));
        return Object.freeze({ accepted: true });
      });
      const settled = work.then(result => {
        unsettled = false;
        return result;
      }, () => {
        unsettled = false;
        fail('bootstrap_mail_unavailable');
      });
      const deadline = new Promise((_, reject) => {
        timer = setTimeout(() => {
          expired = true;
          reject(new MailError('bootstrap_mail_timeout'));
        }, timeout);
      });
      try {
        return await Promise.race([
          settled,
          deadline
        ]);
      } finally {
        clearTimeout(timer);
      }
    }
  });
}
