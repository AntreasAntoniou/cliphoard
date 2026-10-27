// DISABLED composition only. No Worker export, constructor alarm or production binding.
import { epoch, PROTOCOL } from './protocol.mjs';

class RunnerError extends Error {
  constructor(code) { super(code); this.name = 'DeviceDeliveryRunnerError'; this.code = code; }
}
const fail = code => { throw new RunnerError(code); };
const require = (condition, code = 'runner_configuration') => { if (!condition) fail(code); };
function data(value, keys, code = 'runner_configuration') {
  require(value && typeof value === 'object'
    && [Object.prototype, null].includes(Object.getPrototypeOf(value)), code);
  const fields = Object.getOwnPropertyDescriptors(value);
  require(Reflect.ownKeys(fields).length === keys.length && keys.every(key => fields[key]
    && Object.hasOwn(fields[key], 'value')), code);
  return Object.fromEntries(keys.map(key => [key, fields[key].value]));
}
const disabledCall = async () => fail('runner_disabled');
const disabled = Object.freeze(Object.fromEntries(['begin', 'approve', 'alarm', 'recover',
  'observeEntitlement', 'observeAdmission'].map(key => [key, disabledCall])));

export function createDeliveryRunner(options = {}) {
  if (Object.getOwnPropertyDescriptor(options, 'enabled')?.value !== true) return disabled;
  let makeService, alarmStorage, busy, clockMilliseconds, monotonicMilliseconds, policy;
  try {
    const value = data(options, ['enabled', 'makeService', 'alarmStorage', 'mail', 'clockMilliseconds',
      'monotonicMilliseconds', 'operational']);
    ({ makeService, clockMilliseconds, monotonicMilliseconds } = value);
    require(typeof makeService === 'function' && typeof clockMilliseconds === 'function'
      && typeof monotonicMilliseconds === 'function');
    alarmStorage = data(value.alarmStorage, ['getAlarm', 'setAlarm', 'deleteAlarm', 'sync']);
    require(Object.values(alarmStorage).every(method => typeof method === 'function'));
    busy = Object.getOwnPropertyDescriptor(value.mail, 'hasUnsettledSend')?.value;
    require(typeof busy === 'function');
    policy = Object.freeze(data(value.operational, ['maximumAttemptsPerInvocation', 'maxPendingOperations', 'invocationBudgetMilliseconds',
      'prearmDelayMilliseconds', 'retryDelayMilliseconds', 'continuationDelayMilliseconds']));
    require(Object.values(policy).every(number => Number.isSafeInteger(number) && number > 0));
    require(policy.maximumAttemptsPerInvocation <= 100 && policy.maxPendingOperations <= 64
      && policy.invocationBudgetMilliseconds <= 60000
      && [policy.prearmDelayMilliseconds, policy.retryDelayMilliseconds, policy.continuationDelayMilliseconds]
        .every(delay => delay <= 86400000));
  } catch { fail('runner_configuration'); }

  let service, tail = Promise.resolve(), wakeTail = Promise.resolve(), pending = 0, alarmOperation;
  const getService = () => {
    if (!service) {
      const value = makeService();
      require(value && typeof value === 'object', 'runner_unavailable');
      for (const name of ['begin', 'approve', 'deliverOne', 'nextDeliveryAt', 'observeEntitlement', 'observeAdmission'])
        require(typeof Object.getOwnPropertyDescriptor(value, name)?.value === 'function', 'runner_unavailable');
      service = value;
    }
    return service;
  };
  const now = () => {
    const value = clockMilliseconds();
    require(Number.isSafeInteger(value) && value > 0 && value <= PROTOCOL.maxEpoch * 1000, 'runner_unavailable');
    return value;
  };
  const alarmTime = value => {
    require(value === null || (Number.isSafeInteger(value) && value > 0 && value <= PROTOCOL.maxEpoch * 1000), 'runner_unavailable');
    return value;
  };
  const elapsedTime = () => {
    const value = monotonicMilliseconds();
    require(Number.isFinite(value) && value >= 0 && value <= Number.MAX_SAFE_INTEGER, 'runner_unavailable');
    return value;
  };
  const at = delay => alarmTime(now() + delay);
  const isBusy = () => {
    const value = busy(); require(typeof value === 'boolean', 'runner_unavailable'); return value;
  };
  const due = () => {
    const value = getService().nextDeliveryAt();
    return value === null ? null : epoch(value) * 1000;
  };
  const serial = (action, reservedAlarm = false) => {
    if (!reservedAlarm && pending >= policy.maxPendingOperations)
      return Promise.reject(new RunnerError('runner_busy'));
    if (!reservedAlarm) pending++;
    const result = tail.then(action).catch(() => fail('runner_unavailable'));
    const finished = result.then(value => {
      if (!reservedAlarm) pending--; return value;
    }, error => { if (!reservedAlarm) pending--; throw error; });
    tail = finished.then(() => undefined, () => undefined);
    return finished;
  };
  const serialWake = action => {
    const result = wakeTail.then(action);
    wakeTail = result.then(() => undefined, () => undefined);
    return result;
  };
  const prearm = () => serialWake(async () => {
    const previous = alarmTime(await alarmStorage.getAlarm());
    const target = at(policy.prearmDelayMilliseconds);
    // A handler normally observes null for its consumed alarm. Treat a past value
    // as consumed too, avoiding a busy loop in an explicit recovery invocation.
    if (previous === null || previous <= now() || previous > target) await alarmStorage.setAlarm(target);
    await alarmStorage.sync();
    return previous;
  });
  const reconcile = (previous, minimumDelay) => serialWake(async () => {
    const next = due();
    if (next === null) {
      await alarmStorage.deleteAlarm();
    } else {
      let target = Math.max(next, at(minimumDelay));
      // Preserve an earlier pre-existing future wake. The newly installed failsafe
      // may move later to the actual lease expiry because the runner owns this alarm.
      if (previous !== null && previous > now()) target = Math.min(target, previous);
      await alarmStorage.setAlarm(alarmTime(target));
    }
    await alarmStorage.sync();
  });
  function command(name, input) {
    let snapshot;
    try {
      snapshot = Object.freeze(data(input, name === 'begin'
        ? ['method', 'entitlementHandle', 'devicePublicKey', 'requestID']
        : ['method', 'challengeID', 'approvalToken', 'approvalRequestID', 'deviceSignature'], 'runner_rejected'));
      require(snapshot.method === 'POST' && Object.values(snapshot).every(value => typeof value === 'string'), 'runner_rejected');
    } catch { return Promise.reject(new RunnerError('runner_rejected')); }
    return serial(async () => {
      const previous = await prearm(); // Must succeed before any enqueue opportunity.
      const result = await getService()[name](snapshot);
      await reconcile(previous, policy.continuationDelayMilliseconds);
      return result;
    });
  }
  async function feed(name, value) {
    // Never queue committed authority/refund/hold facts behind mail or signing.
    try { return await getService()[name](value); }
    catch { fail('runner_unavailable'); }
  }
  return Object.freeze({
    begin: input => command('begin', input),
    approve: input => command('approve', input),
    observeEntitlement: value => feed('observeEntitlement', value),
    observeAdmission: value => feed('observeAdmission', value),
    recover: () => serial(async () => {
      const previous = alarmTime(await alarmStorage.getAlarm());
      await reconcile(previous, policy.continuationDelayMilliseconds);
      return Object.freeze({ ok: true, code: 'wake_reconciled' });
    }),
    alarm: () => {
      // The platform has one active alarm handler; coalesce explicit callers too.
      // This single reserved operation can rearm even when command capacity is full.
      if (alarmOperation) return alarmOperation;
      // The runtime consumes the old alarm BEFORE entering this method. Rearm
      // outside the long command tail, while sharing the short storage tail with
      // cleanup; otherwise a paused command could later commit with no wake left.
      const entry = prearm().then(previous => ({ previous }), () => ({ failed: true }));
      const result = serial(async () => {
        const armed = await entry;
        require(!armed.failed, 'runner_unavailable');
        await prearm(); // Refresh the failsafe after waiting, before any external work.
        const previous = armed.previous;
        const start = elapsedTime(); let last = start, attempts = 0, deferred = false;
        while (attempts < policy.maximumAttemptsPerInvocation) {
          const tick = elapsedTime();
          if (tick < last) { deferred = true; break; } // A broken elapsed clock cannot extend the budget.
          last = tick;
          if (tick - start >= policy.invocationBudgetMilliseconds) break;
          if (isBusy()) { deferred = true; break; }
          const next = due();
          if (next === null || next > now()) break;
          attempts++;
          try {
            const result = await getService().deliverOne();
            if (result?.ok !== true) deferred = true;
          } catch { deferred = true; break; }
        }
        await reconcile(previous, deferred ? policy.retryDelayMilliseconds : policy.continuationDelayMilliseconds);
        return Object.freeze({ ok: !deferred, code: deferred ? 'delivery_deferred' : 'delivery_checked', attempts });
      }, true);
      alarmOperation = result.then(value => { alarmOperation = undefined; return value; }, error => {
        alarmOperation = undefined; throw error;
      });
      return alarmOperation;
    },
  });
}
