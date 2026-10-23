# Cliphoard direct-edition fulfilment

A small Cloudflare Worker turns an authenticated Lemon Squeezy paid order into the direct app's offline `CLIP1` key. Lemon Squeezy's existing receipt email delivers a private key-retrieval link. This module sends no email and needs no Lemon API token. The Mac App Store edition continues to use StoreKit and cannot use these keys.

**Status: local implementation, disabled deployment template.** No cloud resources or provider product have been created by this module. No production signing key was read for development. Complete the release checks below before selling through it.

## Local verification

Use Node 22 or later; the Swift interoperability case additionally requires macOS and its Swift toolchain.

```sh
cd commerce
npm ci --ignore-scripts
npm test
npm audit
```

The tests generate temporary Ed25519 keys. They cover raw-body HMAC, wrong product/mode, provider payload variants, refunds, replay, concurrent stale reads, storage errors, privacy headers, and two independent local `workerd` instances. The Swift case substitutes only a synthetic public key in a temporary copy of the actual `Licence.swift`, then exercises its pure verifier. It does not launch Cliphoard or read/write app settings, clipboard, history or Keychain. The local runtime binds only loopback and is disposed after each case. No production dependencies are shipped; Miniflare is a pinned development dependency.

## Request and data contract

| Endpoint | Behavior |
| --- | --- |
| `POST /webhooks/lemon` | Verifies `X-Signature` against the original bytes with HMAC-SHA256, then validates event, configured identity and payment state. Maximum body: 64 KiB. |
| `GET /pro/claim?order=<UUID>` | Reads an already-issued record. Never accepts a payment assertion from a URL and never signs a key. |

The webhook requires `data.type=orders`, matching order/item IDs, exact configured store/product/variant, explicit attribute/item test-mode booleans, and a UUIDv4 order identifier. It supports one variant, one unit; configure a dedicated hosted checkout without other items or quantity selection. Explicit multi-item payloads are rejected. A payload that exposes only its first item cannot establish whether undisclosed items exist.

