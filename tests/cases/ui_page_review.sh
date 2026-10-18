#!/bin/bash
# SPDX-License-Identifier: MIT
# /page review paints each area of the live page and names it: a slot by its
# id, a row by the flag that shows it. /page review off takes the names away.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
driver=0
FYAI_TRACE="$TEST_DIR/trace.log" \
pty_run "$TEST_DIR/pty.out" \
    "$FYAI_BIN" -k test-key --theme dark \
    --set display/markdown=true \
    -m mock-model -i <<'PTY' ||
cols: 100
timeout: 20
wait_timeout: 10
steps:
  - type: "/page review on"
  - wait: "page review: on"
    timeout: session
  - wait-screen: status.row
  - wait-screen: header.shown/blank
  - type: "/page review off"
  - wait-gone: status.row
PTY
    driver=$?
if grep -a -q "needs a libfytimui" "$TEST_DIR/pty.out" \
        "$TEST_DIR/trace.log" 2>/dev/null; then
    skip "this build has no page support"
fi
if [ "$driver" -ne 0 ]; then
    tail -c 2000 "$TEST_DIR/pty.out" >&2
    fail "/page review did not name the areas of the page and take them away"
fi
pass
