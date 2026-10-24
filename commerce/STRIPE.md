# Stripe Managed Payments for the direct edition

**Local implementation only. The deployment template is disabled.** This module does not prove live checkout, email delivery or customer activation. It creates one-time Managed Payments Checkout Sessions and issues the existing offline `CLIP1` licence after verifying payment. The Mac App Store edition keeps StoreKit. The older Lemon implementation remains separate and unchanged except that the shared signer now recognizes an explicitly selected Stripe order namespace.

## Purchase and recovery flow

`GET /` is the dedicated purchase front door. It explains US$10 USD, one-time plus applicable taxes, the direct-edition restriction, offline key recovery and the complete Free edition. The system/light/dark presentation uses inline CSS and JavaScript with exact CSP hashes and no external assets or analytics. No email or payment field is collected on this page. Configure the website's purchase link as an ordinary navigation to this origin; no cross-origin fetch is required.

Missing or invalid local configuration renders an unavailable page without a checkout button. Readiness checks the enable switches, concrete bindings, webhook/API-key shape, encryption key and signer/public-key pairing without calling Stripe. This does not replace provider activation or the real checkout/email rehearsal. The cancellation URL is restricted to this same origin's `/` or `/?cancelled=1` landing page.

The browser writes one random order UUID, attempt count and creation time to sessionStorage before its first request. Connection failures, manual retries, page reloads and returning from Checkout keep that identity. There are at most three manual requests and a 25-minute local attempt window; stale, corrupt or inaccessible state stops with a support message. No automatic retry or new order is minted to escape an uncertain result. Appearance preference is also stored in sessionStorage; no customer details or claim token are stored by this page. The returned redirect must be HTTPS on exactly `checkout.stripe.com`, without credentials or a non-default port.

The website sends a fresh UUIDv4 `orderRef` to `POST /checkout/stripe` on the configured origin. Reuse that reference when retrying the same attempt. Before creating any payable Session, the Worker requires a syntactically valid webhook secret, verifies the configured Stripe account and exact price, persists an independently random 256-bit claim token encrypted with AES-GCM, and checks the signer. It then creates hosted Checkout with `managed_payments.enabled=true`, `mode=payment`, an explicit integration currency and exactly one configured item. There is no fallback to ordinary Stripe payments. Secret shape checks do not prove that the endpoint is registered or that its secret matches Stripe; the provider rehearsal remains required.

The success redirect can show the key, but is not the delivery mechanism. Timestamped webhooks trigger current API reads of the full Session, line items, PaymentIntent, Charge and refunds before issuance. Closing Checkout does not prevent the email outbox from running. Stripe's fulfilment guidance requires a webhook because customers might not reach the success page. [Checkout fulfilment](https://docs.stripe.com/checkout/fulfillment?ui=full-page).

Managed Payments sends transaction receipts from Link. Its documented receipt settings do not provide a verified way to insert this application's per-order recovery token. Accordingly, this module sends a separate product email through the native Cloudflare Email Sending binding. It never assumes a Link receipt can recover a Cliphoard licence. [Managed Payments customer flow](https://docs.stripe.com/payments/managed-payments/how-it-works).

The recovery email contains the same private `GET /pro/claim?order=<UUID>&token=<random-token>` link on every retry. The page only retrieves an already-issued licence; it cannot issue a licence from a URL assertion. Every retrieval rechecks current payment and refund state. No customer login is implemented: the independently random token is a bearer secret. Anyone holding the link can retrieve that order's key.

## Validation and persistence

One SQLite-backed Durable Object serializes requests and alarms for each account, mode and order reference. Its record includes the exact configuration scope, order reference, Session ID, original issuance time, signed licence, monotone refund block and email-outbox status. A record with a different identity or configuration fails closed. Issuance is stable for `{o:"stripe:<mode>:<account>:<session>",i:<session creation seconds>,p:"pro",v:1}`; the shipping app's verifier/public key are unchanged.

