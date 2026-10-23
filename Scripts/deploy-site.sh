#!/usr/bin/env bash
# Deploy only the public static site, using an in-memory Cloudflare token.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${CLOUDFLARE_API_TOKEN:?Provide the scoped Cloudflare API token through the environment; never commit it.}"
export WRANGLER_SEND_METRICS=false
export WRANGLER_WRITE_LOGS=false
export WRANGLER_LOG_SANITIZE=true
exec npx --yes wrangler@4.152.0 deploy --config wrangler.site.json "$@"
