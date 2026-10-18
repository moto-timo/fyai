#!/bin/bash
# SPDX-License-Identifier: MIT
# Verify that resizing a live bang session resizes its child PTY.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup

# The shell prints its columns at SIGWINCH; the width it was given must reach
# the screen. It writes READY in two parts once its trap stands, so only its
# output holds the word and not the command in the head: a resize before the
# trap would be lost.
pty_run "$TEST_DIR/pty.out" \
    "$FYAI_BIN" -k test-key --theme dark \
    --set display/markdown=true -m mock-model -i <<'PTY' ||
rows: 30
cols: 100
wait_timeout: 20
steps:
  - type: "!sh -c 'trap \"stty size | sed s/.*[[:space:]]/COLS:/\" WINCH; printf %s%s REA DY; sleep 30 & p=$!; until wait $p; do :; done'"
  - wait: bang-1
    timeout: session
  - wait-screen: READY
  - wait-screen: "Ctrl-] returns to the prompt"
  - write: "\x14"
  - wait-gone: "Ctrl-] returns to the prompt"
  - resize: 72
  - wait-screen: "COLS:70"
  - write: "\x1d"
PTY
    fail "resized bang terminal did not receive its inner work-pane size"


pass
