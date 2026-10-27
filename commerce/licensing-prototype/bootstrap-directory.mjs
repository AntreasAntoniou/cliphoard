// Disabled trusted provisioning directory. No HTTP handler, namespace, secret,
// signer, purchaser authentication, provider client or deployment binding.
import { decode } from './protocol.mjs';
import { identifier, ORDER_REF } from '../src/stripe-security.mjs';

const scopeFields = Object.freeze(['accountId', 'mode', 'orderRef', 'sessionId',
  'productId', 'priceId', 'currency', 'unitAmount', 'taxBehavior']);
class DirectoryError extends Error {
  constructor(code) { super(code); this.name = 'DeviceBootstrapDirectoryError'; this.code = code; }
}
const fail = code => { throw new DirectoryError(code); };
const need = (condition, code) => { if (!condition) fail(code); };
function data(value, fields, code) {
  need(value && typeof value === 'object' && [Object.prototype, null].includes(Object.getPrototypeOf(value)), code);
  const descriptors = Object.getOwnPropertyDescriptors(value);
  need(Reflect.ownKeys(descriptors).length === fields.length
    && fields.every(name => descriptors[name] && Object.hasOwn(descriptors[name], 'value')), code);
  return Object.freeze(Object.fromEntries(fields.map(name => [name, descriptors[name].value])));
}
function canonicalToken(value, bytes, code) {
  try { decode(value, bytes); } catch { fail(code); }
}
function scope(value, code) {
  const pinned = data(value, scopeFields, code);
  need(identifier(pinned.accountId, 'acct') && ['test', 'live'].includes(pinned.mode)
    && typeof pinned.orderRef === 'string' && ORDER_REF.test(pinned.orderRef)
    && identifier(pinned.sessionId, 'cs') && identifier(pinned.productId, 'prod')
    && identifier(pinned.priceId, 'price') && typeof pinned.currency === 'string'
    && /^[a-z]{3}$/.test(pinned.currency) && Number.isSafeInteger(pinned.unitAmount)
    && pinned.unitAmount > 0 && pinned.taxBehavior === 'inclusive', code);
  return pinned;
}
function reservation(value, code) {
  const captured = data(value, ['entitlementID', 'provisioningID', 'scope'], code);
  canonicalToken(captured.entitlementID, 16, code); canonicalToken(captured.provisioningID, 16, code);
  return Object.freeze({ entitlementID: captured.entitlementID, provisioningID: captured.provisioningID,
    scope: scope(captured.scope, code) });
}
function key(value, code) {
  const captured = data(value, ['entitlementID', 'provisioningID'], code);
  canonicalToken(captured.entitlementID, 16, code); canonicalToken(captured.provisioningID, 16, code);
  return captured;
}
function acknowledgement(value, code) {
  const captured = data(value, ['entitlementID', 'provisioningID', 'bindingDigest'], code);
  canonicalToken(captured.entitlementID, 16, code); canonicalToken(captured.provisioningID, 16, code);
  canonicalToken(captured.bindingDigest, 32, code);
  return captured;
}
const disabledCall = async () => fail('directory_disabled');
const disabled = Object.freeze({ reserve: disabledCall, provision: disabledCall,
  lookupReservation: disabledCall, lookupReady: disabledCall });

