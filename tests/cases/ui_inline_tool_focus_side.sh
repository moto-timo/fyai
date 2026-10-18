#!/bin/bash
# SPDX-License-Identifier: MIT
# With the tiles in a column beside the transcript, a tile at the top of the
# column stands above a terminal block of the transcript, so Ctrl-T gives it
# the keys first: the order is that of the screen, not blocks before tiles.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start inline_tool_focus.json

pty_run "$TEST_DIR/pty.out" \
    "$FYAI_BIN" -b main -k test-key --theme dark \
    --set display/markdown=true --set display/stream=false \
    --set display/screen=fullscreen --set display/work_panels=on \
    --set display/tool_display=inline \
    --set tools=true --set api=chat-completions \
    --set shell/input_poll_ms=0 \
    --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model -i <<'PTY' ||
cols: 160
timeout: 30
wait_timeout: 10
steps:
  - type: start a program
  - wait: ready.
    timeout: session
  - wait-screen: ready.
  - type: "!sh -c 'echo TILE-OUT; exec cat'"
  - wait-screen: "▌ TILE-OUT"
  - write: "\x1d"
  - wait-screen: "▌❯"
  - write: "\x14"
  - wait-screen: "▌ TILE-OUT"
  - wait-gone: "▌❯"
  - write: "\x14"
  - wait-gone: "▌ TILE-OUT"
  - type: to-block
  - wait-screen: "▌   to-block"
  - write: "\x14"
  - wait-screen: "▌❯"
PTY
    fail "Ctrl-T did not follow the order of the screen"

mock_stop 2
pass
