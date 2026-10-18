#!/bin/bash
# SPDX-License-Identifier: MIT
# The page marks keyboard focus with a themed edge. Tiles use the first
# margin column; the prompt uses the column before its marker. The inactive
# location remains blank so changing focus does not move content.
set -eu
. "$(dirname "$0")/../harness.sh"

run_with()
{
    renderer=$1
    fyai_test_setup
    pty_run "$TEST_DIR/pty.out" \
        "$FYAI_BIN" -k test-key --theme dark \
        --set display/markdown=true \
        --set api=chat-completions \
        --set "api_url=http://127.0.0.1:9/v1/chat/completions" \
        -m mock-model -i <<'PTY' ||
rows: 30
cols: 100
timeout: 20
wait_timeout: 10
steps:
  - type: "!sh -c 'printf \"%s-%s\\n\" EDGE OUT; exec cat'"
  - wait: bang-1
    timeout: session
  - wait-screen: "▌ EDGE-OUT"
  - wait-gone: "▌❯"
  - write: "\x1d"
  - wait-gone: "▌ EDGE-OUT"
  - wait-screen: "  EDGE-OUT"
  - wait-screen: "▌❯"
  - type: "/kill bang-1"
  - wait-screen: stopping shell bang-1
PTY
        fail "$renderer: the edge did not follow the keys"
    if [ "$renderer" = page ] &&
       grep -a -q "needs a libfytimui" "$TEST_DIR/pty.out"; then
        skip "this build has no page support"
    fi
}

run_with page

pass