export function createDeviceBootstrapDirectory(options = {}) {
  let storage, provisionTarget;
  try {
    need(options && typeof options === 'object' && !Array.isArray(options), 'directory_configuration');
    const enabled = Object.getOwnPropertyDescriptor(options, 'enabled');
    if (enabled === undefined) return disabled;
    need(Object.hasOwn(enabled, 'value'), 'directory_configuration');
    if (enabled.value !== true) return disabled;
    const supplied = data(options, ['enabled', 'storage', 'provisionTarget'], 'directory_configuration');
    const rawStorage = data(supplied.storage, ['sql', 'transactionSync', 'sync'], 'directory_configuration');
    const sql = data(rawStorage.sql, ['exec'], 'directory_configuration');
    need(typeof sql.exec === 'function' && typeof rawStorage.transactionSync === 'function'
      && typeof rawStorage.sync === 'function' && typeof supplied.provisionTarget === 'function', 'directory_configuration');
    storage = Object.freeze({ ...rawStorage, sql }); provisionTarget = supplied.provisionTarget;
  } catch { fail('directory_configuration'); }
  const exec = (query, ...values) => Array.from(storage.sql.exec(query, ...values));
  const database = operation => {
    try { return operation(); }
    catch (error) { if (error instanceof DirectoryError) throw error; fail('directory_storage'); }
  };
  const durable = async () => {
    try { await storage.sync(); } catch { fail('directory_unavailable'); }
  };
  function schemaExists() {
    const tables = exec("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('device_bootstrap_directory_meta','device_bootstrap_directory')");
    if (tables.length === 0) return false;
    need(tables.length === 2, 'directory_storage');
    const meta = exec('SELECT singleton,schema_version FROM device_bootstrap_directory_meta');
    need(meta.length === 1 && meta[0].singleton === 1 && meta[0].schema_version === 1, 'directory_storage');
    return true;
  }
  function initialize() {
    if (schemaExists()) return;
    exec(`CREATE TABLE device_bootstrap_directory_meta (
      singleton INTEGER PRIMARY KEY CHECK(singleton=1), schema_version INTEGER NOT NULL)`);
    exec('INSERT INTO device_bootstrap_directory_meta VALUES(1,1)');
    exec(`CREATE TABLE device_bootstrap_directory (
      entitlement_id TEXT PRIMARY KEY, provisioning_id TEXT NOT NULL UNIQUE,
      account_id TEXT NOT NULL, mode TEXT NOT NULL, order_ref TEXT NOT NULL, session_id TEXT NOT NULL,
      reservation_json TEXT NOT NULL, phase TEXT NOT NULL CHECK(phase IN ('pending','ready','conflict')),
      binding_digest TEXT,
      UNIQUE(account_id,mode,order_ref), UNIQUE(account_id,mode,session_id),
      CHECK((phase='pending' AND binding_digest IS NULL) OR (phase IN ('ready','conflict') AND binding_digest IS NOT NULL)))`);
  }
  function decodeRow(row) {
    let pinned;
    try { pinned = reservation(JSON.parse(row.reservation_json), 'directory_storage'); }
    catch { fail('directory_storage'); }
    need(JSON.stringify(pinned) === row.reservation_json
      && pinned.entitlementID === row.entitlement_id && pinned.provisioningID === row.provisioning_id
      && pinned.scope.accountId === row.account_id && pinned.scope.mode === row.mode
      && pinned.scope.orderRef === row.order_ref && pinned.scope.sessionId === row.session_id
      && ['pending', 'ready', 'conflict'].includes(row.phase), 'directory_storage');
    if (row.phase === 'pending') need(row.binding_digest === null, 'directory_storage');
    else canonicalToken(row.binding_digest, 32, 'directory_storage');
    return { pinned, phase: row.phase, bindingDigest: row.binding_digest };
  }
  function byID(id) {
    if (!schemaExists()) return null;
    const rows = exec('SELECT * FROM device_bootstrap_directory WHERE entitlement_id=?', id);
    need(rows.length <= 1, 'directory_storage');
    return rows.length ? decodeRow(rows[0]) : null;
  }
  const ready = row => Object.freeze({ entitlementID: row.pinned.entitlementID,
    provisioningID: row.pinned.provisioningID, bindingDigest: row.bindingDigest });
  function exactKey(row, requested) {
    need(row !== null, 'directory_missing');
    need(row.pinned.entitlementID === requested.entitlementID
      && row.pinned.provisioningID === requested.provisioningID, 'directory_conflict');
    need(row.phase !== 'conflict', 'directory_conflict');
  }

  return Object.freeze({
    // TRUSTED provisioning only. The caller supplies an independently pinned
    // purchase. This reservation does not authenticate it or authorize activation.
    async reserve(...args) {
      need(args.length === 1, 'directory_invalid');
      const pinned = reservation(args[0], 'directory_invalid'), encoded = JSON.stringify(pinned);
      database(() => storage.transactionSync(() => {
        initialize();
        const rows = exec(`SELECT * FROM device_bootstrap_directory WHERE entitlement_id=? OR provisioning_id=?
          OR (account_id=? AND mode=? AND order_ref=?) OR (account_id=? AND mode=? AND session_id=?)`,
        pinned.entitlementID, pinned.provisioningID, pinned.scope.accountId, pinned.scope.mode, pinned.scope.orderRef,
        pinned.scope.accountId, pinned.scope.mode, pinned.scope.sessionId);
        need(rows.length <= 1, 'directory_conflict');
        if (rows.length) {
          const existing = decodeRow(rows[0]);
          need(JSON.stringify(existing.pinned) === encoded, 'directory_conflict');
          return;
        }
        exec(`INSERT INTO device_bootstrap_directory VALUES(?,?,?,?,?,?,?,'pending',NULL)`, pinned.entitlementID,
          pinned.provisioningID, pinned.scope.accountId, pinned.scope.mode, pinned.scope.orderRef, pinned.scope.sessionId, encoded);
      }));
      await durable();
      const observed = database(() => byID(pinned.entitlementID));
      need(observed && JSON.stringify(observed.pinned) === encoded, 'directory_storage');
      return observed.pinned;
    },
    // TRUSTED recovery of a reservation after a lost response. Never regenerates
    // IDs, changes purchase scope or returns bootstrap/activation secrets.
    async lookupReservation(...args) {
      need(args.length === 1, 'directory_invalid');
      const pinnedScope = scope(args[0], 'directory_invalid');
      const read = () => database(() => {
        if (!schemaExists()) return null;
        const rows = exec('SELECT * FROM device_bootstrap_directory WHERE account_id=? AND mode=? AND order_ref=?',
          pinnedScope.accountId, pinnedScope.mode, pinnedScope.orderRef);
        need(rows.length <= 1, 'directory_storage');
        if (!rows.length) return null;
        const row = decodeRow(rows[0]);
        need(JSON.stringify(row.pinned.scope) === JSON.stringify(pinnedScope), 'directory_conflict');
        return row.pinned;
      });
      if (read() === null) return null;
      await durable(); return read();
    },
    // The target commits its own immutable bootstrap/binding transaction first.
    // The second transaction below publishes routing readiness only. A crash
    // between them leaves a retryable pending row, never an atomic cross-DO claim.
    async provision(...args) {
      need(args.length === 1, 'directory_invalid');
      const requested = key(args[0], 'directory_invalid');
      const before = database(() => byID(requested.entitlementID)); exactKey(before, requested);
      await durable();
      let result;
      try { result = acknowledgement(await provisionTarget(before.pinned), 'directory_unavailable'); }
      catch { fail('directory_unavailable'); }
      const conflict = database(() => storage.transactionSync(() => {
        const current = byID(requested.entitlementID); exactKey(current, requested);
        const identityMatches = result.entitlementID === requested.entitlementID && result.provisioningID === requested.provisioningID;
        if (!identityMatches || (current.phase === 'ready' && current.bindingDigest !== result.bindingDigest)) {
          if (current.phase === 'ready') exec("UPDATE device_bootstrap_directory SET phase='conflict' WHERE entitlement_id=?", requested.entitlementID);
          return true;
        }
        if (current.phase === 'pending') exec("UPDATE device_bootstrap_directory SET phase='ready',binding_digest=? WHERE entitlement_id=?",
          result.bindingDigest, requested.entitlementID);
        return false;
      }));
      await durable();
      if (conflict) fail('directory_conflict');
      const after = database(() => byID(requested.entitlementID)); exactKey(after, requested);
      need(after.phase === 'ready' && after.bindingDigest === result.bindingDigest, 'directory_conflict');
      return ready(after);
    },
    // Public routing may use only this lookup capability. A miss performs reads
    // only, including before the first trusted reservation created any tables.
    async lookupReady(...args) {
      need(args.length === 1, 'directory_invalid'); canonicalToken(args[0], 16, 'directory_invalid');
      const before = database(() => byID(args[0]));
      if (!before || before.phase !== 'ready') return null;
      await durable();
      const after = database(() => byID(args[0]));
      return after?.phase === 'ready' ? ready(after) : null;
    },
  });
}
