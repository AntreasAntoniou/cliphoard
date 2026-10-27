// DISABLED private composition. No Worker export, environment lookup, production
// routing, provider client, issuer key, custody implementation or scheduler default.
import { decode } from './protocol.mjs';
import { identifier, ORDER_REF } from '../src/stripe-security.mjs';
import { createStripeDeviceAuthority, createPinnedDeviceReceiptIssuer } from './stripe-authority.mjs';
import { createSqliteActivationService } from './sqlite-service.mjs';
import { createNativeMailDelivery } from './native-mail.mjs';
import { createDeliveryRunner } from './delivery-runner.mjs';
import { createActivationHttpHandler } from './http-adapter.mjs';

class LifecycleError extends Error {
  constructor(code) { super(code); this.name = 'DeviceLicenceLifecycleError'; this.code = code; }
}
const fail = code => { throw new LifecycleError(code); };
const need = condition => { if (!condition) fail('lifecycle_configuration'); };
function data(value, fields) {
  need(value && typeof value === 'object' && [Object.prototype, null].includes(Object.getPrototypeOf(value)));
  const descriptors = Object.getOwnPropertyDescriptors(value);
  need(Reflect.ownKeys(descriptors).length === fields.length
    && fields.every(key => descriptors[key] && Object.hasOwn(descriptors[key], 'value')));
  return Object.freeze(Object.fromEntries(fields.map(key => [key, descriptors[key].value])));
}
function functions(value, fields) {
  const captured = data(value, fields);
  need(Object.values(captured).every(method => typeof method === 'function'));
  return captured;
}
const disabledCall = async () => fail('lifecycle_disabled');
const disabled = Object.freeze({ handle: createActivationHttpHandler(), alarm: disabledCall,
  recover: disabledCall, refreshAuthority: disabledCall, refreshAdmission: disabledCall });

