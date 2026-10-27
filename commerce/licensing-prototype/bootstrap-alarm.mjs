// Disabled two-channel scheduler. One owner per Durable Object must wrap its one
// physical alarm with this object; callers never receive the physical capability.
import { PROTOCOL } from './protocol.mjs';

const channels = Object.freeze(['activation', 'bootstrap']);
class AlarmError extends Error {
  constructor(code) { super(code); this.name = 'DeviceLicenceAlarmError'; this.code = code; }
}
const fail = code => { throw new AlarmError(code); };
const need = condition => { if (!condition) fail('alarm_configuration'); };
function data(value, names) {
  need(value && typeof value === 'object' && [Object.prototype, null].includes(Object.getPrototypeOf(value)));
  const descriptors = Object.getOwnPropertyDescriptors(value);
  need(Reflect.ownKeys(descriptors).length === names.length
    && names.every(name => descriptors[name] && Object.hasOwn(descriptors[name], 'value')));
  return Object.freeze(Object.fromEntries(names.map(name => [name, descriptors[name].value])));
}
function functions(value, names) {
  const captured = data(value, names); need(Object.values(captured).every(method => typeof method === 'function'));
  return captured;
}
const disabledCall = async () => fail('alarm_disabled');
const disabledChannel = Object.freeze({ getAlarm: disabledCall, setAlarm: disabledCall,
  deleteAlarm: disabledCall, sync: disabledCall });
const disabled = Object.freeze({ activation: disabledChannel, bootstrap: disabledChannel,
  alarm: disabledCall, recover: disabledCall });

