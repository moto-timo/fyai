#!/bin/bash
# SPDX-License-Identifier: MIT
# A side question keeps running after the main turn frees its scratch state.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start btw_after_turn.json

pty_run "$TEST_DIR/pty.out" \
    "$FYAI_BIN" -k test-key --theme dark \
    --set display/markdown=true --set display/stream=false \
    --set api=responses --set "api_url=$MOCK_URL/v1/responses" \
    -m mock-model -i <<'PTY'
steps:
  - type: main question
  - wait: main question
    timeout: 1.5
  - write: "/btw side question\n"
  - wait: main question
    timeout: 1.5
  - wait: "btw: session/"
    timeout: session
  - touch: "${TEST_DIR}/release-main"
  - wait-screen: MAIN-ANSWER
  - touch: "${TEST_DIR}/release-side"
  - wait-screen: Esc closes
  - write: "\e"
  - wait-gone: SIDE-ANSWER
PTY

[ ! -f "$TEST_DIR/stream-wait-failed" ] ||
    fail "a held mock reply was never released"

mock_stop 2
pass
