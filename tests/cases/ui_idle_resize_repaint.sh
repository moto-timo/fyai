#!/bin/bash
# SPDX-License-Identifier: MIT
# Verify idle-session repaint after SIGWINCH.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start ui_reflow.json

pty_run "$TEST_DIR/pty.out" \
    "$FYAI_BIN" -k test-key --theme dark \
    --set display/markdown=true --set display/stream=true \
    --set api=chat-completions \
    --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model -i <<'PTY'
rows: 30
cols: 100
timeout: 40
steps:
  - type: say it
  - wait: Reflow streaming done.
    timeout: session
  - resize: 52
  - wait-repaint: Reflow streaming done.
PTY

"$PYTHON" - "$TEST_DIR/pty.out" <<'PY' || fail "an idle resize was never acted on"
import os
import sys

sys.path.insert(0, os.environ["TESTS_DIR"])
from tile_assert import frames

COLS = 52

# Inspect the last screen containing the resized answer.
last = None
for disp in frames(open(sys.argv[1], "rb").read(), 30, 100):
    if any("the window changes" in r for r in disp):
        last = disp
if last is None:
    raise SystemExit("the answer never reached the screen")
widest = max((len(r.rstrip()) for r in last), default=0)
if widest > COLS:
    raise SystemExit("a row of %d columns in a window of %d" % (widest, COLS))
PY

pass
