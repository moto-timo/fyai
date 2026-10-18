#!/bin/bash
# SPDX-License-Identifier: MIT
# The scroll bar of a tile moves its view through the history of its program.
# With display/work_controls=full a tile has a bar that the page draws on its
# canvas. The
# wheel over the tile moves three rows, the arrow at the top of the bar moves
# one, and what the user types shows the live screen again.
set -eu
. "$(dirname "$0")/../harness.sh"

# The tile is the whole width of a 100-column terminal, under the blank row
# above the pane: its head takes rows 2 and 3, the screen starts on row 4,
# and the bar is the last column. The
# last row of the screen is the row of the cursor, under L200.
run_with()
{
    renderer=$1
    fyai_test_setup
    pty_run "$TEST_DIR/pty.out" \
        "$FYAI_BIN" -k test-key --theme dark \
        --set display/work_controls=full \
        --set retry/max_attempts=1 \
        --set api=chat-completions \
        --set "api_url=http://127.0.0.1:9/v1/chat/completions" \
        -m mock-model -i <<'PTY' ||
rows: 30
cols: 100
timeout: 20
wait_timeout: 10
steps:
  - type: "!sh -c 'seq -f L%03g 1 200; exec cat'"
  - wait: bang-1
    timeout: session
  - wait-screen: L200
  - wait-screen: "▴"
  - write: "\e[<64;20;10M"
  - wait-gone: L200
  - wait-screen: L198
  - write: "\e[<0;100;4M\e[<0;100;4m"
  - wait-gone: L198
  - wait-screen: L197
  - write: "x"
  - wait-screen: L200
  - write: "\x1d"
  - wait-gone: "Ctrl-]"
  - type: "/kill bang-1"
  - wait-screen: stopping shell bang-1
PTY
        fail "$renderer: the scroll bar did not move the view"
    if [ "$renderer" = page ] &&
       grep -a -q "needs a libfytimui" "$TEST_DIR/pty.out"; then
        skip "this build has no page support"
    fi
}

run_with page

pass
