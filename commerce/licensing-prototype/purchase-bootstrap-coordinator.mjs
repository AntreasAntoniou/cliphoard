// Disabled trusted backend seam. No route, provider client, ledger, key or sender.
import { decode } from './protocol.mjs';
import { identifier, ORDER_REF } from '../src/stripe-security.mjs';

const scopeFields = ['accountId', 'mode', 'orderRef', 'sessionId', 'productId', 'priceId',
  'currency', 'unitAmount', 'taxBehavior'];
class CoordinatorError extends Error {
  constructor(code) { super(code); this.name = 'PurchaseBootstrapCoordinatorError'; this.code = code; }
}
const fail = code => { throw new CoordinatorError(code); };
const need = (condition, code) => { if (!condition) fail(code); };
function data(value, fields, code) {
  need(value && typeof value === 'object' && [Object.prototype, null].includes(Object.getPrototypeOf(value)), code);
  const descriptors = Object.getOwnPropertyDescriptors(value);
  need(Reflect.ownKeys(descriptors).length === fields.length
    && fields.every(name => descriptors[name] && Object.hasOwn(descriptors[name], 'value')), code);
  return Object.freeze(Object.fromEntries(fields.map(name => [name, descriptors[name].value])));
}
function scope(value, code) {
  const captured = data(value, scopeFields, code);
  need(identifier(captured.accountId, 'acct') && ['test', 'live'].includes(captured.mode)
    && typeof captured.orderRef === 'string' && ORDER_REF.test(captured.orderRef)
    && identifier(captured.sessionId, 'cs') && identifier(captured.productId, 'prod')
    && identifier(captured.priceId, 'price') && typeof captured.currency === 'string'
    && /^[a-z]{3}$/.test(captured.currency) && Number.isSafeInteger(captured.unitAmount)
    && captured.unitAmount > 0 && captured.taxBehavior === 'inclusive', code);
  return captured;
}
function token(value, bytes, code) { try { decode(value, bytes); } catch { fail(code); } }
const disabled = Object.freeze({ process: async () => fail('coordinator_disabled') });

