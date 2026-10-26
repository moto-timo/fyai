#!/bin/bash
# SPDX-License-Identifier: MIT
# Escape ends a plain wait.
#
# The model waits an hour with no name. The wait runs on the loop of the
# turn, so Escape must reach it there: a wait that ignores it leaves the user
# with a session that only ^C can leave.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start wait_plain_escape.json

pty_run "$TEST_DIR/pty.out" \
    "$FYAI_BIN" -k test-key --theme dark \
    --set display/markdown=true --set display/stream=false \
    --set tools=true --set api=chat-completions \
    --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model -i <<'PTY' ||
rows: 40
cols: 100
steps:
  - type: go to sleep
  - wait-file: "${TEST_DIR}/served"
    equals: "1"
    timeout: session
  - write: "\e\x00"
  - wait-screen: interrupted
PTY
	fail "Escape did not end the wait"

mock_stop 1
pass
