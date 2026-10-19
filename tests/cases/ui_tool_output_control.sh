#!/bin/bash
# SPDX-License-Identifier: MIT
# A tool result that holds a private CSI sequence (ESC [ ? 4 m), a device control
# string and carriage returns, such as the capture of a terminal program, must
# not blank the transcript of the fullscreen page: the rows of the exchange stay
# and the answer shows under it.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start ui_tool_output_control.json
pty_run "$TEST_DIR/pty.out" \
    "$FYAI_BIN" -k test-key --theme dark \
    --set display/markdown=true --set display/stream=false \
    --set display/screen=fullscreen \
    --set api=chat-completions \
    --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model -i <<'PTY'
rows: 30
cols: 100
steps:
  - type: go
  - wait-screen: FYAI_DONE_MARK
    timeout: session
  - wait-screen: what is this?
PTY

mock_stop 2
pass