The Worker verifies the raw webhook bytes using Stripe's HMAC-SHA256 signature and a five-minute timestamp tolerance. The request and webhook snapshot API version are both pinned to **2026-09-30.endive**. It accepts only the configured account/mode and retrieves provider objects instead of trusting the event's embedded payment assertion. Repeated or out-of-order paid events cannot undo a refund block. [Stripe webhooks](https://docs.stripe.com/webhooks), [API versioning](https://docs.stripe.com/api/versioning).

Only an exact one-time, per-unit, exclusive-tax price is supported: configured product, price, currency, base amount and quantity one, with no discount or shipping. Tax may increase the total; Session, line item, PaymentIntent and captured Charge amounts must agree. Manual price-currency options cannot override the explicit Checkout currency. Managed Payments' Adaptive Pricing may still present the customer's local currency while the integration amounts remain in the configured currency. [Manual currency selection](https://docs.stripe.com/payments/checkout/localize-prices/manual-currency-prices?payment-ui=stripe-hosted), [Adaptive Pricing](https://docs.stripe.com/payments/currencies/localize-prices/adaptive-pricing?payment-ui=stripe-hosted).

Any refund record, partial refunded amount or dispute blocks future issuance and retrieval, even if the refund later fails. This deliberately conservative policy requires an operator to resolve exceptional cases; paid replay never restores access. **An already-delivered offline licence cannot be revoked by this service.** No online revocation has been added to the app.

The record stores a token hash and authenticated ciphertext, never the plaintext token, signing seed, encryption key, email address, customer name or raw provider response. The encryption key is separate from the signing seed, with an explicit key ID; authenticated data binds the ciphertext to this order and configuration. The current deployment has one key ID. Missing or changed keys fail closed. Rotation requires a reviewed migration preserving old customer access; never overwrite or regenerate the key as an outage workaround.

Provider responses are bounded to 256 KiB with an eight-second deadline; redirects are rejected and raw provider errors are suppressed. Webhook bodies are limited to 64 KiB. Claim responses carry `no-store`, `no-referrer`, `noindex`, a restrictive CSP and no external resources, analytics or scripts. The template disables request/invocation logs and preview URLs. This is application-level data minimization, not a promise that Stripe, Cloudflare, browsers or email providers keep no operational records.

## Outbox and operator recovery

`EMAIL.send()` receives the current validated Stripe Session email address only in memory. The binding uses a configured sender and replies to the same support address. Its returned `messageId` is hashed for the stored acceptance marker. Cloudflare API acceptance is distinct from inbox delivery, and the API does not document an idempotency key. [Email Sending Workers API](https://developers.cloudflare.com/email-service/api/send-emails/workers-api/).

The outbox persists its attempt before sending and arms its next alarm before external work. It attempts at most 12 sends, using exponential delays capped at six hours. A crash after provider acceptance but before the local acceptance write may produce a duplicate email with the **same link and key**. Ordinary webhook replay does not resend accepted mail or reset exhausted retries. Errors are fixed codes and do not include email addresses or provider text.

The private Durable Object action `retryDelivery` resets a valid paid order's outbox after rechecking payment/refunds and the stored licence. It can recover an exhausted attempt or resend accepted-but-lost mail to the current Stripe-confirmed recipient. It accepts neither a replacement email nor a replacement token. It is deliberately **not a public HTTP route**. An authenticated, operator-only maintenance caller must invoke the `STRIPE_ORDERS` binding with the same account/mode/order name and `{action:"retryDelivery",orderRef}`. No such production maintenance caller is deployed by these files. Confirm operator access in the release rehearsal; do not expose this action through the website.

For webhook failures, inspect Stripe's delivery status and resend the original event through its supported dashboard. A receipt resend does not recreate a failed issuance. For a missing order after an uncertain Checkout creation, reconcile the original metadata and idempotency key; do not invent another order or delete its record. Automatic creation retries use unchanged parameters and only the first 30 minutes of the original fixed one-hour Session expiry.

## Configuration and secure bindings

Prepare separate test/live deployments, Durable Object namespaces, webhook signing secrets, encryption keys and rate-limit namespaces. Use synthetic signing keys in test. Keep production purchases disabled until the rehearsal below passes. Do not reuse or route over the existing Lemon claim path; choose a dedicated approved origin or an explicitly reviewed route migration.

| Configuration | Requirement |
| --- | --- |
| `STRIPE_ACCOUNT_ID`, `STRIPE_MODE` | Exact account ID and literal `test` or `live`. |
| `STRIPE_PRODUCT_ID`, `STRIPE_PRICE_ID` | Exact approved one-time direct-edition product/price for this mode. |
| `STRIPE_CURRENCY`, `STRIPE_UNIT_AMOUNT` | Integration currency and integer base amount; e.g. `usd` and `1000` for US$10 before applicable tax. |
| `PUBLIC_ORIGIN`, `CANCEL_URL`, `DOWNLOAD_URL` | Approved dedicated HTTPS origin without trailing slash; same-origin `/?cancelled=1` cancellation page; verified direct download. |
| `EXPECTED_PUBLIC_KEY_HEX` | Test: generated synthetic key. Live: exact public key compiled into the shipping app. |
| `CLIPHOARD_SIGNING_SEED` | Secret: canonical base64 of the existing matching 32-byte Ed25519 seed. A new unrelated signer would break the shipping app. |
| `STRIPE_API_KEY` | Secret: matching-mode restricted key. Checkout Sessions **Write**; Accounts, Prices, Payment Intents, and Charges and Refunds **Read**. No customer/product mutation or refund creation is used. Confirm every endpoint with the restricted key in test. |
| `STRIPE_WEBHOOK_SECRET` | Secret for this account-level snapshot webhook and mode. |
| `CLAIM_ENCRYPTION_KEY`, `CLAIM_KEY_ID` | Separate secret: canonical base64url of 32 random bytes, plus its stable nonsecret ID. |
| `STRIPE_ORDERS` | Binding to this deployment's `StripeOrder` Durable Object class; SQLite migration in the template. |
| `EMAIL`, `EMAIL_FROM` | Native `send_email` binding and a sender on an onboarded domain. Use the approved support mailbox. |
| `CHECKOUT_RATE_LIMITER` | Native rate-limit binding; template 5 attempts/60 seconds per account/IP digest. |
| Four enable switches | `CHECKOUT_ENABLED`, `ISSUANCE_ENABLED`, `DELIVERY_ENABLED`, `EMAIL_DELIVERY_ENABLED`: all initially `false`. Checkout refuses to open unless all four and the concrete email binding are available. |

Webhook endpoint: `https://<approved-origin>/webhooks/stripe`. Subscribe to `checkout.session.completed`, `checkout.session.async_payment_succeeded`, `checkout.session.async_payment_failed`, `refund.created`, `refund.updated`, `refund.failed` and `charge.refunded`, with the pinned snapshot API version. The webhook does not accept connected-account or organization-context events. Delayed payment completion stays pending until the API reports paid; an async failure cannot issue a key.

For native email, Cloudflare documents separate sender and recipient restriction variants. Use `allowed_destination_addresses` for the owned test inbox; production uses the approved `allowed_sender_addresses` restriction. Do not assume both variants combine without provider validation. Sender onboarding is required in either case. No SMTP token is needed by this native binding. [Send bindings](https://developers.cloudflare.com/email-service/configuration/send-bindings/).

The rate limiter is regional and approximate, not a global quota or a complete abuse defence. Only checkout creation is limited here; assign an operator to monitor aggregate failures and quotas without logging bearer URLs or customer payloads. [Workers rate limiting](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/).

The account, mode, product, price, currency, base amount, public key, API version and origin form the persistent scope. Do not change those under existing orders without a reviewed migration. The cancellation URL must also remain compatible with existing Sessions. Price evolution needs continued routing to historical order configuration; changing a global price variable alone would make older claims fail closed.

## Local tests and release rehearsal

Run with an explicitly verified Node runtime. This work used Node 24.11.0:

```sh
/usr/local/bin/node --version
/usr/local/bin/node --test --test-concurrency=1 test/*.test.mjs
```

Run from `commerce/` after the existing pinned dev dependencies are installed. Tests use synthetic keys and provider fixtures. The workerd case exercises real Durable Object storage, serialization, alarms and WebCrypto, with Stripe calls and email transport intercepted locally. The Swift test uses a temporary copy of the actual verifier with only a synthetic public-key seam; the app source is untouched. These tests do not prove provider permissions, a real purchase, native inbox delivery or customer UI activation.

For the standalone local visual fixture, run `/usr/local/bin/node scripts/preview-stripe.mjs`. It binds only loopback on an automatically selected port and prints three URLs: unavailable, synthetic ready and cancelled. Every POST returns 503; outbound network and email are disabled. The synthetic ready screen is labelled test checkout. It uses the same server-rendered page, CSP and browser script as the Worker. Stop it with Ctrl+C when visual review is complete. It is not a provider sandbox or a deployable server.

Before opening sales:

1. Review the exact origin, resource bindings, restricted-key grants, production-signer custody and existing sender. Configure secrets using the approved in-memory credential workflow; never place their values in files, command arguments, logs or browser/chat output. Do not rotate the shipping signer.
2. Deploy a separate test namespace with synthetic signer, test account/product/price, native email restricted to the owned test inbox, rate limiter and pinned-version webhook. Verify all required restricted-key reads plus actual Session creation in Managed Payments mode.
3. Complete a real provider test-mode checkout. Close the browser before its redirect. Verify webhook issuance, native email inbox arrival, recovery link, stable licence and offline activation with a synthetic-verifier test build. Test delayed payment, repeated events, wrong scope, partial refund, refund-before-paid replay, delivery outage and private operator resend. Preserve redacted IDs/statuses, never customer data or bearer links.
4. Confirm the billing/address/tax behavior and local-currency presentation against the configured US$10 exclusive-tax price. Confirm Link's separate receipt and the product support mailbox. Verify that the restricted production key covers the exact endpoint set and that the live signer matches the shipping app before uploading it.
5. Deploy the reviewed live configuration with all switches off, verify routes and disabled-state responses, and perform the separately authorized live fulfilment check. Test mode success is not live payment proof. Only then enable the reviewed entry points and link the public purchase button.

Rollback begins by disabling `CHECKOUT_ENABLED` and hiding the purchase entry point. Set `ISSUANCE_ENABLED=false` for an issuance defect while keeping valid refund handling active. Leave `DELIVERY_ENABLED=true` for existing buyers unless delivery itself is unsafe. Preserve the Durable Object namespace, encryption key and signer; reconcile failed webhooks/outboxes after repair before reopening checkout.
