// SYNTHETIC LOCAL HARNESS ONLY. Actual candidate classes are re-exported unchanged.
import worker from '../src/device-licensing-worker.mjs';
export { StripeOrder, DeviceLicenceDirectory, DeviceLicenceEntitlement } from '../src/device-licensing-worker.mjs';
export default { async fetch(request, env) {
  if (new URL(request.url).origin === 'https://control.synthetic.invalid') {
    const input = await request.json(), config = JSON.parse(env.DEVICE_LICENCE_CONFIG_V1);
    if (input.action === 'authority') {
      const value = await env.STRIPE_ORDERS.getByName(`${env.STRIPE_ACCOUNT_ID}:${env.STRIPE_MODE}:${config.qualification.orderRefs[0]}`).inspectDeviceAuthority();
      return Response.json({ state: value.state });
    }
    const target = env.DEVICE_LICENCE_ENTITLEMENTS.getByName(`${config.realm}:entitlement:${input.entitlementID}`);
    const result = await target.setAdmission({ expectedRevision: input.expectedRevision, decision: input.decision });
    return Response.json({ entitlementID: result.entitlementID, revision: result.revision, decision: result.decision });
  }
  return worker.fetch(request, env);
} };
