#!/bin/bash
# SPDX-License-Identifier: MIT
# Verify parallel full-screen shells across successive resize barriers. Each
# program paints its size, so after each resize both must stand on the screen
# at the rows the grid gives them, which are the same for both.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup

pty_run "$TEST_DIR/pty.out" \
    "$FYAI_BIN" -k test-key --theme dark \
    --set display/markdown=true -m mock-model -i <<'PTY' ||
rows: 30
cols: 100
wait_timeout: 10
steps:
  - type: "!${PYTHON} ${TESTS_DIR}/resize_tui.py A"
  - wait: A SIZE 20x98
    timeout: session
  - wait-screen: "Ctrl-]"
  - write: "\x1d"
  - wait-gone: "Ctrl-]"
  - type: "!${PYTHON} ${TESTS_DIR}/resize_tui.py B"
  - wait-screen: A SIZE 20x47
  - wait-screen: B SIZE 20x46
  - resize: "24x80"
  - wait-screen: A SIZE 14x37
  - wait-screen: B SIZE 14x36
  - resize: "28x80"
  - wait-screen: A SIZE 18x37
  - wait-screen: B SIZE 18x36
  - resize: "26x80"
  - wait-screen: A SIZE 16x37
  - wait-screen: B SIZE 16x36
  - resize: "32x80"
  - wait-screen: A SIZE 22x37
  - wait-screen: B SIZE 22x36
  - write: "\x1d"
PTY
    fail "parallel bang shells did not take the same rows after each resize"

pass
