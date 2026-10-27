# Disabled purchaser directory and public edge

The trusted directory reserves one exact account/mode/order/Session scope to a fixed entitlement and provisioning ID. Only a matching durable target acknowledgement publishes READY. READY means initialized; the target must still check current payment/purchaser/admission facts. Public lookup cannot allocate a target or authorize issuance.

The directory and target commit independently. A lost target acknowledgement leaves the directory pending; retry calls the same target and recovers its committed binding. A later conflicting acknowledgement removes an existing ready mapping from routing. This is a recoverable cross-object protocol, not an atomic cross-object transaction.

The namespace edge performs fixed-origin/route/method/header/body admission, then lookup before forwarding the original Request. Its finite slot remains held until trusted work settles. Production rate/abuse thresholds, authentication and namespace/provider bindings are still unselected.

## RPC acknowledgement capture

Cloudflare attaches Symbol.dispose to object-valued RPC results. The exported captureDeviceBootstrapDirectoryRPCAcknowledgement adapter copies exactly three primitive canonical fields, rejects extra keys/symbols/accessors, and calls the known disposer on both acceptance and rejection. The domain directory still accepts only its exact data schema. Null remains a lookup miss. A throwing disposer yields sanitized failure. Native Proxy traps and malicious transport implementations are outside this plain-data boundary.

Reference: https://developers.cloudflare.com/workers/runtime-apis/rpc/lifecycle/

## Evidence and limits

Sixteen focused directory/edge cases passed across preserved initial and corrected-fixture executions. Three new RPC cases passed after a missing fixture export was corrected; the initial import failure ran no behavioral assertions. The first coupled workerd attempts retained the exact Symbol.dispose incompatibility before the adapter repair.

One local Miniflare/workerd case then passed with one persisted directory and two SQLite target Durable Objects. It used the actual bootstrap service/mail, AES-GCM custody, shared alarm multiplexer and existing lifecycle/router. It recovered the deliberate lost acknowledgement, recreated the runtime with identical synthetic keys, reused committed setup descriptors, approved separate devices, observed both logical alarm handlers and rejected blocked payment despite READY. cf:false and zero Worker outbound calls do not establish absence of all host egress. The synthetic Miniflare loopback transport is not public TLS or provider delivery.

All new modules are opt-in components. No default Worker or shipping caller is wired. Real credentials, distinct production issuers/sealer recovery, authoritative provisioning and authentication, actual inbox delivery, hardware/Keychain and signed-app persistence, shipping activation and release remain separate gates. Legacy CLIP1 keys and perpetual issued receipts retain their prior behavior.
