import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { mkdtemp, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { randomToken, verifyReceiptSignature } from '../protocol.mjs';

// Optional path to an already-installed copy of the repository's pinned test
// dependencies. No installation, provider credentials or Wrangler config here.
const require = createRequire(process.env.CLIPHOARD_TEST_DEPENDENCIES ?? import.meta.url);
const { Miniflare, Log, LogLevel } = require('miniflare');

test('real workerd SQLite: atomic rollback, duplicate approval and stored-receipt retry after runtime restart', { timeout: 30000 }, async () => {
  const directory = await mkdtemp(join(tmpdir(), 'cliphoard-synthetic-workerd-ledger-'));
  const options = { modules: true,
    scriptPath: fileURLToPath(new URL('./sqlite-runtime-harness.mjs', import.meta.url)),
    compatibilityDate: '2026-07-01', host: '127.0.0.1', port: 0, log: new Log(LogLevel.NONE),
    durableObjects: { SYNTHETIC_LEDGER: { className: 'SyntheticSqliteLedger', useSQLite: true } },
    durableObjectsPersist: directory, bindings: { SYNTHETIC_ENTITLEMENT_ID: randomToken(16) },
  };
  let runtime;
  const call = async input => {
    const result = await runtime.dispatchFetch('http://synthetic.invalid/sqlite-prototype-test', {
      method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(input),
    });
    assert.equal(result.status, 200);
    return result.json();
  };
  try {
    runtime = new Miniflare(options);
    const first = await call({ action: 'exercise', now: 1767323045 });
    for (const key of ['rollbackRejected', 'rollbackEmpty', 'duplicateSame']) assert.equal(first[key], true, key);
    assert.equal(first.signatures, 1);
    assert.equal(first.delivery.code, 'delivery_uncertain');
    assert.equal(first.snapshot.issued, 1);
    await verifyReceiptSignature(first.receipt, new Map([['synthetic-1', first.issuer]]));
    await runtime.dispose(); runtime = undefined;
    runtime = new Miniflare(options);
    const resumed = await call({ action: 'resume', now: 1767323075, issuer: first.issuer });
    assert.equal(resumed.result.code, 'accepted');
    assert.equal(resumed.receipt, first.receipt);
    assert.equal(resumed.deliveryID, first.deliveryID);
    assert.equal(resumed.snapshot.issued, 1);
    assert.equal(resumed.snapshot.accepted, 2);
  } finally {
    await runtime?.dispose();
    await rm(directory, { recursive: true });
  }
});
