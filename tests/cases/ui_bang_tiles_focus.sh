#!/bin/bash
# SPDX-License-Identifier: MIT
# Verify focus cycling across bang-shell tiles and the prompt. The pane holds
# its tiles oldest first, so the cycle runs bang-1, bang-2, prompt: Ctrl-Tab
# leaves the tile that has the keys and each Ctrl-T takes the next one.
#
# The four focus keys go in one write, so they share a frame: each is acted on
# in order, and the keys after one reach whoever holds the keys then. The last
# waits for the way back to leave the status row: the keys are the prompt's
# again, which is where the commands below must land.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup

pty_run "$TEST_DIR/pty.out" \
    "$FYAI_BIN" -k test-key --theme dark \
    --set display/markdown=true --set display/work_min_tile_cols=30 \
    -m mock-model -i <<'PTY'
timeout: 20
steps:
  - type: "!sh -c 'printf FIRST; while :; do sleep 1; done'"
  - wait: FIRST
    timeout: session
  - wait-screen: "Ctrl-] returns to the prompt"
  - write: "\x1d"
  - wait-gone: "Ctrl-] returns to the prompt"
  - type: "!sh -c 'printf SECOND; while :; do sleep 1; done'"
  - wait-screen: "Ctrl-] returns to the prompt"
  - write: "\e[9;5u\x14\x14\x14"
  - wait-gone: "Ctrl-] returns to the prompt"
  - type: "/sessions"
  - wait-screen: Active sessions
  - type: "/kill bang-1"
  - wait-screen: stopping shell bang-1
  - type: "/kill bang-2"
  - wait-screen: stopping shell bang-2
PTY

"$PYTHON" - "$TEST_DIR/pty.out" "$TESTS_DIR" <<'PYEOF' || \
    fail "bang shells did not tile and cycle focus"
import sys

sys.path.insert(0, sys.argv[2])
from tile_assert import frames

shown = frames(open(sys.argv[1], "rb").read(), 30, 100)
if not any(any("FIRST" in row for row in frame) and
           any("SECOND" in row for row in frame) for frame in shown):
    raise SystemExit("the two bang screens never shared one frame")
# The way back is on the status row while a tile holds the keys; the tile
# itself gains no row, so nothing moves when focus does.
if not any("Ctrl-]" in row for frame in shown for row in frame):
    raise SystemExit("Ctrl-T never focused a tile")
if not any("Active sessions" in row for frame in shown for row in frame):
    raise SystemExit("/sessions did not list the live shells")
if not any("bang-1" in "\n".join(frame) and
           "bang-2" in "\n".join(frame) and
           "shell" in "\n".join(frame) for frame in shown):
    raise SystemExit("/sessions did not include both live shells")
if not any("stopping shell bang-1" in row for frame in shown for row in frame):
    raise SystemExit("/kill did not stop the named shell")
PYEOF

pass
