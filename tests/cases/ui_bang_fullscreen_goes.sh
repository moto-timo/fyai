#!/bin/bash
# SPDX-License-Identifier: MIT
# A full-screen bang program draws on the alternate screen and leaves nothing
# on the primary one: when it ends its tile goes at once, with no dismissal.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
driver=0
FYAI_TRACE="$TEST_DIR/trace.log" \
pty_run "$TEST_DIR/pty.out" \
    "$FYAI_BIN" -k test-key --theme dark \
    --set display/markdown=true \
    -m mock-model -i <<'PTY' || driver=$?
rows: 30
cols: 100
timeout: 20
wait_timeout: 10
steps:
  - type: "!sh -c 'printf \"\\033[?1049h\"; printf %s%s ALT OUT; read x; printf \"\\033[?1049l\"'"
  - wait: bang-1
    timeout: session
  - wait-screen: ALTOUT
  - write: "\r"
  - wait-gone: bang-1
PTY
if [ "$driver" -ne 0 ]; then
    tail -c 2000 "$TEST_DIR/pty.out" >&2
    fail "the tile of a full-screen program did not go when it ended"
fi
pass
