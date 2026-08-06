#!/usr/bin/env bash
# Build Cliphoard, install it over /Applications/Cliphoard.app, and relaunch.
#
# The local counterpart to Scripts/release.sh: no Developer ID, no notarization —
# it signs with the stable self-signed "Ditto Local Signing" identity so the macOS
# Accessibility grant (keyed to code identity) SURVIVES the swap and the global
# hotkey keeps working without re-granting.
#
# Usage: Scripts/deploy-local.sh [--skip-tests]
#
# Safe to run repeatedly while iterating: clip history lives in
# ~/Library/Application Support/Ditto (untouched), never inside the bundle.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
SKIP_TESTS="${1:-}"

# 1. Gate on the suite unless explicitly skipped — never deploy a red build.
if [ "$SKIP_TESTS" != "--skip-tests" ]; then
    echo "▸ Testing…"
    # Gate on swift test's EXIT CODE, not on scraping its output: the suite prints
    # a semantic-retrieval demo AFTER the summary line, so tailing the output
    # misses "0 failures" and would fail a perfectly green build.
    TEST_LOG="$(mktemp -t cliphoard-test)"
    if ! swift test >"$TEST_LOG" 2>&1; then
        echo "✗ tests failed — refusing to deploy:"
        grep -E "error:|failed|XCTAssert" "$TEST_LOG" | head -15
        echo "  (full log: $TEST_LOG)"
        exit 1
    fi
    echo "  ✓ $(grep -oE "Executed [0-9]+ tests, with [0-9]+ failures" "$TEST_LOG" | tail -1)"
    rm -f "$TEST_LOG"
fi

# 2. Build the universal, signed bundle.
bash "$ROOT/Scripts/build-app.sh" release

# 3. Quit the running instance (graceful first, then firm) so the binary is replaceable.
if pgrep -x Cliphoard >/dev/null; then
    echo "▸ Quitting running instance…"
    osascript -e 'tell application "Cliphoard" to quit' 2>/dev/null || true
    for _ in 1 2 3 4 5; do pgrep -x Cliphoard >/dev/null || break; sleep 1; done
    pgrep -x Cliphoard >/dev/null && { pkill -x Cliphoard; sleep 2; } || true
fi

# 4. Install + verify the signature, then relaunch.
echo "▸ Installing to /Applications…"
rm -rf /Applications/Cliphoard.app
cp -R "$ROOT/build/Cliphoard.app" /Applications/Cliphoard.app
codesign --verify --deep --strict /Applications/Cliphoard.app 2>/dev/null \
    && echo "  ✓ signature valid" || echo "  ! signature check reported an issue"

open /Applications/Cliphoard.app
sleep 2
PID="$(pgrep -x Cliphoard || true)"
if [ -n "$PID" ]; then
    echo "✓ Deployed and running (pid $PID) — summon with ⌃⌥⌘V"
else
    echo "✗ App did not start; try: open /Applications/Cliphoard.app"
    exit 1
fi