export function createDeviceLicenceAlarmMultiplexer(options = {}) {
  let storage, physical, clock, delay, handlers;
  try {
    need(options && typeof options === 'object' && !Array.isArray(options));
    const enabled = Object.getOwnPropertyDescriptor(options, 'enabled');
    if (enabled === undefined) return disabled;
    need(Object.hasOwn(enabled, 'value'));
    if (enabled.value !== true) return disabled;
    const value = data(options, ['enabled', 'storage', 'physicalAlarm', 'clockMilliseconds',
      'recoveryDelayMilliseconds', 'handlers']);
    const supplied = data(value.storage, ['sql', 'transactionSync', 'sync']);
    need(typeof supplied.transactionSync === 'function' && typeof supplied.sync === 'function');
    storage = Object.freeze({ ...supplied, sql: functions(supplied.sql, ['exec']) });
    physical = functions(value.physicalAlarm, ['getAlarm', 'setAlarm', 'deleteAlarm', 'sync']);
    handlers = functions(value.handlers, channels);
    clock = value.clockMilliseconds; delay = value.recoveryDelayMilliseconds;
    need(typeof clock === 'function' && Number.isSafeInteger(delay) && delay > 0 && delay <= 86400000);
  } catch { fail('alarm_configuration'); }
  const validTime = value => {
    if (!Number.isSafeInteger(value) || value < 1 || value > PROTOCOL.maxEpoch * 1000) fail('alarm_unavailable');
    return value;
  };
  const now = () => validTime(clock());
  const exec = (query, ...args) => Array.from(storage.sql.exec(query, ...args));
  let initialized = false, tail = Promise.resolve();
  const running = new Set();
  function ensure() {
    if (initialized) return;
    storage.transactionSync(() => {
      exec(`CREATE TABLE IF NOT EXISTS device_licence_alarm_channels (
        channel TEXT PRIMARY KEY CHECK(channel IN ('activation','bootstrap')), wake_at INTEGER NOT NULL)`);
      exec(`CREATE TABLE IF NOT EXISTS device_licence_alarm_guards (
        channel TEXT PRIMARY KEY CHECK(channel IN ('activation','bootstrap')), wake_at INTEGER NOT NULL)`);
    });
    initialized = true;
  }
  const serial = action => {
    const result = tail.then(() => { ensure(); return action(); }).catch(() => fail('alarm_unavailable'));
    tail = result.then(() => undefined, () => undefined); return result;
  };
  const rows = table => exec(`SELECT channel,wake_at FROM ${table}`).map(row => {
    if (!channels.includes(row.channel)) fail('alarm_unavailable'); validTime(row.wake_at); return row;
  });
  const channelRows = () => rows('device_licence_alarm_channels');
  const guardRows = () => rows('device_licence_alarm_guards');
  async function prearm() {
    const target = validTime(now() + delay), previous = await physical.getAlarm();
    if (previous !== null) validTime(previous);
    if (previous === null || previous <= now() || previous > target) await physical.setAlarm(target);
    await physical.sync();
  }
  async function reconcile() {
    const pending = [...channelRows(), ...guardRows()];
    if (pending.length === 0) await physical.deleteAlarm();
    else await physical.setAlarm(validTime(Math.max(Math.min(...pending.map(row => row.wake_at)), now() + 1)));
    await physical.sync();
  }
  function channel(name) {
    return Object.freeze({
      getAlarm: () => serial(() => channelRows().find(row => row.channel === name)?.wake_at ?? null),
      setAlarm: time => {
        try { validTime(time); } catch { return Promise.reject(new AlarmError('alarm_rejected')); }
        return serial(async () => {
          await prearm();
          storage.transactionSync(() => exec(`INSERT INTO device_licence_alarm_channels VALUES(?,?)
            ON CONFLICT(channel) DO UPDATE SET wake_at=excluded.wake_at`, name, time));
          await storage.sync(); await reconcile();
        });
      },
      deleteAlarm: () => serial(async () => {
        // Deleting one channel cannot remove another channel or dispatch guard.
        storage.transactionSync(() => exec('DELETE FROM device_licence_alarm_channels WHERE channel=?', name));
        await storage.sync(); await reconcile();
      }),
      sync: () => serial(async () => { await storage.sync(); await reconcile(); }),
    });
  }
  async function dispatch() {
    const selected = await serial(async () => {
      // The platform may have consumed the physical alarm. Restore a durable
      // physical wake before advancing due rows or entering a handler.
      await prearm();
      const at = now(), fallback = validTime(at + delay);
      const due = new Set([...channelRows(), ...guardRows()].filter(row => row.wake_at <= at).map(row => row.channel));
      const start = [...due].filter(name => !running.has(name));
      storage.transactionSync(() => {
        for (const name of due) {
          exec('UPDATE device_licence_alarm_channels SET wake_at=? WHERE channel=? AND wake_at<=?', fallback, name, at);
          exec(`INSERT INTO device_licence_alarm_guards VALUES(?,?)
            ON CONFLICT(channel) DO UPDATE SET wake_at=excluded.wake_at`, name, fallback);
        }
        for (const name of running)
          exec('UPDATE device_licence_alarm_guards SET wake_at=? WHERE channel=?', fallback, name);
      });
      await storage.sync(); await reconcile();
      for (const name of start) running.add(name);
      return start;
    });
    const outcomes = await Promise.allSettled(selected.map(async name => {
      let success = false;
      try { await handlers[name](); success = true; }
      finally {
        try {
          await serial(async () => {
            storage.transactionSync(() => {
              if (success) exec('DELETE FROM device_licence_alarm_guards WHERE channel=?', name);
              else exec('UPDATE device_licence_alarm_guards SET wake_at=? WHERE channel=?', validTime(now() + delay), name);
            });
            await storage.sync(); await reconcile();
          });
        } finally { running.delete(name); }
      }
    }));
    if (outcomes.some(outcome => outcome.status === 'rejected')) fail('alarm_dispatch_failed');
    return Object.freeze({ ok: true, code: 'alarms_checked', dispatched: selected.length });
  }
  return Object.freeze({ activation: channel('activation'), bootstrap: channel('bootstrap'),
    alarm: async (...args) => { if (args.length) fail('alarm_rejected'); return dispatch(); },
    recover: async (...args) => {
      if (args.length) fail('alarm_rejected');
      return serial(async () => { await storage.sync(); await reconcile();
        return Object.freeze({ ok: true, code: 'wake_reconciled' }); });
    },
  });
}
