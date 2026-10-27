import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomToken } from '../protocol.mjs';

const require = createRequire(process.env.CLIPHOARD_TEST_DEPENDENCIES ?? import.meta.url);
const { Miniflare, Log, LogLevel } = require('miniflare');

test('real local workerd reconstructs private lifecycle, refreshes before alarm delivery and reconciles terminal block', { timeout: 30000 }, async () => {
  const directory = await mkdtemp(join(tmpdir(), 'cliphoard-lifecycle-workerd-'));
  let runtime, outbound = 0;
  const options = { modules: true, compatibilityDate: '2026-07-01', cf: false,
    scriptPath: fileURLToPath(new URL('./server-lifecycle-runtime-harness.mjs', import.meta.url)),
    host: '127.0.0.1', port: 0, log: new Log(LogLevel.NONE),
    durableObjects: { SYNTHETIC_LIFECYCLE: { className: 'SyntheticLifecycle', useSQLite: true } },
    durableObjectsPersist: directory, bindings: { SYNTHETIC_ENTITLEMENT_ID: randomToken(16) },
    outboundService: () => { outbound++; throw Error('worker outbound forbidden'); },
  };
  const call = async action => {
    const response = await runtime.dispatchFetch('http://synthetic.invalid/local-lifecycle-fixture', {
      method: 'POST', body: JSON.stringify({ action }), headers: { 'content-type': 'application/json' },
    });
    assert.equal(response.status, 200); return response.json();
  };
  const settleAlarm = async target => {
    const until = Date.now() + 5000; let result;
    do {
      await new Promise(resolve => setTimeout(resolve, 20)); result = await call('status');
    } while ((result.evidence.alarms !== target || result.pending !== 0) && Date.now() < until);
    return result;
  };
  try {
    runtime = new Miniflare(options);
    const first = await call('prepare');
    assert.equal(first.pending, 1); assert.equal(first.evidence.signatures, 1);
    assert.equal(first.evidence.approval_sends, 1); assert.equal(first.evidence.receipt_sends, 0);
    assert.ok(first.alarm > Date.now());
    await runtime.dispose(); runtime = undefined;
    runtime = new Miniflare(options);
    const recovered = await call('recover');
    assert.equal(recovered.pending, 1); assert.equal(recovered.alarm, first.alarm);
    assert(recovered.evidence.authority_reads > first.evidence.authority_reads);
    assert(recovered.evidence.admission_reads > first.evidence.admission_reads);
    await call('trigger'); const delivered = await settleAlarm(1);
    assert.equal(delivered.pending, 0); assert.equal(delivered.evidence.receipt_sends, 1);
    assert.equal(delivered.evidence.signatures, 1); assert.equal(delivered.evidence.receipt_matches, 1);
    assert.equal(delivered.evidence.pre_alarm_null, 1); assert.equal(delivered.alarm, null);
    const queued = await call('queue-blocked'); assert.equal(queued.pending, 1);
    await runtime.dispose(); runtime = undefined;
    runtime = new Miniflare(options);
    await call('trigger'); const blocked = await settleAlarm(2);
    assert.equal(blocked.pending, 0); assert.equal(blocked.cancelled, 1); assert.equal(blocked.status, 'blocked');
    assert.equal(blocked.evidence.approval_sends, 1); assert.equal(blocked.evidence.receipt_sends, 1);
    assert.equal(blocked.evidence.pre_alarm_null, 2); assert.equal(blocked.alarm, null);
    assert.equal(blocked.evidence.errors, 0); assert.equal(outbound, 0);
  } finally {
    await runtime?.dispose(); await rm(directory, { recursive: true });
  }
});
