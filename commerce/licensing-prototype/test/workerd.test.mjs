import test from 'node:test';
import assert from 'node:assert/strict';
import { Miniflare, Log, LogLevel } from 'miniflare';
import { fileURLToPath } from 'node:url';
import { receiptFixture } from './fixtures.mjs';
import { verifyReceiptSignature } from '../protocol.mjs';

test('actual Workers runtime: bidirectional P-256 wire verification, local proof, email approval, replay and refund', { timeout: 30000 }, async () => {
  const incoming = await receiptFixture();
  const runtime = new Miniflare({ modules: true,
    scriptPath: fileURLToPath(new URL('./runtime-harness.mjs', import.meta.url)),
    compatibilityDate: '2026-07-01', host: '127.0.0.1', port: 0, log: new Log(LogLevel.NONE),
  });
  try {
    const response = await runtime.dispatchFetch('http://synthetic.invalid/prototype-test', {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ receipt: incoming.receipt, publicIssuer: incoming.signer.publicKey }),
    });
    assert.equal(response.status, 200);
    const result = await response.json();
    assert.equal(result.incomingID, incoming.fields.receiptID);
    for (const key of ['getRejected', 'scannerUnchanged', 'replayRejected', 'refundRejected', 'offlineAfterRefund', 'identicalRetry']) {
      assert.equal(result[key], true, key);
    }
    assert.equal(result.signatures, 1);
    const verified = await verifyReceiptSignature(result.receipt, new Map([['synthetic-1', result.publicIssuer]]));
    assert.equal(verified.fields.receiptID, result.receiptID);
  } finally { await runtime.dispose(); }
});
