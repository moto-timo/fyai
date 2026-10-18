#!/bin/bash
# SPDX-License-Identifier: MIT
# The buttons at the right of the head of a tile. With the mouse grabbed, the
# minimize button makes a tile a head under the screens, a click on that head
# shows it again, and the maximize button gives a tile the pane and gives it
# back.
set -eu
. "$(dirname "$0")/../harness.sh"

# Each program prints a line its command does not hold, so the line leaves
# the screen with the screen of its tile. In a 100-column terminal the minimize
# button of the first tile is column 45 and the maximize button of the second
# is column 98, on row 2, under the blank row above the pane. A minimized
# tile is shown again by a click on its
# head, which is found on the screen. The command of the second tile is whole
# only while that tile has the whole width, which says the layout moved.
run_with()
{
    renderer=$1
    fyai_test_setup
    pty_run "$TEST_DIR/pty.out" \
        "$FYAI_BIN" -k test-key --theme dark \
        --set display/markdown=true \
        --set display/work_controls=zoom \
        --set retry/max_attempts=1 \
        --set api=chat-completions \
        --set "api_url=http://127.0.0.1:9/v1/chat/completions" \
        -m mock-model -i <<'PTY' ||
rows: 30
cols: 100
timeout: 20
wait_timeout: 10
steps:
  - type: "!sh -c 'printf \"%s-%s\\n\" LEFT OUT; exec cat'"
  - wait: bang-1
    timeout: session
  - wait-screen: LEFT-OUT
  - write: "\x1d"
  - wait-gone: "Ctrl-]"
  - type: "!sh -c 'printf \"%s-%s\\n\" RIGHT OUT; exec cat'"
  - wait-screen: RIGHT-OUT
  - write: "\e[<0;45;2M\e[<0;45;2m"
  - wait-gone: LEFT-OUT
  - wait-screen: "RIGHT OUT; exec cat'"
  - click: "LEFT OUT; exec cat'"
  - wait-screen: LEFT-OUT
  - wait-gone: "RIGHT OUT; exec cat'"
  - write: "\e[<0;98;2M\e[<0;98;2m"
  - wait-gone: bang-1
  - write: "\e[<0;98;2M\e[<0;98;2m"
  - wait-screen: bang-1
  - write: "\x1d"
  - wait-gone: "Ctrl-]"
  - type: "/kill bang-1"
  - wait-screen: stopping shell bang-1
  - type: "/kill bang-2"
  - wait-screen: stopping shell bang-2
PTY
        fail "$renderer: a button of a tile did not act"
    if [ "$renderer" = page ] &&
       grep -a -q "needs a libfytimui" "$TEST_DIR/pty.out"; then
        skip "this build has no page support"
    fi
    grep -a -q "▁" "$TEST_DIR/pty.out" ||
        fail "$renderer: the head has no buttons"
}

run_with page

pass
