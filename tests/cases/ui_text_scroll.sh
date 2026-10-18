#!/bin/bash
# SPDX-License-Identifier: MIT
# A tool exchange that holds more rows than it shows has a scroll bar, and the
# bar scrolls it. With display/work_controls=full the tile of text takes a
# column for the bar, draws the arrows and the thumb, and the arrows move the
# rows it shows: the last rows follow the output, an arrow up moves back one
# row, an arrow down returns to the end, and the wheel over the rows moves
# three, and a key that is typed shows the end again. The rows are on rows 7 to 11 of a 30-row terminal.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start ui_text_scroll.json

pty_run "$TEST_DIR/pty.out" \
    "$FYAI_BIN" -k test-key --theme dark \
    --set display/markdown=true --set display/stream=false \
    --set display/work_controls=full \
    --set tools=true --set api=chat-completions \
    --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model -i <<'PTY' ||
rows: 30
cols: 100
timeout: 30
wait_timeout: 10
steps:
  - type: print the lines
  - wait: Print sixty lines
    timeout: session
  - wait-screen: row-060
  - wait-screen: "▴"
  - click: "▴"
  - wait-gone: row-060
  - wait-screen: row-055
  - click: "▾"
  - wait-screen: row-060
  - write: "\e[<64;10;9M"
  - wait-gone: row-060
  - wait-screen: row-053
  - write: "\e[<65;10;9M"
  - wait-screen: row-060
  - write: "\e[<64;10;9M"
  - wait-gone: row-060
  - wait-screen: row-053
  - write: "x"
  - wait-screen: row-060
  - write: "\x7f"
  - touch: "${TEST_DIR}/band-release"
  - wait-screen: done.
PTY
    fail "the scroll bar of a tile of text did not move its rows"

mock_stop 2

# With no history the band keeps the rows it shows, and has nothing to scroll.
fyai_test_setup
mock_start ui_text_scroll.json

pty_run "$TEST_DIR/none.out" \
    "$FYAI_BIN" -k test-key --theme dark \
    --set display/markdown=true --set display/stream=false \
    --set display/work_controls=full --set display/tool_history_lines=0 \
    --set tools=true --set api=chat-completions \
    --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model -i <<'PTY' ||
rows: 30
cols: 100
timeout: 30
wait_timeout: 10
steps:
  - type: print the lines
  - wait: Print sixty lines
    timeout: session
  - wait-screen: row-060
  - touch: "${TEST_DIR}/band-release"
  - wait-screen: done.
PTY
    fail "a band with no history did not finish"
if grep -a -q "▴" "$TEST_DIR/none.out"; then
    fail "a band with no history drew a scroll bar"
fi

mock_stop 2
pass
