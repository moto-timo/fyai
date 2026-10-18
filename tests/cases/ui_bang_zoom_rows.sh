#!/bin/bash
# SPDX-License-Identifier: MIT
# Verify named and fixed zoom-row policies.
set -eu
. "$(dirname "$0")/../harness.sh"

# The shell reports its size every 0.2 seconds, so the size a grant gives it
# reaches the screen; the case waits for that size on the screen.
SHELL_SIZE="!sh -c 'while :; do stty size; sleep 0.2; done'"

# The size in the last row of the screen of @1 that holds one.
last_size()
{
    "$PYTHON" - "$1" "$2" "$TESTS_DIR" <<'PYEOF'
import re
import sys

sys.path.insert(0, sys.argv[3])
from screen import Screen

END = b"\x1b[?2026l"
data = open(sys.argv[1], "rb").read()
screen = Screen(32, 100)
pos = 0
rows = None
while True:
    i = data.find(END, pos)
    if i < 0:
        break
    screen.feed(data[pos:i + len(END)])
    pos = i + len(END)
    shown = [int(m[1]) for line in screen.display()
             if (m := re.search(r"(?:^|\s)(\d+) (\d+)\s*$", line))]
    if shown:
        rows = shown[-1]
if rows is None:
    raise SystemExit("the shell did not report its size")
if rows != int(sys.argv[2]):
    raise SystemExit("the shell has %d rows; expected %s" % (rows, sys.argv[2]))
PYEOF
}

run_size()
{
    policy=$1
    expected=$2
    fyai_test_setup
    export SHELL_SIZE
    export expected
    export policy
    pty_run "$TEST_DIR/pty-$policy.out" \
        "$FYAI_BIN" -k test-key --theme dark \
        --set display/markdown=true \
        --set "display/work_zoom_rows=$policy" -m mock-model -i <<'PTY'
rows: 32
cols: 100
steps:
  - type: "${SHELL_SIZE}"
  - wait: bang-1
    timeout: session
  - wait-screen: "Ctrl-]"
  - write: "\x1d"
  - wait-gone: "Ctrl-]"
  - type: "/zoom bang-1"
  - wait-screen: "Ctrl-]"
  - wait-screen: "${expected} 98"
  - snapshot: "${TEST_DIR}/zoom-${policy}.out"
  - write: "\x1d"
PTY
    last_size "$TEST_DIR/zoom-$policy.out" "$expected" ||
        fail "a zoomed $policy pane did not give the shell $expected rows"
}

run_focused_size()
{
    policy=$1
    expected=$2
    fyai_test_setup
    export SHELL_SIZE
    export expected
    export policy
    pty_run "$TEST_DIR/focused.out" \
        "$FYAI_BIN" -k test-key --theme dark \
        --set display/markdown=true \
        --set "display/work_zoom_rows=$policy" -m mock-model -i <<'PTY'
rows: 32
cols: 100
steps:
  - type: "${SHELL_SIZE}"
  - wait: bang-1
    timeout: session
  - wait-screen: "Ctrl-]"
  - wait-screen: "${expected} 98"
  - snapshot: "${TEST_DIR}/focused-${policy}.out"
  - write: "\x1d"
PTY
    last_size "$TEST_DIR/focused-$policy.out" "$expected" ||
        fail "a focused $policy pane did not give the shell $expected rows"
}

run_key_cycle()
{
    fyai_test_setup
    export SHELL_SIZE
    pty_run "$TEST_DIR/cycle.out" \
        "$FYAI_BIN" -k test-key --theme dark \
        --set display/markdown=true \
        --set display/work_zoom_rows=half -m mock-model -i <<'PTY'
rows: 32
cols: 100
steps:
  - type: "${SHELL_SIZE}"
  - wait: bang-1
    timeout: session
  - wait-screen: "14 98"
  - write: "\e[116;6u"
  - wait-screen: "work pane height: quarter"
  - wait-screen: "6 98"
  - write: "\x1d"
PTY
}

# The cap includes surrounding UI and shell chrome. The prompt block stands
# whether the tile holds the keys or not, so these do not change with focus.
run_focused_size half 14
run_key_cycle
run_size half 14
run_size quarter 6
run_size 12 10
pass
