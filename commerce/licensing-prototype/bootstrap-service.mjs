// Disabled per-entitlement issuance/custody/outbox seam. No route or production defaults.
import {
  base64url,
  decode,
  digest,
  epoch,
  randomToken,
  tokenDigest,
  canonicalDevice,
  PROTOCOL
} from './protocol.mjs';
import {
  bootstrapPayload,
  parseBootstrap,
  verifyBootstrap,
  createDeviceBootstrapIssuer
} from './bootstrap-protocol.mjs';
import { createStripeDeviceAuthority } from './stripe-authority.mjs';
import {
  identifier,
  ORDER_REF
} from '../src/stripe-security.mjs';

class ServiceError extends Error {
  constructor(code) {
    super(code);
    this.code = code;
    this.name = 'BootstrapServiceError';
  }
}
const fail = code => {
  throw new ServiceError(code);
};
const need = (value, code = 'bootstrap_configuration') => {
  if (!value)
    fail(code);
};
const encoder = new TextEncoder(), decoder = new TextDecoder('utf-8', { fatal: true });
const scopeKeys = [
  'accountId',
  'mode',
  'orderRef',
  'sessionId',
  'productId',
  'priceId',
  'currency',
  'unitAmount',
  'taxBehavior'
];
const selectionKeys = [
  'profileID',
  'bootstrapKeyID',
  'bootstrapPublicKey',
  'receiptIssuerKeyID',
  'receiptIssuerPublicKey'
];
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
function methods(value, keys) {
  const v = data(value, keys);
  need(Object.values(v).every(x => typeof x === 'function'));
  return v;
}
const disabledCall = async () => fail('bootstrap_disabled');
const disabled = Object.freeze(Object.fromEntries([
  'provision',
  'requestIssue',
  'requestRecovery',
  'refreshAuthority',
  'recover',
  'alarm',
  'readActivationBinding',
  'snapshot'
].map(name => [
  name,
  disabledCall
])));

