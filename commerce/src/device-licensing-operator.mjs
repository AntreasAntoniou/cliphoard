// Binding-only operator surface. This module supplies no HTTP route or credentials.
import { WorkerEntrypoint } from 'cloudflare:workers';
import { decode } from '../licensing-prototype/protocol.mjs';
import { requireValue, captureRPC, deviceConfiguration } from './device-licensing-config.mjs';

export class DeviceLicenceOperator extends WorkerEntrypoint {
  #target(entitlementID) {
    decode(entitlementID, 16);
    const c = deviceConfiguration(this.env), namespace = this.env.DEVICE_LICENCE_ENTITLEMENTS;
    return namespace.get(namespace.idFromName(`${c.realm}:entitlement:${entitlementID}`));
  }
  async readAdmission(...args) {
    try {
      requireValue(args.length === 1);
      const [entitlementID] = args, raw = await this.#target(entitlementID).readAdmission();
      const descriptors = Object.getOwnPropertyDescriptors(raw);
      if (Object.hasOwn(descriptors, 'state')) {
        const result = captureRPC(raw, ['state']);
        requireValue(result.state === 'uninitialized'); return result;
      }
      const result = captureRPC(raw, ['entitlementID', 'revision', 'storedDecision', 'effectiveDecision']);
      requireValue(result.entitlementID === entitlementID && Number.isSafeInteger(result.revision) && result.revision > 0
        && ['hold', 'allow'].includes(result.storedDecision) && ['hold', 'allow'].includes(result.effectiveDecision)
        && (result.storedDecision === 'allow' || result.effectiveDecision === 'hold'));
      return result;
    } catch { throw Error('device_operator_unavailable'); }
  }
  async setAdmission(...args) {
    try {
      requireValue(args.length === 3);
      const [entitlementID, expectedRevision, decision] = args;
      requireValue(Number.isSafeInteger(expectedRevision) && expectedRevision > 0 && Number.isSafeInteger(expectedRevision + 1)
        && ['hold', 'allow'].includes(decision));
      const result = captureRPC(await this.#target(entitlementID).setAdmission({ expectedRevision, decision }),
        ['entitlementID', 'revision', 'decision']);
      requireValue(result.entitlementID === entitlementID && result.revision === expectedRevision + 1
        && ['hold', 'allow'].includes(result.decision) && (decision === 'allow' || result.decision === 'hold'));
      return result;
    } catch { throw Error('device_operator_unavailable'); }
  }
}
