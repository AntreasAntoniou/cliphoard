// DISABLED adapter: no production factory, route, Stripe client, key or mail sender.
import { ProtocolError, need, decode, tokenDigest, sameTokenHash, digest, epoch, canonicalDevice,
  receiptPayload, base64url, verifyReceiptSignature } from './protocol.mjs';
import { identifier, ORDER_REF } from '../src/stripe-security.mjs';

const scopeFields = Object.freeze(['accountId', 'mode', 'orderRef', 'sessionId',
  'productId', 'priceId', 'currency', 'unitAmount', 'taxBehavior']);
const bindingFields = Object.freeze(['entitlementID', 'entitlementHandleDigest', ...scopeFields]);
const factFields = Object.freeze([...scopeFields, 'state', 'ownerEmail']);
const receiptFields = Object.freeze(['issuerKeyID', 'entitlementID', 'deviceKeyHash', 'receiptID', 'issuedAt']);
const encoder = new TextEncoder();
const fail = code => { throw new ProtocolError(code); };

// Copy only exact own data properties. Do not invoke getters while validating a
// dependency result, and do not serialize arbitrary dependency objects.
function ownData(value, fields, code) {
  need(value && typeof value === 'object' && !Array.isArray(value)
    && [Object.prototype, null].includes(Object.getPrototypeOf(value)), code);
  const descriptors = Object.getOwnPropertyDescriptors(value);
  const keys = Reflect.ownKeys(descriptors);
  need(keys.length === fields.length && keys.every(key => typeof key === 'string'
    && fields.includes(key) && 'value' in descriptors[key]), code);
  return Object.fromEntries(fields.map(key => [key, descriptors[key].value]));
}
function enabledOptions(options, fields) {
  need(options && typeof options === 'object' && !Array.isArray(options), 'configuration');
  // Read only the own opt-in descriptor first. Missing/inherited opt-ins leave
  // the factory disabled; no dependency value or getter is evaluated.
  const enabled = Object.getOwnPropertyDescriptor(options, 'enabled');
  if (enabled === undefined) return null;
  need('value' in enabled, 'configuration');
  if (enabled.value !== true) return null;
  return ownData(options, ['enabled', ...fields], 'configuration');
}
function configuration(binding) {
  const value = ownData(binding, bindingFields, 'configuration');
  try { decode(value.entitlementID, 16); decode(value.entitlementHandleDigest, 32); }
  catch { fail('configuration'); }
  need(identifier(value.accountId, 'acct') && ['test', 'live'].includes(value.mode)
    && typeof value.orderRef === 'string' && ORDER_REF.test(value.orderRef)
    && identifier(value.sessionId, 'cs') && identifier(value.productId, 'prod')
    && identifier(value.priceId, 'price') && typeof value.currency === 'string'
    && /^[a-z]{3}$/.test(value.currency) && Number.isSafeInteger(value.unitAmount)
    && value.unitAmount > 0 && value.taxBehavior === 'inclusive', 'configuration');
  return Object.freeze(value);
}
function disabledAuthority() {
  const disabled = async () => fail('prototype_disabled');
  return Object.freeze({ resolveEntitlement: disabled, readEntitlement: disabled,
    refreshAuthority: disabled, admission: disabled,
    readAuthorityFence: () => fail('prototype_disabled') });
}

/** One trusted order/session and one activation ledger, sharing the SAME SQLite
 * storage/transaction boundary. The read callback must be the explicitly enabled
 * orderService.inspectDeviceAuthority capability, never a request body/feed. */