export function createDeviceLicenceServerLifecycle(options = {}) {
  let value, storage, binding, issuer, custody, admission, mailOptions, alarmStorage,
    clocks, limits, operational, http, issueReceipt, mail;
  try {
    need(options && typeof options === 'object' && !Array.isArray(options));
    // An inherited switch cannot enable this facade. A getter is rejected without
    // invoking it; disabled construction never examines dependency descriptors.
    const enabled = Object.getOwnPropertyDescriptor(options, 'enabled');
    if (enabled === undefined) return disabled;
    need(Object.hasOwn(enabled, 'value'));
    if (enabled.value !== true) return disabled;
    value = data(options, ['enabled', 'storage', 'binding', 'inspectDeviceAuthority', 'issuer',
      'tokenCustody', 'admission', 'mail', 'alarmStorage', 'clocks', 'limits', 'operational', 'http']);
    const suppliedStorage = data(value.storage, ['sql', 'transactionSync', 'sync']);
    need(typeof suppliedStorage.transactionSync === 'function' && typeof suppliedStorage.sync === 'function');
    storage = Object.freeze({ ...suppliedStorage, sql: functions(suppliedStorage.sql, ['exec']) });
    binding = data(value.binding, ['entitlementID', 'entitlementHandleDigest', 'accountId', 'mode',
      'orderRef', 'sessionId', 'productId', 'priceId', 'currency', 'unitAmount', 'taxBehavior']);
    decode(binding.entitlementID, 16); decode(binding.entitlementHandleDigest, 32);
    need(identifier(binding.accountId, 'acct') && ['test', 'live'].includes(binding.mode)
      && typeof binding.orderRef === 'string' && ORDER_REF.test(binding.orderRef)
      && identifier(binding.sessionId, 'cs') && identifier(binding.productId, 'prod')
      && identifier(binding.priceId, 'price') && typeof binding.currency === 'string'
      && /^[a-z]{3}$/.test(binding.currency) && Number.isSafeInteger(binding.unitAmount)
      && binding.unitAmount > 0 && binding.taxBehavior === 'inclusive'
      && typeof value.inspectDeviceAuthority === 'function');
    issuer = data(value.issuer, ['issuerKeyID', 'issuerPublicKey', 'sign']);
    custody = functions(value.tokenCustody, ['sealToken', 'openToken']);
    admission = functions(value.admission, ['evaluate', 'readCurrent']);
    mailOptions = data(value.mail, ['from', 'replyTo', 'send', 'timeoutMilliseconds']);
    alarmStorage = functions(value.alarmStorage, ['getAlarm', 'setAlarm', 'deleteAlarm', 'sync']);
    clocks = functions(value.clocks, ['epochMilliseconds', 'monotonicMilliseconds']);
    limits = data(value.limits, ['challengeTTLSeconds', 'deliveryLeaseSeconds']);
    need(Object.values(limits).every(number => Number.isSafeInteger(number) && number > 0 && number <= 1800));
    operational = data(value.operational, ['maximumAttemptsPerInvocation', 'maxPendingOperations',
      'invocationBudgetMilliseconds', 'prearmDelayMilliseconds', 'retryDelayMilliseconds', 'continuationDelayMilliseconds']);
    http = data(value.http, ['origin', 'bodyTimeoutMs']);
    // These constructors validate/capture values only. Neither invokes a key,
    // sender, SQL capability, timer or provider. The ledger remains lazy below.
    issueReceipt = createPinnedDeviceReceiptIssuer({ enabled: true, entitlementID: binding.entitlementID, ...issuer });
    mail = createNativeMailDelivery({ enabled: true, entitlementID: binding.entitlementID,
      trustedIssuers: new Map([[issuer.issuerKeyID, issuer.issuerPublicKey]]), ...mailOptions });
  } catch { fail('lifecycle_configuration'); }

  let components, runner, handler;
  function ensure() {
    if (!components) {
      const authority = createStripeDeviceAuthority({ enabled: true, storage, binding,
        inspectDeviceAuthority: value.inspectDeviceAuthority, admission: admission.evaluate });
      const service = createSqliteActivationService({ storage, entitlementID: binding.entitlementID,
        issuerKeyID: issuer.issuerKeyID, issuerPublicKey: issuer.issuerPublicKey, issueReceipt,
        resolveEntitlement: handle => withTerminalFeed(() => authority.resolveEntitlement(handle)),
        readEntitlement: id => withTerminalFeed(() => authority.readEntitlement(id)),
        sealToken: custody.sealToken, openToken: custody.openToken,
        deliverApproval: mail.deliverApproval, deliverReceipt: mail.deliverReceipt,
        admission: authority.admission, readAuthorityFence: authority.readAuthorityFence,
        clock: () => Math.floor(clocks.epochMilliseconds() / 1000), ...limits });
      components = Object.freeze({ authority, service });
    }
    return components;
  }
  async function publishTerminal() {
    const fence = components?.authority.readAuthorityFence();
    if (fence?.status === 'blocked')
      await runner.observeEntitlement({ ...fence, product: 'pro' });
  }
  async function withTerminalFeed(operation) {
    // An authoritative read can commit a terminal block and then reject the
    // active-entitlement request. Publish that committed fence even on rejection.
    try { return await operation(); }
    finally { await publishTerminal(); }
  }
  async function refreshAuthority() {
    const authority = ensure().authority;
    const fact = await withTerminalFeed(() => authority.refreshAuthority());
    if (fact.status === 'active') await runner.observeEntitlement(fact);
    else if (fact.status !== 'blocked') fail('lifecycle_unavailable');
    // Pending/unknown are not terminal and cannot authorize cached active work.
  }
  async function refreshAdmission() {
    const fact = data(await admission.readCurrent(), ['entitlementID', 'revision', 'decision']);
    if (fact.entitlementID !== binding.entitlementID || !Number.isSafeInteger(fact.revision)
      || fact.revision < 1 || !['allow', 'hold'].includes(fact.decision)) fail('lifecycle_unavailable');
    await runner.observeAdmission(fact);
  }
  async function refreshFeeds() {
    // Independent feeds publish as soon as each completes. A paused/failed
    // admission source cannot prevent a committed terminal authority publication.
    const results = await Promise.allSettled([refreshAuthority(), refreshAdmission()]);
    if (results.some(result => result.status === 'rejected')) fail('lifecycle_unavailable');
  }
  try {
    runner = createDeliveryRunner({ enabled: true, makeService: () => ensure().service, alarmStorage,
      mail: { hasUnsettledSend: mail.hasUnsettledSend }, clockMilliseconds: clocks.epochMilliseconds,
      monotonicMilliseconds: clocks.monotonicMilliseconds, operational, refreshFeeds,
      // Only this same-storage monotonic terminal projection can remove a
      // command-owned prearm. Holds and unavailable/pending reads are not terminal.
      isTerminalAuthority: () => components?.authority.readAuthorityFence().status === 'blocked' });
    handler = createActivationHttpHandler({ enabled: true, service: Object.freeze({
      begin: runner.begin, approve: runner.approve }), entitlementID: binding.entitlementID, ...http });
  } catch { fail('lifecycle_configuration'); }
  function trusted(operation, code) {
    return async (...args) => {
      if (args.length !== 0) fail('lifecycle_rejected');
      try {
        const result = await operation();
        return code ? Object.freeze({ ok: true, code }) : result;
      } catch { fail('lifecycle_unavailable'); }
    };
  }
  return Object.freeze({ handle: handler,
    alarm: trusted(runner.alarm), recover: trusted(runner.recover),
    refreshAuthority: trusted(refreshAuthority, 'authority_refreshed'),
    refreshAdmission: trusted(refreshAdmission, 'admission_refreshed') });
}
