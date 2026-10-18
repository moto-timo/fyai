#!/bin/bash
# SPDX-License-Identifier: MIT
# Ctrl-T gives the keys to the places that take them in the order the screen
# shows them, from the top down and from left to right: a terminal block of
# the transcript above the work pane comes before a tile of the pane, and
# after the last the prompt has the keys again. The pane takes a quarter of the
# terminal, so the block stays on the screen. The page is
# $FYAI_INLINE_SCREEN, fullscreen by default.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start inline_tool_focus.json

pty_run "$TEST_DIR/pty.out" \
    "$FYAI_BIN" -b main -k test-key --theme dark \
    --set display/markdown=true --set display/stream=false \
    --set "display/screen=${FYAI_INLINE_SCREEN:-fullscreen}" \
    --set display/tool_display=inline --set display/work_zoom_rows=quarter \
    --set tools=true --set api=chat-completions \
    --set shell/input_poll_ms=0 \
    --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model -i <<'PTY' ||
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
  - wait-gone: "▌❯"
  - type: to-block
  - wait-row: "▌   to-block"
  - write: "\x14"
  - wait-screen: "▌ TILE-OUT"
  - write: "\x14"
  - wait-screen: "▌❯"
PTY
    fail "Ctrl-T did not follow the order of the screen"

mock_stop 2
pass
