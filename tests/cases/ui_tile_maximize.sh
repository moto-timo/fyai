#!/bin/bash
# SPDX-License-Identifier: MIT
# In a fullscreen session the maximize button of a tile gives it the whole
# page: the transcript, the header and the prompt go, a hint row says the way
# back, and the keys are the tile's. The maximize button again, or Ctrl-],
# gives the page back.
set -eu
. "$(dirname "$0")/../harness.sh"

# run STEPS: a shell tile that prints SIZED, then the steps.
run()
{
    fyai_test_setup
    driver=0
    FYAI_PTY_ROWS=30 FYAI_PTY_COLS=100 \
    FYAI_PTY_INPUT="!sh -c 'while :; do printf \"\\r\\033[KTILE %s %s%s \" \"\$(stty size)\" SIZ ED; sleep 0.2; done'" \
    FYAI_PTY_NEEDLE="TILE" FYAI_PTY_TIMEOUT=20 \
    FYAI_PTY_AFTER="$1" \
    FYAI_PTY_AFTER_PAUSE=0 FYAI_PTY_AFTER_TIMEOUT=10 \
    "$PYTHON" "$TESTS_DIR/pty_driver.py" "$TEST_DIR/pty.out" \
        "$FYAI_BIN" -k test-key --theme dark \
        --set display/markdown=true --set display/screen=fullscreen \
        --set display/work_controls=full \
        -m mock-model -i || driver=$?
    if grep -a -q "needs a libfytimui" "$TEST_DIR/pty.out" 2>/dev/null; then
        skip "this build has no page support"
    fi
    if [ "$driver" -ne 0 ]; then
        tail -c 2000 "$TEST_DIR/pty.out" >&2
        fail "the maximized tile did not go as the case says"
    fi
}

# The button takes the page, and the same button gives it back.
run "wait-screen:SIZED|click:□|wait-screen:returns to the page|wait-gone:❯|click:□|wait-gone:returns to the page|wait-screen:❯|click:×|wait-gone:SIZED"
# Ctrl-] gives the page back too.
run "wait-screen:SIZED|click:□|wait-screen:returns to the page|raw:1d|wait-gone:returns to the page|wait-screen:❯|click:×|wait-gone:SIZED"
pass
