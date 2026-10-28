// LOCAL TEST ONLY. Deliberately public scalar 1/2 and AES 0..31 fixtures.
import { DurableObject } from 'cloudflare:workers';
import { createDeviceLicenceDurableObjectClasses, createDeviceLicenceAuthenticatedEdge } from '../durable-object-hosts.mjs';
import { reconstructHostKeyCapabilities } from '../host-key-consumer.mjs';
import { syntheticMaterial } from './host-key-consumer-fixtures.mjs';
const realm = 'synthetic-host', origin = 'https://host.synthetic.invalid';
const token = n => btoa(String.fromCharCode(...new Uint8Array(16).fill(n))).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
const purchase = { accountId: 'acct_Host', mode: 'test', orderRef: '00000000-0000-4000-8000-000000000001',
  sessionId: 'cs_test_Host1', productId: 'prod_Host', priceId: 'price_Host', currency: 'gbp', unitAmount: 1000, taxBehavior: 'inclusive' };
export class SyntheticHostOrder extends DurableObject {
  async inspect(value) { const blocked = await this.ctx.storage.get('blocked'); return { ...value,
    state: blocked ? 'blocked' : 'active', ownerEmail: blocked ? null : 'owner@example.invalid' }; }
  async block() { await this.ctx.storage.put('blocked', true); }
}
const primitive = value => { const result = Object.fromEntries(Object.entries(value)); value[Symbol.dispose]?.(); return result; };
const common = env => ({ realm, directoryNamespace: env.SYNTHETIC_DIRECTORY, targetNamespace: env.SYNTHETIC_TARGET });
const inspect = env => async value => primitive(await env.SYNTHETIC_ORDER.getByName('synthetic-order').inspect(value));
const operational = { maximumAttemptsPerInvocation: 2, maxPendingOperations: 4, invocationBudgetMilliseconds: 1000,
  prearmDelayMilliseconds: 60000, retryDelayMilliseconds: 60000, continuationDelayMilliseconds: 60000 };
const hosts = createDeviceLicenceDurableObjectClasses({ enabled: true, DurableObject,
  configureDirectory: (_ctx, env) => ({ ...common(env), inspectDeviceAuthority: inspect(env),
    allocateEntitlementID: () => token(1), allocateProvisioningID: () => token(21) }),
  configureEntitlement: async (ctx, env) => {
    const material = syntheticMaterial(), keys = await reconstructHostKeyCapabilities({ enabled: true, material });
    ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS synthetic_mail(sequence INTEGER PRIMARY KEY AUTOINCREMENT, message TEXT NOT NULL)');
    return { ...common(env), selection: { profileID: 'synthetic-profile', bootstrapKeyID: material.bootstrapSigner.keyID,
      bootstrapPublicKey: material.bootstrapSigner.publicKey, receiptIssuerKeyID: material.receiptSigner.keyID,
      receiptIssuerPublicKey: material.receiptSigner.publicKey }, keys, inspectDeviceAuthority: inspect(env),
      admission: { evaluate: async () => ({ decision: 'allow', revision: 1 }), readCurrent: async id => ({ entitlementID: id, decision: 'allow', revision: 1 }) },
      mail: { from: 'support@example.invalid', replyTo: 'support@example.invalid', timeoutMilliseconds: 1000,
        send: async value => { ctx.storage.sql.exec('INSERT INTO synthetic_mail(message) VALUES(?)', JSON.stringify(value));
          await ctx.storage.sync(); return { messageId: 'synthetic-accepted' }; } },
      clocks: { epochMilliseconds: () => Date.now(), monotonicMilliseconds: () => performance.now() },
      bootstrapOperational: { ...operational, deliveryLeaseSeconds: 30 }, activationOperational: operational,
      limits: { challengeTTLSeconds: 600, deliveryLeaseSeconds: 30 }, http: { origin, bodyTimeoutMs: 1000 },
      maxConcurrentRequests: 4, alarmRecoveryDelayMilliseconds: 60000 };
  },
});
export class SyntheticHostDirectory extends hosts.Directory {}
export class SyntheticHostTarget extends hosts.Entitlement {
  constructor(ctx, env) { super(ctx, env); this.context = ctx; }
  inspect() {
    const sql = this.context.storage.sql;
    return { objectID: this.context.id.toString(), reservation: Array.from(sql.exec('SELECT * FROM device_licence_host_reservation')),
      bootstrap: Array.from(sql.exec('SELECT binding_digest,handle_digest,envelope_hash,status FROM device_bootstrap_state')),
      mail: Array.from(sql.exec('SELECT message FROM synthetic_mail')).map(row => JSON.parse(row.message)),
      alarms: Array.from(sql.exec('SELECT channel,wake_at FROM device_licence_alarm_channels ORDER BY channel')) };
  }
  async trigger() {
    this.context.storage.sql.exec('UPDATE device_licence_alarm_channels SET wake_at=?', Date.now() - 1);
    await super.alarm(); return { ok: true };
  }
}
export default { async fetch(request, env) {
  const url = new URL(request.url), directory = env.SYNTHETIC_DIRECTORY.getByName(`${realm}:directory`);
  const target = env.SYNTHETIC_TARGET.getByName(`${realm}:entitlement:${token(1)}`);
  if (url.origin === 'https://control.synthetic.invalid') {
    try {
      const { action } = await request.json(); let result;
      if (action === 'purchase') result = await directory.processPurchase(purchase);
      else if (action === 'inspect') result = await target.inspect();
      else if (action === 'trigger') result = await target.trigger();
      else if (action === 'recovery') { const ack = primitive(await directory.lookupReady(token(1))); result = await target.requestRecovery(ack, token(33)); }
      else if (action === 'block') { await env.SYNTHETIC_ORDER.getByName('synthetic-order').block(); result = await directory.refreshPurchase(purchase); }
      else throw Error('unknown action');
      return Response.json(result);
    } catch { return Response.json({ ok: false }, { status: 503 }); }
  }
  const edge = createDeviceLicenceAuthenticatedEdge({ enabled: true, ...common(env), origin, maxConcurrentRequests: 4,
    authenticate: async (original, id) => ({ decision: original.headers.get('X-Synthetic-Authority') === 'fixture-only' ? 'allow' : 'deny', realm, entitlementID: id }) });
  return edge.handle(request);
} };
