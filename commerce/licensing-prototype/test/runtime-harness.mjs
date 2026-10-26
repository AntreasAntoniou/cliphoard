// TEST-ONLY Miniflare entry point. Not referenced by any Wrangler/deployment configuration.
import { fixture } from './fixtures.mjs';
import { verifyOffline, verifyReceiptSignature, randomToken } from '../protocol.mjs';

export default {
  async fetch(request) {
    const input = await request.json();
    const incoming = await verifyReceiptSignature(input.receipt, new Map([['synthetic-1', input.publicIssuer]]));
    const f = await fixture(); const { challenge } = await f.start();
    const approval = await f.approval(challenge);
    const before = f.service.snapshot();
    f.service.preview({ method: 'GET' });
    let getRejected = false;
    try { await f.service.approve({ ...approval, method: 'GET' }); }
    catch (error) { getRejected = error.code === 'method_not_allowed'; }
    const scannerUnchanged = JSON.stringify(before) === JSON.stringify(f.service.snapshot());
    const result = await f.service.approve(approval);
    const local = await verifyOffline(result.receipt, f.device.provider, f.trust);
    const retry = await f.service.approve(approval);
    let replayRejected = false;
    try { await f.service.approve(await f.approval(challenge)); }
    catch (error) { replayRejected = error.code === 'challenge_consumed'; }
    f.mutable.status = 'refunded';
    let refundRejected = false;
    try { await f.start(randomToken(16)); }
    catch (error) { refundRejected = error.code === 'entitlement_ineligible'; }
    const offlineAfterRefund = await verifyOffline(result.receipt, f.device.provider, f.trust);
    return Response.json({ incomingID: incoming.fields.receiptID, receipt: result.receipt,
      publicIssuer: f.signer.publicKey, receiptID: local.receiptID, getRejected, scannerUnchanged,
      replayRejected, refundRejected, offlineAfterRefund: offlineAfterRefund.receiptID === local.receiptID,
      identicalRetry: result.receipt === retry.receipt, signatures: f.signatures() });
  },
};