export function createDeviceBootstrapService(options = {}) {
  let storage, reservation, selection, sign, custody, inspect, delivery, wake, clocks, policy, configJSON;
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
      'storage',
      'reservation',
      'selection',
      'signer',
      'custody',
      'inspectDeviceAuthority',
      'delivery',
      'alarmStorage',
      'clocks',
      'operational'
    ]);
    const s = data(v.storage, [
      'sql',
      'transactionSync',
      'sync'
    ]);
    need(typeof s.transactionSync === 'function' && typeof s.sync === 'function');
    storage = Object.freeze({
      ...s,
      sql: methods(s.sql, ['exec'])
    });
    const r = data(v.reservation, [
        'entitlementID',
        'provisioningID',
        'scope'
      ]), scope = data(r.scope, scopeKeys);
    decode(r.entitlementID, 16);
    decode(r.provisioningID, 16);
    need(identifier(scope.accountId, 'acct') && [
      'test',
      'live'
    ].includes(scope.mode) && typeof scope.orderRef === 'string' && ORDER_REF.test(scope.orderRef) && identifier(scope.sessionId, 'cs') && identifier(scope.productId, 'prod') && identifier(scope.priceId, 'price') && typeof scope.currency === 'string' && /^[a-z]{3}$/.test(scope.currency) && Number.isSafeInteger(scope.unitAmount) && scope.unitAmount > 0 && scope.taxBehavior === 'inclusive');
    reservation = Object.freeze({
      ...r,
      scope
    });
    selection = data(v.selection, selectionKeys);
    need([
      selection.profileID,
      selection.bootstrapKeyID,
      selection.receiptIssuerKeyID
    ].every(x => typeof x === 'string' && /^[a-z0-9][a-z0-9_-]{0,31}$/.test(x)));
    need(decode(selection.bootstrapPublicKey, 65)[0] === 4 && decode(selection.receiptIssuerPublicKey, 65)[0] === 4);
    sign = methods(v.signer, ['sign']).sign;
    custody = data(v.custody, [
      'keyID',
      'seal',
      'open'
    ]);
    need(typeof custody.keyID === 'string' && /^[a-z0-9][a-z0-9_-]{0,31}$/.test(custody.keyID) && typeof custody.seal === 'function' && typeof custody.open === 'function');
    inspect = v.inspectDeviceAuthority;
    need(typeof inspect === 'function');
    delivery = methods(v.delivery, [
      'deliverBootstrap',
      'hasUnsettledSend'
    ]);
    wake = methods(v.alarmStorage, [
      'getAlarm',
      'setAlarm',
      'deleteAlarm',
      'sync'
    ]);
    clocks = methods(v.clocks, [
      'epochMilliseconds',
      'monotonicMilliseconds'
    ]);
    policy = data(v.operational, [
      'maxPendingOperations',
      'maximumAttemptsPerInvocation',
      'invocationBudgetMilliseconds',
      'prearmDelayMilliseconds',
      'retryDelayMilliseconds',
      'continuationDelayMilliseconds',
      'deliveryLeaseSeconds'
    ]);
    need(Object.values(policy).every(x => Number.isSafeInteger(x) && x > 0) && policy.maxPendingOperations <= 64 && policy.maximumAttemptsPerInvocation <= 100 && policy.invocationBudgetMilliseconds <= 60000 && policy.deliveryLeaseSeconds <= 1800 && [
      policy.prearmDelayMilliseconds,
      policy.retryDelayMilliseconds,
      policy.continuationDelayMilliseconds
    ].every(x => x <= 86400000));
    configJSON = JSON.stringify({
      reservation,
      selection,
      custodyKeyID: custody.keyID
    });
  } catch {
    fail('bootstrap_configuration');
  }
  const exec = (sql, ...args) => Array.from(storage.sql.exec(sql, ...args)), tx = fn => storage.transactionSync(fn);
  const millis = () => {
    const n = clocks.epochMilliseconds();
    need(Number.isSafeInteger(n) && n > 0 && n <= PROTOCOL.maxEpoch * 1000, 'bootstrap_unavailable');
    return n;
  };
  const now = () => epoch(Math.floor(millis() / 1000));
  const elapsed = () => {
    const n = clocks.monotonicMilliseconds();
    need(Number.isFinite(n) && n >= 0, 'bootstrap_unavailable');
    return n;
  };
  const alarmTime = n => {
    need(n === null || Number.isSafeInteger(n) && n > 0 && n <= PROTOCOL.maxEpoch * 1000, 'bootstrap_unavailable');
    return n;
  };
  const trust = Object.freeze({
    expectedProfileID: selection.profileID,
    bootstrapKeyID: selection.bootstrapKeyID,
    bootstrapPublicKey: selection.bootstrapPublicKey,
    receiptIssuerKeyIDs: Object.freeze([selection.receiptIssuerKeyID])
  });
  let initialized = false, authority, pending = 0, tail = Promise.resolve(), wakeTail = Promise.resolve(), alarmOperation;
  function schema() {
    if (initialized)
      return;
    tx(() => {
      exec(`CREATE TABLE IF NOT EXISTS device_bootstrap_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1),schema_version INTEGER NOT NULL,config_json TEXT NOT NULL,binding_digest TEXT NOT NULL,handle_digest TEXT NOT NULL,issued_at INTEGER NOT NULL,payload_hash TEXT NOT NULL,sealed_payload TEXT NOT NULL,envelope_hash TEXT,sealed_envelope TEXT,issue_requested INTEGER NOT NULL,status TEXT NOT NULL)`);
      exec(`CREATE TABLE IF NOT EXISTS device_bootstrap_outbox(id TEXT PRIMARY KEY,request_id TEXT NOT NULL UNIQUE,status TEXT NOT NULL,lease_id TEXT,lease_until INTEGER,attempts INTEGER NOT NULL DEFAULT 0,outcome TEXT NOT NULL DEFAULT 'not_attempted')`);
      exec(`CREATE TABLE IF NOT EXISTS device_bootstrap_attempts(lease_id TEXT PRIMARY KEY,outbox_id TEXT NOT NULL,started_at INTEGER NOT NULL,finished_at INTEGER,outcome TEXT NOT NULL)`);
    });
    initialized = true;
  }
  function row(optional = false) {
    schema();
    const rows = exec('SELECT * FROM device_bootstrap_state');
    if (optional && rows.length === 0)
      return null;
    need(rows.length === 1, 'bootstrap_storage_mismatch');
    const r = rows[0];
    need(r.singleton === 1 && r.schema_version === 1 && r.config_json === configJSON && [
      'allocated',
      'issued',
      'blocked'
    ].includes(r.status) && [
      0,
      1
    ].includes(r.issue_requested), 'bootstrap_storage_mismatch');
    decode(r.binding_digest, 32);
    decode(r.handle_digest, 32);
    decode(r.payload_hash, 32);
    epoch(r.issued_at);
    need(typeof r.sealed_payload === 'string' && r.sealed_payload.length >= 32 && r.sealed_payload.length <= 8192, 'bootstrap_storage_mismatch');
    need(r.envelope_hash === null === (r.sealed_envelope === null), 'bootstrap_storage_mismatch');
    if (r.envelope_hash !== null) {
      decode(r.envelope_hash, 32);
      need(typeof r.sealed_envelope === 'string' && r.sealed_envelope.length >= 32 && r.sealed_envelope.length <= 8192, 'bootstrap_storage_mismatch');
    }
    need(r.status !== 'issued' || r.envelope_hash !== null, 'bootstrap_storage_mismatch');
    return r;
  }
  const binding = r => Object.freeze({
    entitlementID: reservation.entitlementID,
    entitlementHandleDigest: r.handle_digest,
    ...reservation.scope
  });
  const bindingText = r => JSON.stringify({
    reservation,
    selection,
    custodyKeyID: custody.keyID,
    handleDigest: r.handle_digest,
    issuedAt: r.issued_at
  });
  async function verifiedRow() {
    const r = row();
    need(await digest(encoder.encode(bindingText(r))) === r.binding_digest, 'bootstrap_storage_mismatch');
    return r;
  }
  function getAuthority() {
    if (!authority)
      authority = createStripeDeviceAuthority({
        enabled: true,
        storage,
        binding: binding(row()),
        inspectDeviceAuthority: inspect,
        admission: async () => fail('bootstrap_admission_not_used')
      });
    return authority;
  }
  const aad = (kind, r, hash = r.payload_hash) => `cliphoard.bootstrap-${ kind }\n1\n${ reservation.entitlementID }\n${ reservation.provisioningID }\n${ r.binding_digest }\n${ hash }\n${ custody.keyID }`;
  async function sealed(plaintext, context) {
    const result = await custody.seal(plaintext, context);
    need(typeof result === 'string' && result.length >= 32 && result.length <= 8192 && result !== plaintext, 'bootstrap_custody_unavailable');
    return result;
  }
  async function payload(r) {
    const value = await custody.open(r.sealed_payload, aad('payload', r));
    need(typeof value === 'string' && encoder.encode(value).length <= 512, 'bootstrap_custody_unavailable');
    need(await digest(encoder.encode(value)) === r.payload_hash, 'bootstrap_custody_unavailable');
    const lines = value.split('\n');
    need(lines.length === 10, 'bootstrap_custody_unavailable');
    const fields = {
      bootstrapKeyID: selection.bootstrapKeyID,
      profileID: selection.profileID,
      receiptIssuerKeyID: selection.receiptIssuerKeyID,
      entitlementID: reservation.entitlementID,
      activationHandle: lines[7],
      issuedAt: r.issued_at
    };
    need(decoder.decode(bootstrapPayload(fields)) === value && await tokenDigest(fields.activationHandle) === r.handle_digest, 'bootstrap_custody_unavailable');
    return fields;
  }
  async function envelope(r) {
    need(r.envelope_hash !== null, 'bootstrap_not_issued');
    const value = await custody.open(r.sealed_envelope, aad('envelope', r, r.envelope_hash));
    need(typeof value === 'string' && await digest(encoder.encode(value)) === r.envelope_hash, 'bootstrap_custody_unavailable');
    const fields = await verifyBootstrap(value, trust), parsed = parseBootstrap(value);
    need(fields.entitlementID === reservation.entitlementID && fields.issuedAt === r.issued_at && await digest(parsed.payload) === r.payload_hash && await tokenDigest(fields.activationHandle) === r.handle_digest, 'bootstrap_custody_unavailable');
    return value;
  }
  function terminal() {
    const r = row();
    if (getAuthority().readAuthorityFence().status === 'blocked')
      tx(() => {
        exec('UPDATE device_bootstrap_state SET status=\'blocked\' WHERE singleton=1');
        exec('UPDATE device_bootstrap_outbox SET status=\'cancelled\' WHERE status IN (\'pending\',\'leased\')');
      });
    return r.status === 'blocked' || getAuthority().readAuthorityFence().status === 'blocked';
  }
  async function active() {
    try {
      const value = await getAuthority().readEntitlement(reservation.entitlementID);
      need(!terminal() && value.status === 'active', 'bootstrap_ineligible');
      return value;
    } finally {
      if (terminal())
        await storage.sync();
    }
  }
  function fence(revision) {
    const r = row(), f = getAuthority().readAuthorityFence();
    need(r.status !== 'blocked' && f.id === reservation.entitlementID && f.status === 'active' && f.revision === revision, 'bootstrap_ineligible');
  }
  const serializedWake = fn => {
    const result = wakeTail.then(fn);
    wakeTail = result.catch(() => {
    });
    return result;
  };
  const prearm = () => serializedWake(async () => {
    const prior = alarmTime(await wake.getAlarm()), target = alarmTime(millis() + policy.prearmDelayMilliseconds);
    if (prior === null || prior <= millis() || prior > target)
      await wake.setAlarm(target);
    await wake.sync();
  });
  function due() {
    const r = row(true);
    if (!r || r.status === 'blocked')
      return null;
    if (r.issue_requested && r.envelope_hash === null)
      return now();
    const n = exec('SELECT MIN(CASE WHEN status=\'pending\' THEN ? ELSE lease_until END) AS due FROM device_bootstrap_outbox WHERE status IN (\'pending\',\'leased\')', now())[0].due;
    return n === null ? null : epoch(n);
  }
  const reconcile = () => serializedWake(async () => {
    const next = due();
    if (next === null)
      await wake.deleteAlarm();
    else
      await wake.setAlarm(alarmTime(Math.max(next * 1000, millis() + policy.retryDelayMilliseconds)));
    await wake.sync();
  });
  async function reconcileTerminalFailure() {
    try {
      if (initialized && authority && row(true)?.status === 'blocked' && authority.readAuthorityFence().status === 'blocked') {
        await storage.sync();
        await reconcile();
      }
    } catch {
/* Retain the wake when terminal durability or cleanup remains uncertain. */    }
  }
  function serial(fn, reserved = false) {
    if (!reserved && pending >= policy.maxPendingOperations)
      return Promise.reject(new ServiceError('bootstrap_busy'));
    if (!reserved)
      pending++;
    const work = tail.then(async () => {
      try {
        await prearm();
        const result = await fn();
        await reconcile();
        return result;
      } catch {
        await reconcileTerminalFailure();
        throw new ServiceError('bootstrap_unavailable');
      }
    });
    const finished = work.finally(() => {
      if (!reserved)
        pending--;
    });
    tail = finished.catch(() => {
    });
    return finished;
  }
  async function provision() {
    await canonicalDevice(selection.bootstrapPublicKey);
    await canonicalDevice(selection.receiptIssuerPublicKey);
    let r = row(true);
    if (!r) {
      const handle = randomToken(32), issuedAt = now(), fields = {
          bootstrapKeyID: selection.bootstrapKeyID,
          profileID: selection.profileID,
          receiptIssuerKeyID: selection.receiptIssuerKeyID,
          entitlementID: reservation.entitlementID,
          activationHandle: handle,
          issuedAt
        };
      const plaintext = decoder.decode(bootstrapPayload(fields));
      const candidate = {
        handle_digest: await tokenDigest(handle),
        issued_at: issuedAt,
        payload_hash: await digest(encoder.encode(plaintext))
      };
      candidate.binding_digest = await digest(encoder.encode(bindingText(candidate)));
      candidate.sealed_payload = await sealed(plaintext, aad('payload', candidate));
      tx(() => {
        if (!row(true))
          exec('INSERT INTO device_bootstrap_state VALUES(1,1,?,?,?,?,?,?,NULL,NULL,0,\'allocated\')', configJSON, candidate.binding_digest, candidate.handle_digest, candidate.issued_at, candidate.payload_hash, candidate.sealed_payload);
      });
    }
    await storage.sync();
    r = await verifiedRow();
    getAuthority();
    await storage.sync();
    return Object.freeze({
      entitlementID: reservation.entitlementID,
      provisioningID: reservation.provisioningID,
      bindingDigest: r.binding_digest
    });
  }
  function addDelivery(requestID) {
    const id = reservation.provisioningID + '.' + requestID;
    exec('INSERT OR IGNORE INTO device_bootstrap_outbox(id,request_id,status) VALUES(?,?,\'pending\')', id, requestID);
  }
  async function issue() {
    let r = await verifiedRow();
    const owner = await active();
    if (r.envelope_hash !== null)
      return Object.freeze({
        ok: true,
        code: 'already_issued'
      });
    const fields = await payload(r);
    fence(owner.revision);
    const purchase = { ...fields };
    delete purchase.bootstrapKeyID;
    const issuer = createDeviceBootstrapIssuer({
      enabled: true,
      fields: purchase,
      signer: {
        bootstrapKeyID: selection.bootstrapKeyID,
        bootstrapPublicKey: selection.bootstrapPublicKey,
        sign
      }
    });
    const raw = await issuer.issue(), hash = await digest(encoder.encode(raw)), cipher = await sealed(raw, aad('envelope', r, hash));
    const current = await active();
    tx(() => {
      fence(current.revision);
      const winner = row();
      need(winner.payload_hash === r.payload_hash && winner.binding_digest === r.binding_digest, 'bootstrap_storage_mismatch');
      if (winner.envelope_hash === null) {
        exec('UPDATE device_bootstrap_state SET envelope_hash=?,sealed_envelope=?,status=\'issued\' WHERE singleton=1', hash, cipher);
        addDelivery('initial');
      }
    });
    await storage.sync();
    r = await verifiedRow();
    await envelope(r);
    fence(current.revision);
    return Object.freeze({
      ok: true,
      code: 'issued'
    });
  }
  async function deliverOne() {
    const r = await verifiedRow();
    if (r.status === 'blocked')
      return {
        ok: true,
        code: 'blocked'
      };
    const first = exec('SELECT * FROM device_bootstrap_outbox WHERE status=\'pending\' OR (status=\'leased\' AND lease_until<=?) ORDER BY rowid LIMIT 1', now())[0];
    if (!first)
      return {
        ok: true,
        code: 'nothing_due'
      };
    const owner = await active(), leaseID = randomToken(16);
    const claimed = tx(() => {
      fence(owner.revision);
      const current = exec('SELECT * FROM device_bootstrap_outbox WHERE id=?', first.id)[0];
      if (!(current.status === 'pending' || current.status === 'leased' && current.lease_until <= now()))
        return false;
      if (current.lease_id)
        exec('UPDATE device_bootstrap_attempts SET outcome=\'uncertain\' WHERE lease_id=? AND outcome=\'in_flight\'', current.lease_id);
      exec('INSERT INTO device_bootstrap_attempts VALUES(?,?,?,NULL,\'in_flight\')', leaseID, current.id, now());
      exec('UPDATE device_bootstrap_outbox SET status=\'leased\',lease_id=?,lease_until=?,attempts=attempts+1,outcome=\'in_flight\' WHERE id=?', leaseID, epoch(now() + policy.deliveryLeaseSeconds), current.id);
      return true;
    });
    await storage.sync();
    if (!claimed)
      return {
        ok: true,
        code: 'not_claimed'
      };
    let dispatched = false;
    try {
      const raw = await envelope(r), fresh = await active();
      const authorizeDispatch = () => tx(() => {
        fence(fresh.revision);
        const current = exec('SELECT * FROM device_bootstrap_outbox WHERE id=?', first.id)[0], latest = row();
        need(current.status === 'leased' && current.lease_id === leaseID && now() < current.lease_until && latest.envelope_hash === r.envelope_hash, 'bootstrap_delivery_superseded');
      });
      authorizeDispatch();
      dispatched = true;
      const accepted = await delivery.deliverBootstrap({
        to: fresh.ownerEmail,
        deliveryID: first.id,
        entitlementID: reservation.entitlementID,
        envelope: raw,
        payloadHash: r.payload_hash,
        authorizeDispatch
      });
      need(data(accepted, ['accepted']).accepted === true, 'bootstrap_delivery_unavailable');
      tx(() => {
        exec('UPDATE device_bootstrap_attempts SET outcome=\'accepted\',finished_at=? WHERE lease_id=?', now(), leaseID);
        exec('UPDATE device_bootstrap_outbox SET outcome=\'accepted\',status=CASE WHEN status=\'cancelled\' THEN status ELSE \'accepted\' END WHERE id=? AND lease_id=?', first.id, leaseID);
      });
      await storage.sync();
      return {
        ok: true,
        code: 'accepted'
      };
    } catch {
      tx(() => {
        const outcome = dispatched ? 'uncertain' : 'not_dispatched';
        exec('UPDATE device_bootstrap_attempts SET outcome=?,finished_at=? WHERE lease_id=? AND outcome<>\'accepted\'', outcome, now(), leaseID);
        exec('UPDATE device_bootstrap_outbox SET outcome=? WHERE id=? AND lease_id=?', outcome, first.id, leaseID);
      });
      await storage.sync();
      return {
        ok: false,
        code: dispatched ? 'delivery_uncertain' : 'delivery_deferred'
      };
    }
  }
  async function drain() {
    const r = await verifiedRow();
    await active();
    if (r.issue_requested && r.envelope_hash === null)
      await issue();
    const start = elapsed();
    let prior = start, attempts = 0;
    while (attempts < policy.maximumAttemptsPerInvocation) {
      const tick = elapsed();
      if (tick < prior || tick - start >= policy.invocationBudgetMilliseconds)
        break;
      prior = tick;
      const busy = delivery.hasUnsettledSend();
      need(typeof busy === 'boolean', 'bootstrap_unavailable');
      if (busy)
        break;
      const next = due();
      if (next === null || next > now())
        break;
      attempts++;
      const result = await deliverOne();
      if (!result.ok)
        break;
    }
    return Object.freeze({
      ok: true,
      code: 'recovered',
      attempts
    });
  }
  return Object.freeze({
    provision: (...args) => args.length ? Promise.reject(new ServiceError('bootstrap_rejected')) : serial(provision),
    requestIssue: (...args) => args.length ? Promise.reject(new ServiceError('bootstrap_rejected')) : serial(async () => {
      await verifiedRow();
      tx(() => {
        need(row().status !== 'blocked', 'bootstrap_ineligible');
        exec('UPDATE device_bootstrap_state SET issue_requested=1 WHERE singleton=1');
      });
      await storage.sync();
      return issue();
    }),
    requestRecovery: input => {
      let value;
      try {
        value = data(input, ['requestID']);
        decode(value.requestID, 16);
      } catch {
        return Promise.reject(new ServiceError('bootstrap_rejected'));
      }
      return serial(async () => {
        const r = await verifiedRow();
        need(r.envelope_hash !== null, 'bootstrap_not_issued');
        const owner = await active();
        tx(() => {
          fence(owner.revision);
          addDelivery(value.requestID);
        });
        await storage.sync();
        return Object.freeze({
          ok: true,
          code: 'delivery_requested'
        });
      });
    },
    refreshAuthority: async (...args) => {
      if (args.length)
        fail('bootstrap_rejected');
      try {
        await prearm();
        await verifiedRow();
        let fact;
        try {
          fact = await getAuthority().refreshAuthority();
        } finally {
          if (terminal())
            await storage.sync();
        }
        await reconcile();
        return Object.freeze({
          ok: true,
          code: fact.status === 'blocked' ? 'blocked' : 'authority_refreshed'
        });
      } catch {
        fail('bootstrap_unavailable');
      }
    },
    recover: (...args) => args.length ? Promise.reject(new ServiceError('bootstrap_rejected')) : serial(drain),
    alarm: (...args) => {
      if (args.length)
        return Promise.reject(new ServiceError('bootstrap_rejected'));
      if (alarmOperation)
        return alarmOperation;
      const entered = prearm();
      alarmOperation = serial(async () => {
        await entered;
        return drain();
      }, true).finally(() => {
        alarmOperation = undefined;
      });
      return alarmOperation;
    },
    readActivationBinding: (...args) => {
      if (args.length)
        fail('bootstrap_rejected');
      try {
        return binding(row());
      } catch {
        fail('bootstrap_unavailable');
      }
    },
    snapshot: () => {
      try {
        const r = row();
        return Object.freeze({
          allocated: 1,
          issued: r.envelope_hash === null ? 0 : 1,
          blocked: r.status === 'blocked' ? 1 : 0,
          pending: exec('SELECT count(*) AS n FROM device_bootstrap_outbox WHERE status IN (\'pending\',\'leased\')')[0].n,
          accepted: exec('SELECT count(*) AS n FROM device_bootstrap_outbox WHERE status=\'accepted\'')[0].n,
          uncertain: exec('SELECT count(*) AS n FROM device_bootstrap_attempts WHERE outcome=\'uncertain\'')[0].n
        });
      } catch {
        fail('bootstrap_unavailable');
      }
    }
  });
}