export function createStripeDeviceAuthority(options = {}) {
  const supplied = enabledOptions(options, ['storage', 'binding', 'inspectDeviceAuthority', 'admission']);
  if (supplied === null) return disabledAuthority();
  const { storage, binding, inspectDeviceAuthority, admission: admissionAuthority } = supplied;
  const pinned = configuration(binding);
  need(typeof storage?.sql?.exec === 'function' && typeof storage.transactionSync === 'function'
    && typeof storage.sync === 'function' && typeof inspectDeviceAuthority === 'function'
    && typeof admissionAuthority === 'function', 'configuration');
  const bindingJSON = JSON.stringify(pinned);
  const exec = (query, ...args) => Array.from(storage.sql.exec(query, ...args));
  const tx = callback => storage.transactionSync(callback);
  const row = () => {
    const rows = exec('SELECT * FROM device_licence_stripe_authority');
    need(rows.length === 1, 'storage_scope_mismatch');
    const current = rows[0];
    need(current.singleton === 1 && current.schema_version === 1 && current.binding_json === bindingJSON
      && Number.isSafeInteger(current.revision) && current.revision >= 0
      && ['unknown', 'pending', 'active', 'blocked'].includes(current.status)
      && ((current.revision === 0) === (current.status === 'unknown'))
      && (current.purchaser_hash === null || (typeof current.purchaser_hash === 'string'
        && /^[A-Za-z0-9_-]{43}$/.test(current.purchaser_hash)))
      && (current.status !== 'active' || current.purchaser_hash !== null), 'storage_scope_mismatch');
    return current;
  };
  try {
    tx(() => {
      exec(`CREATE TABLE IF NOT EXISTS device_licence_stripe_authority (
        singleton INTEGER PRIMARY KEY CHECK(singleton=1), schema_version INTEGER NOT NULL,
        binding_json TEXT NOT NULL, revision INTEGER NOT NULL, status TEXT NOT NULL,
        purchaser_hash TEXT)`);
      if (exec('SELECT singleton FROM device_licence_stripe_authority').length === 0)
        exec(`INSERT INTO device_licence_stripe_authority VALUES(1,1,?,0,'unknown',NULL)`, bindingJSON);
      row();
    });
  } catch { fail('storage_scope_mismatch'); }
  const fence = current => ({ id: pinned.entitlementID, revision: current.revision, status: current.status });
  function readAuthorityFence() {
    try { return fence(row()); }
    catch { fail('authority_unavailable'); }
  }
  function observe(state, purchaserHash) {
    const current = row();
    // Only local committed transitions create revisions. Stripe event timestamps
    // and arrival order have no authority here. A terminal block always wins.
    if (current.status === 'blocked') return current;
    if (purchaserHash !== null && current.purchaser_hash !== null
      && purchaserHash !== current.purchaser_hash) state = 'blocked';
    const owner = current.purchaser_hash ?? (state === 'active' ? purchaserHash : null);
    if (current.status === state && current.purchaser_hash === owner) return current;
    need(current.revision < Number.MAX_SAFE_INTEGER, 'authority_unavailable');
    exec('UPDATE device_licence_stripe_authority SET revision=?,status=?,purchaser_hash=? WHERE singleton=1',
      current.revision + 1, state, owner);
    return row();
  }
  async function inspectAndObserve() {
    let raw;
    try { raw = await inspectDeviceAuthority(); }
    catch { fail('authority_unavailable'); }
    let fact, state, purchaserHash = null;
    try {
      fact = ownData(raw, factFields, 'authority_unavailable');
      // A verified result for another purchase cannot be quietly rebound.
      if (scopeFields.some(field => fact[field] !== pinned[field])) state = 'blocked';
      else {
        need(['active', 'pending', 'blocked'].includes(fact.state), 'authority_unavailable');
        state = fact.state;
        if (state === 'active') {
          need(typeof fact.ownerEmail === 'string' && fact.ownerEmail.length <= 254
            && /^[^\s@<>\r\n]+@[^\s@<>\r\n]+\.[^\s@<>\r\n]+$/.test(fact.ownerEmail), 'authority_unavailable');
          purchaserHash = await digest(encoder.encode(`cliphoard.stripe-purchaser\n1\n${fact.ownerEmail}`));
        } else need(fact.ownerEmail === null, 'authority_unavailable');
      }
      const observed = tx(() => observe(state, purchaserHash));
      await storage.sync();
      // Another operation can commit a terminal block during durability wait.
      const current = row();
      return { current, observed, ownerEmail: fact.ownerEmail };
    } catch { fail('authority_unavailable'); }
  }
  async function activeEntitlement() {
    const { current, observed, ownerEmail } = await inspectAndObserve();
    need(current.status === 'active' && observed.status === 'active'
      && current.revision === observed.revision, 'entitlement_ineligible');
    return { id: pinned.entitlementID, revision: current.revision, status: 'active', product: 'pro', ownerEmail };
  }
  return Object.freeze({
    readAuthorityFence,
    async refreshAuthority(...args) {
      need(args.length === 0, 'authority_scope_mismatch');
      return { ...fence((await inspectAndObserve()).current), product: 'pro' };
    },
    async resolveEntitlement(handle) {
      let hash;
      try { hash = await tokenDigest(handle); }
      catch { fail('entitlement_ineligible'); }
      need(sameTokenHash(hash, pinned.entitlementHandleDigest), 'entitlement_ineligible');
      return activeEntitlement();
    },
    async readEntitlement(id) {
      need(id === pinned.entitlementID, 'authority_scope_mismatch');
      return activeEntitlement();
    },
    async admission(input) {
      const value = ownData(input, ['phase', 'entitlementID', 'deviceKeyHash', 'now'], 'authority_scope_mismatch');
      need(value.entitlementID === pinned.entitlementID
        && ['begin', 'approve', 'approve_commit'].includes(value.phase), 'authority_scope_mismatch');
      try { decode(value.deviceKeyHash, 32); epoch(value.now); }
      catch { fail('authority_scope_mismatch'); }
      const before = readAuthorityFence();
      need(before.status === 'active', 'entitlement_ineligible');
      let decision;
      try {
        decision = ownData(await admissionAuthority({ ...value }), ['revision', 'decision'], 'admission_unavailable');
        need(Number.isSafeInteger(decision.revision) && decision.revision > 0
          && ['allow', 'hold'].includes(decision.decision), 'admission_unavailable');
      } catch { fail('admission_unavailable'); }
      const after = readAuthorityFence();
      need(after.status === 'active' && after.revision === before.revision, 'entitlement_ineligible');
      return decision;
    },
  });
}

