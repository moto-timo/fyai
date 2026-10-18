#!/bin/bash
# SPDX-License-Identifier: MIT
# display/focus_mark=edge marks the tile that has the keys with the edge
# column alone: the cells of the tile keep the ground of the terminal. With
# wash, the default, the same tile stands on the focus ground.
set -eu
. "$(dirname "$0")/../harness.sh"

run_with()
{
    mark=$1
    fyai_test_setup
    pty_run "$TEST_DIR/pty.out" \
        "$FYAI_BIN" -k test-key --theme dark \
        --set display/markdown=true \
        --set 'display/focus_bg="#203040"' \
        --set "display/focus_mark=$mark" \
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
  - snapshot: "${TEST_DIR}/focus.out"
  - write: "\x1d"
  - type: "/kill bang-1"
  - wait-screen: stopping shell bang-1
PTY
        fail "$mark: the session did not go as the case says"
    if grep -a -q "needs a libfytimui" "$TEST_DIR/pty.out"; then
        skip "this build has no page support"
    fi
    "$PYTHON" - "$TEST_DIR/focus.out" "$TESTS_DIR" "$mark" <<'PY' ||
import sys

sys.path.insert(0, sys.argv[2])
from screen import Screen

s = Screen(30, 100)
s.feed(open(sys.argv[1], "rb").read())
ground = s.ground_at("EDGE-OUT")
if sys.argv[3] == "edge" and ground is not None:
    raise SystemExit("edge: the focused tile has a ground: %r" % (ground,))
if sys.argv[3] == "wash" and ground is None:
    raise SystemExit("wash: the focused tile has no ground")
PY
        fail "$mark: the focused tile is marked wrongly"
}

run_with wash
run_with edge

pass