An `order_created` issues only when `status=paid`, `refunded` is `false` or `null`, and refund timestamp/amount indicate no refund. Amount formatting is not authorization: paid discounts, zero totals and converted fractional totals are allowed. Official webhook examples use nullable refund fields and microsecond timestamps; the separate API description uses boolean/integer examples. Both documented shapes are tested with synthetic identity/signatures. [Webhook examples](https://docs.lemonsqueezy.com/help/webhooks/example-payloads), [Order object](https://docs.lemonsqueezy.com/api/orders/the-order-object).

The signed payload is `{o:"ls:<mode>:<store>:<order>",i:<original creation seconds>,p:"pro",v:1}`. Stable identity/time makes independently retried issuance produce the same key in the tested WebCrypto runtimes. An existing record must match and verify before a duplicate is acknowledged. A signed `order_refunded` creates a separate append-only tombstone, including partial refunds and while new issuance is paused. A late paid event cannot overwrite that tombstone.

KV stores namespace IDs, order ID, issued time, a SHA-256 of the UUID, and the licence. It stores no customer name/email, raw order UUID, complete webhook, webhook secret or signing seed. Refund records contain only an order-scoped marker. No expiry is applied, so old receipt links can keep working. The worker does not log requests or exceptions.

## Exact setup fields

Prepare separate **test and live** Worker deployments and KV namespaces. Do not enable Workers Paid: this is a Free-plan candidate, subject to the capacity checks below. Keep the existing website's routes intact.

| Setting | Required value/source |
| --- | --- |
| Lemon store | Existing merchant store; confirm that live payments are approved. |
| Product / variant | One-time Cliphoard Pro direct-edition unlock; owner-approved price/currency/tax category; one unit. Record numeric store, product and variant IDs for the selected mode. |
| Native license-key generation | Off. Those keys do not carry the app's Ed25519 signature. |
| Product receipt button text | `Get your Cliphoard Pro key` |
| Receipt button URL | `https://<approved-origin>/pro/claim?order=[order_identifier]` |
| Product link / confirmation button | Same URL if desired; the receipt remains the recovery route. |
| Lemon webhook URL | `https://<approved-origin>/webhooks/lemon` |
| Lemon webhook events | `order_created`, `order_refunded` in the matching test/live mode. |
| Lemon webhook signing secret | Generate a unique 6–40 character secret and keep it in Bitwarden and the Worker secret binding only. |
| `LEMON_MODE` | Literal `test` or `live`. |
| `LEMON_STORE_ID`, `LEMON_PRODUCT_ID`, `LEMON_VARIANT_ID` | Exact positive numeric IDs from that provider configuration. |
| `PUBLIC_ORIGIN` | Approved HTTPS origin, without path or trailing slash. Requests on any other origin are rejected. |
| `DOWNLOAD_URL` | Verified direct-edition release page or final download URL. |
| `RECEIPTS` | KV binding to this deployment's new namespace. |
| `EXPECTED_PUBLIC_KEY_HEX` | Test: synthetic public key. Live: the exact public key compiled into the shipping direct app. |
| `CLIPHOARD_SIGNING_SEED` | Secret binding containing canonical base64 of the matching 32-byte Ed25519 seed; never a file path or PEM. |
| `LEMON_WEBHOOK_SECRET` | Secret binding matching the provider webhook. |
| `ISSUANCE_ENABLED`, `DELIVERY_ENABLED` | Initially `false`; enable only after the corresponding gates below. |

Lemon documents `[order_identifier]` for receipt/confirmation/product links. Fulfilment is driven by the webhook, so closing checkout before clicking does not lose the order. The worker uses its already-issued record when the customer clicks later. [Link variables](https://docs.lemonsqueezy.com/help/products/link-variables), [Receipt customization](https://docs.lemonsqueezy.com/help/checkout/customizing-receipt-emails).

`wrangler.example.toml` is intentionally incomplete: it has no route, namespace ID, account ID or secrets, and both switches are off. Copy it to the ignored `wrangler.local.toml` or `wrangler.live.toml` only during reviewed setup. Add an exact approved route or dedicated custom domain and the selected KV binding. Keep `workers_dev`, preview URLs and observability disabled. Do not enable payload/URL logging while diagnosing a real customer.

Deployment commands are deliberately not an npm script. After approval, use a pinned/reviewed Wrangler installation to create the selected namespace, deploy the reviewed configuration, and set the two secrets with `wrangler secret put NAME --config <selected-config>`. Feed values through stdin from an in-memory Bitwarden consumer; never place them in shell history, argv, config files, test output or logs. Secret upload and production signer access are separate release actions, not part of `npm test`. The existing local signer script takes a **file path**, whereas this Worker binding takes the **base64 seed value**; do not confuse them. The worker imports the seed as PKCS#8 and verifies each signature against the configured public key before storing it. [Workers Web Crypto](https://developers.cloudflare.com/workers/runtime-apis/web-crypto/).

## Required release rehearsal

1. Deploy the exact reviewed module to a separate test namespace with a synthetic signer. Confirm account plan, route boundaries, disabled request logs, correct IDs/mode and the download URL before enabling test issuance/delivery.
2. Complete a real Lemon **test-mode** checkout using its supported test payment flow. Verify the actual signed event is accepted, and that the native receipt substitutes the same UUID found in `attributes.identifier`. Preserve only a redacted schema/status receipt; never retain customer details or the live bearer URL in public evidence.
3. Follow the actual receipt link. Confirm a valid synthetic key, retry behavior, no cross-origin/subresource leakage, and actual Worker CPU usage within the Free-plan allowance. Test repeated delivery, refund-after-order, refund-before-replay, paused issuance and failed-delivery/manual-resend recovery. Use separate regional reads if available; local KV does not simulate edge propagation.
4. Decide whether UUID bearer links meet the intended privacy model. The provider documents a UUID identity, **not a secret-token security guarantee**. Anyone given a valid receipt URL can retrieve that key; hashing the UUID in KV does not add authorization. The implementation accepts UUIDv4 but has no customer-login check. If this is unsuitable, stop this route and use an independently random claim token delivered by an authenticated email/customer channel.
5. Before live secret upload, verify the shipping app's public key against the authorized existing seed in a private in-memory check. Development has not read that seed. Never replace or regenerate it merely to make deployment easier. Production-key custody, route and provider settings require explicit action-time review.
6. Configure the separate live namespace/IDs/secrets; repeat the enabled-state and negative-signature checks. Keep purchase links hidden until an authorized end-to-end live fulfilment check has passed. Do not infer a paid/live purchase from a synthetic or test-mode order.

The receipt page has `no-store`, `no-referrer`, `noindex`, a restrictive CSP and no third-party resources, JavaScript, analytics, cookies or automatic polling. These controls reduce browser/cache leakage; they do not promise that Cloudflare, browsers or the mail provider retain no internal records. Invocation logs can include full URLs, which is why the template disables them. [Workers Logs](https://developers.cloudflare.com/workers/observability/logs/workers-logs/).

## Free-plan limits and operational limits

Current Workers Free limits include 100,000 requests/day, 10 ms CPU per request and 128 MB memory. Local tests do not establish deployed CPU billing or account headroom. [Workers limits](https://developers.cloudflare.com/workers/platform/limits/).

KV Free includes 100,000 reads/day, 1,000 writes/day and 1 GB stored. Limits are shared with the account's other usage; excess operations fail. A new order normally costs two reads and one write, a claim two reads, and a refund one read plus one write. Duplicates normally avoid writes, but stale reads can cause repeated identical writes. Same-key writes are limited to one per second. A raw 1,000-write quota is therefore not a guaranteed 1,000-order capacity. [KV pricing](https://developers.cloudflare.com/kv/platform/pricing/), [KV limits](https://developers.cloudflare.com/kv/platform/limits/).

KV is eventually consistent: new records, negative lookups and refund markers can remain stale across regions for 60 seconds **or more**. Paid/refund operations are not atomic. The separate marker prevents overwriting a refund, but cannot guarantee immediate suppression of delivery during propagation. The page asks for a manual reload after a minute instead of automatic polling. Already-delivered offline keys remain valid after refund; the app has no online revocation system. [KV consistency](https://developers.cloudflare.com/kv/concepts/how-kv-works/).

There is no application rate limiter, reconciliation scheduler or external alert/email service. Invalid signatures cannot issue keys, but public request floods can consume Free quotas. Do not present this as high-volume or abuse-resistant infrastructure. Before launch, assign an operator to check Lemon's webhook delivery status and Cloudflare's aggregate errors/CPU/quota metrics, including after the first sales and refunds; do not turn on customer payload/receipt-URL logs.

Lemon acknowledges only HTTP 200 and retries failures a finite three times (5, 25, 125 seconds). The worker waits for its KV write before returning 200 and returns 503 on storage failures. After an outage or quota reset, inspect failed provider deliveries and manually resend the original signed events through Lemon's supported dashboard. Reconcile paid/refunded order IDs against the minimal KV records without exporting customer data. Receipt resends alone do not recreate a missing webhook record. [Webhook delivery](https://docs.lemonsqueezy.com/help/webhooks/webhook-requests).

## Rollback

First hide/disable the affected checkout entry points. Set `ISSUANCE_ENABLED=false` to stop new issuance while leaving `DELIVERY_ENABLED=true` for existing customers; valid refund events still record tombstones. For a delivery-security defect, also set `DELIVERY_ENABLED=false`, accepting that customers temporarily cannot retrieve keys. Roll back to the reviewed prior Worker version/configuration while preserving the namespace and signer. Do not delete KV, rotate the signing key or change the app's public key as an outage workaround. After repair, test with synthetic data, then reconcile/resend failed provider events before reopening sales. Keep the public status and support instructions accurate about any delivery delay.