/** A separately selected P-256 issuer capability. No CLIP1 key/seed is accepted,
 * loaded, converted or reused; no real issuer/key-management policy is selected. */
export function createPinnedDeviceReceiptIssuer(options = {}) {
  const supplied = enabledOptions(options, ['entitlementID', 'issuerKeyID', 'issuerPublicKey', 'sign']);
  if (supplied === null) return async () => fail('prototype_disabled');
  const { entitlementID, issuerKeyID, issuerPublicKey, sign } = supplied;
  try {
    decode(entitlementID, 16);
    const publicBytes = decode(issuerPublicKey, 65);
    need(publicBytes[0] === 4 && typeof issuerKeyID === 'string'
      && /^[a-z0-9][a-z0-9_-]{0,31}$/.test(issuerKeyID) && typeof sign === 'function', 'configuration');
  } catch { fail('configuration'); }
  const trust = new Map([[issuerKeyID, issuerPublicKey]]);
  return async function issueReceipt(input) {
    let fields, expectedPayload;
    try {
      fields = ownData(input, receiptFields, 'signer_mismatch');
      need(fields.issuerKeyID === issuerKeyID && fields.entitlementID === entitlementID, 'signer_mismatch');
      expectedPayload = base64url(receiptPayload(fields));
    } catch { fail('signer_mismatch'); }
    // Import/validate the pinned curve point before invoking any signing service.
    try { await canonicalDevice(issuerPublicKey); }
    catch { fail('configuration'); }
    let receipt;
    try { receipt = await sign({ ...fields }); }
    catch { fail('signer_unavailable'); }
    try {
      const verified = await verifyReceiptSignature(receipt, trust);
      need(base64url(verified.payload) === expectedPayload, 'signer_mismatch');
      return receipt;
    } catch { fail('signer_mismatch'); }
  };
}
