#!/usr/bin/env bash
# Retired compatibility entrypoint. Never copies or removes models or app resources.
set -euo pipefail
printf '%s\n' 'Model embedding is disabled. All model weights must download and prepare locally after installation.' >&2
exit 2
