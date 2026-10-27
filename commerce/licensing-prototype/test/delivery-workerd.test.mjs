import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomToken } from '../protocol.mjs';

// Read only the already-installed pinned development dependency. No installation.
const require = createRequire(process.env.CLIPHOARD_TEST_DEPENDENCIES ?? import.meta.url);
const { Miniflare, Log, LogLevel } = require('miniflare');

test('actual local workerd alarm preserves prearm across recreation and dispatches committed receipt', { timeout: 30000 }, async () => {
  const directory = await mkdtemp(join(tmpdir(), 'cliphoard-delivery-workerd-'));
  let runtime, outbound = 0;
  const options = { modules: true, compatibilityDate: '2026-07-01', cf: false,
    scriptPath: fileURLToPath(new URL('./delivery-runtime-harness.mjs', import.meta.url)),
    host: '127.0.0.1', port: 0, log: new Log(LogLevel.NONE),
    durableObjects: { SYNTHETIC_DELIVERY: { className: 'SyntheticDeliveryLedger', useSQLite: true } },
    durableObjectsPersist: directory, bindings: { SYNTHETIC_ENTITLEMENT_ID: randomToken(16) },
    outboundService: () => { outbound++; throw new Error('all worker outbound requests forbidden in this test'); },
  };
  const call = async action => {
    const response = await runtime.dispatchFetch('http://synthetic.invalid/local-delivery-fixture', {
      method: 'POST', body: JSON.stringify({ action }), headers: { 'content-type': 'application/json' },
    });
    assert.equal(response.status, 200); return response.json();
  };
  try {
    runtime = new Miniflare(options);
    const first = await call('prepare');
    assert.equal(first.interrupted, true); assert.equal(first.snapshot.issued, 1);
    assert.equal(first.snapshot.pending, 1); assert.ok(first.alarm > Date.now());
    await runtime.dispose(); runtime = undefined;
    runtime = new Miniflare(options);
    const resumed = await call('status');
    assert.equal(resumed.alarm, first.alarm); assert.equal(resumed.evidence.receipt_sends, 0);
    assert.equal((await call('recover')).alarm, first.alarm);
    await call('trigger');
    let result;
    const until = Date.now() + 5000;
    do {
      await new Promise(resolve => setTimeout(resolve, 20)); result = await call('status');
    } while (result.snapshot.pending !== 0 && Date.now() < until);
    assert.equal(result.snapshot.pending, 0); assert.equal(result.snapshot.accepted, 2);
    assert.equal(result.evidence.receipt_sends, 1); assert.equal(result.evidence.alarms, 1);
    assert.equal(result.evidence.pre_alarm_null, 1); assert.equal(result.alarm, null);
    assert.equal(outbound, 0);
  } finally {
    await runtime?.dispose(); await rm(directory, { recursive: true });
  }
});
