#!/bin/bash
# SPDX-License-Identifier: MIT
# Verify the full-screen TUI grid after SIGWINCH.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup

# Capture the zoomed grid before unzoom changes its dimensions.
# The screen holds the resized generation once its size line, which the
# program writes last, stands in a complete frame.
# Match the width without the "x": the size line is cut to the granted
# width, and a repaint racing the grant can slice "SIZE 20x50" so only
# the "50 GEN" tail reaches the capture. The clipped head still proves
# the child observed the new width, and the verdict below replays the
# full grid through the screen model, which is what rules on the rows.
# The old width ends in "98 GEN", so the shorter needle cannot match
# the pre-resize generation.
export PYTHON
pty_run "$TEST_DIR/pty.out" \
    "$FYAI_BIN" -k test-key --theme dark \
    --set display/markdown=true -m mock-model -i <<'PTY'
rows: 30
cols: 100
timeout: 40
wait_timeout: 20
steps:
  - type: "!${PYTHON} ${TESTS_DIR}/resize_tui.py"
  - wait: SIZE 20x98 GEN
    timeout: session
  - wait-screen: "Ctrl-] returns to the prompt"
  - write: "\x14"
  - wait-gone: "Ctrl-] returns to the prompt"
  - resize: 52
  - wait-screen: "50 GEN"
  - snapshot: "${TEST_DIR}/pattern.out"
  - write: "\x1d"
PTY

"$PYTHON" - "$TEST_DIR/pattern.out" "$TESTS_DIR" <<'PYEOF' || \
    fail "the resized full-screen pattern was corrupted"
import sys

sys.path.insert(0, sys.argv[2])
from screen import Screen

data = open(sys.argv[1], "rb").read()
clear = b"\x1b[0m\x1b[H\x1b[2J"
if clear in data:
    data = data[data.rfind(clear):]
s = Screen(30, 52)
s.feed(data)
lines = s.lines()
# Validate every row of the grid granted to the program.
import re

sized = [m for m in (re.search(r"SIZE (\d+)x50 GEN", line) for line in lines) if m]
if not sized:
    raise SystemExit("the resized generation is not visible")
rows = int(sized[-1].group(1))
for row in range(1, rows):
    token = "R%02d:" % row
    matches = [line.strip() for line in lines if token in line]
    if not matches:
        raise SystemExit("pattern row %d is missing" % row)
    body = matches[-1]
    fill = chr(ord("A") + row % 26)
    if body[len(token):].replace(fill, ""):
        raise SystemExit("pattern row %d contains foreign cells: %r" %
                         (row, body))
PYEOF

pass
