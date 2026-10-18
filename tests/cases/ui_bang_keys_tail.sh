#!/bin/bash
# SPDX-License-Identifier: MIT
# Verify that focus-key handling returns the input-frame suffix.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup

# Send Ctrl-] and /status in one input frame.
pty_run "$TEST_DIR/pty.out" \
    "$FYAI_BIN" -k test-key --theme dark \
    --set display/markdown=true -m mock-model -i <<'PTY'
timeout: 20
snapshot: "${TEST_DIR}/tail.out"
steps:
  - type: "!sh -c 'printf ZOOMED; sleep 5'"
  - wait: ZOOMED
    timeout: session
  - wait-screen: "Ctrl-]"
  - write: "\x1d/status\n"
  - wait-screen: Usage / total
PTY

"$PYTHON" - "$TEST_DIR/tail.out" "$TESTS_DIR" <<'PYEOF' || \
    fail "the line typed with the focus key was lost"
import sys

sys.path.insert(0, sys.argv[2])
from screen import Screen

s = Screen(30, 100)
s.feed(open(sys.argv[1], "rb").read())
shown = "\n".join(s.lines())
if "Usage / total" not in shown:
    raise SystemExit("the prompt never ran the line typed after the key")
PYEOF

pass