export function createPurchaseBootstrapCoordinator(options = {}) {
  let pinned, inspect, directory, resolveTarget, allocateEntitlementID, allocateProvisioningID;
  try {
    need(options && typeof options === 'object' && !Array.isArray(options), 'coordinator_configuration');
    const enabled = Object.getOwnPropertyDescriptor(options, 'enabled');
    if (enabled === undefined) return disabled;
    need(Object.hasOwn(enabled, 'value'), 'coordinator_configuration');
    if (enabled.value !== true) return disabled;
    const supplied = data(options, ['enabled', 'scope', 'inspectDeviceAuthority', 'directory',
      'resolveTarget', 'allocateEntitlementID', 'allocateProvisioningID'], 'coordinator_configuration');
    pinned = scope(supplied.scope, 'coordinator_configuration');
    directory = data(supplied.directory, ['reserve', 'lookupReservation', 'provision', 'lookupReady'], 'coordinator_configuration');
    inspect = supplied.inspectDeviceAuthority; resolveTarget = supplied.resolveTarget;
    allocateEntitlementID = supplied.allocateEntitlementID; allocateProvisioningID = supplied.allocateProvisioningID;
    need([inspect, resolveTarget, allocateEntitlementID, allocateProvisioningID, ...Object.values(directory)]
      .every(value => typeof value === 'function'), 'coordinator_configuration');
  } catch { fail('coordinator_configuration'); }

  // These are only per-instance operation guards, never a second durable ledger.
  let inFlight, reserveUncertain = false;
  const matchesScope = observed => need(scopeFields.every(name => observed[name] === pinned[name]), 'coordinator_scope_mismatch');
  function reservation(value) {
    const captured = data(value, ['entitlementID', 'provisioningID', 'scope'], 'coordinator_directory_unavailable');
    token(captured.entitlementID, 16, 'coordinator_directory_unavailable');
    token(captured.provisioningID, 16, 'coordinator_directory_unavailable');
    const purchase = scope(captured.scope, 'coordinator_directory_unavailable'); matchesScope(purchase);
    return Object.freeze({ entitlementID: captured.entitlementID, provisioningID: captured.provisioningID, scope: purchase });
  }
  function acknowledgement(value, original) {
    const captured = data(value, ['entitlementID', 'provisioningID', 'bindingDigest'], 'coordinator_directory_unavailable');
    token(captured.bindingDigest, 32, 'coordinator_directory_unavailable');
    need(captured.entitlementID === original.entitlementID && captured.provisioningID === original.provisioningID,
      'coordinator_directory_unavailable');
    return captured;
  }
  async function active() {
    let fact;
    try { fact = data(await inspect(), [...scopeFields, 'state', 'ownerEmail'], 'coordinator_authority_unavailable'); }
    catch { fail('coordinator_authority_unavailable'); }
    matchesScope(fact);
    need(['active', 'pending', 'blocked'].includes(fact.state), 'coordinator_authority_unavailable');
    if (fact.state !== 'active') {
      need(fact.ownerEmail === null, 'coordinator_authority_unavailable'); fail('coordinator_ineligible');
    }
    need(typeof fact.ownerEmail === 'string' && fact.ownerEmail.length <= 254
      && /^[^\s@<>\r\n]+@[^\s@<>\r\n]+\.[^\s@<>\r\n]+$/.test(fact.ownerEmail), 'coordinator_authority_unavailable');
    return fact.ownerEmail;
  }
  async function lookup() {
    let value;
    try { value = await directory.lookupReservation(pinned); }
    catch { fail('coordinator_directory_unavailable'); }
    if (value === null) return null;
    const result = reservation(value); reserveUncertain = false; return result;
  }
  async function allocation() {
    const existing = await lookup();
    if (existing !== null) return existing;
    // A previous uncertain dispatch is not a new genuine-miss authorization.
    need(!reserveUncertain, 'coordinator_directory_unavailable');
    let candidate;
    try {
      const entitlementID = await allocateEntitlementID(), provisioningID = await allocateProvisioningID();
      token(entitlementID, 16, 'coordinator_allocation_unavailable'); token(provisioningID, 16, 'coordinator_allocation_unavailable');
      candidate = Object.freeze({ entitlementID, provisioningID, scope: pinned });
    } catch { fail('coordinator_allocation_unavailable'); }
    reserveUncertain = true;
    try {
      const result = reservation(await directory.reserve(candidate));
      need(result.entitlementID === candidate.entitlementID && result.provisioningID === candidate.provisioningID,
        'coordinator_directory_unavailable');
      reserveUncertain = false; return result;
    } catch {
      // Conflict or lost acknowledgement: only recover the actual original scope.
      const recovered = await lookup();
      need(recovered !== null, 'coordinator_directory_unavailable'); return recovered;
    }
  }
  async function ready(original) {
    const key = Object.freeze({ entitlementID: original.entitlementID, provisioningID: original.provisioningID });
    try { return acknowledgement(await directory.provision(key), original); }
    catch {
      let observed;
      try { observed = await directory.lookupReady(original.entitlementID); }
      catch { fail('coordinator_directory_unavailable'); }
      // Null is pending/conflict, not authority to allocate or assume readiness.
      need(observed !== null, 'coordinator_directory_unavailable');
      return acknowledgement(observed, original);
    }
  }
  async function run() {
    const purchaser = await active();
    const original = await allocation(), ack = await ready(original);
    let target;
    try {
      target = data(await resolveTarget(ack), ['entitlementID', 'provisioningID', 'bindingDigest', 'requestIssue'], 'coordinator_target_mismatch');
      need(target.entitlementID === ack.entitlementID && target.provisioningID === ack.provisioningID
        && target.bindingDigest === ack.bindingDigest && typeof target.requestIssue === 'function', 'coordinator_target_mismatch');
    } catch { fail('coordinator_target_mismatch'); }
    need(await active() === purchaser, 'coordinator_purchaser_mismatch');
    let issued;
    try {
      // The trusted resolver must select the actual service; its own fresh
      // payment/purchaser fences remain essential after this coordinator read.
      issued = data(await target.requestIssue(), ['ok', 'code'], 'coordinator_issue_unavailable');
      need(issued.ok === true && ['issued', 'already_issued'].includes(issued.code), 'coordinator_issue_unavailable');
    } catch { fail('coordinator_issue_unavailable'); }
    return Object.freeze({ ...ack, ...issued });
  }
  return Object.freeze({ process(...args) {
    if (args.length !== 0) return Promise.reject(new CoordinatorError('coordinator_rejected'));
    if (inFlight) return inFlight;
    const work = Promise.resolve().then(run).finally(() => { if (inFlight === work) inFlight = undefined; });
    inFlight = work; return work;
  } });
}
