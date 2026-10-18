#!/bin/bash
# SPDX-License-Identifier: MIT
# With display/tool_display=inline, a terminal block is as wide as the
# transcript - the render width less the indent of tool output - and follows
# the window when it changes width: its program sees the new size. The page
# is $FYAI_INLINE_SCREEN, fullscreen by default.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start inline_tool_resize.json

pty_run "$TEST_DIR/pty.out" \
    "$FYAI_BIN" -b main -k test-key --theme dark \
    --set display/markdown=true --set display/stream=false \
    --set "display/screen=${FYAI_INLINE_SCREEN:-fullscreen}" \
    --set display/tool_display=inline \
    --set tools=true --set api=chat-completions \
    --set shell/input_poll_ms=0 \
    --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model -i <<'PTY' ||
cols: 100
timeout: 30
wait_timeout: 10
steps:
  - type: start a program
  - wait: ready.
    timeout: session
  - wait-row: "12 95"
  - resize: 80
  - wait-row: "12 75"
PTY
    fail "the terminal block did not follow the width of the window"

mock_stop 2
pass
