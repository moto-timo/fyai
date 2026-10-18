#!/bin/bash
# SPDX-License-Identifier: MIT
# Verify the PTY driver: fresh-frame waits, screen waits, frame counts, a
# wait for a count, a file and the input row, the expansion of ${NAME}, and
# the status of the child after PTY EOF.
set -eu
. "$(dirname "$0")/../harness.sh"
fyai_test_setup_bare

# A program that reads two lines of input and then acts on each 'x' it reads,
# as MODE says. Its exit status is STATUS.
CHILD=$(cat <<'PY'
import os, sys, time, tty
tty.setraw(0)
os.write(1, b'\x1b[?25h')
line = b''
while not line.endswith(b'\n'):
    line += os.read(0, 1)
os.write(1, b'Done.\x1b[?2026l')
line = b''
while not line.endswith(b'\n'):
    ch = os.read(0, 1)
    if ch == b'x':
        if sys.argv[1] == 'held':
            while not os.path.exists(sys.argv[3]):
                time.sleep(0.01)
        if sys.argv[1] in ('fresh', 'held'):
            os.write(1, b'Done.\x1b[?2026l')
        elif sys.argv[1] == 'partial':
            os.write(1, b'Done.')
        elif sys.argv[1] == 'gone':
            os.write(1, b'\x1b[2J\x1b[H\x1b[?2026l')
        elif sys.argv[1] == 'stays':
            os.write(1, b'\x1b[?2026l')
        elif sys.argv[1] == 'frames':
            os.write(1, b'.\x1b[?2026l.\x1b[?2026l')
        elif sys.argv[1] == 'echo':
            os.write(1, b'PONG PONG\x1b[?2026l')
        continue
    line += ch
for fd in (0, 1, 2):
    os.close(fd)
time.sleep(0.1)
os._exit(int(sys.argv[2]))
PY
)
export CHILD

# check MODE STATUS ERROR < STEPS: run the child in MODE. ERROR is a text of
# the report that the driver must make, or empty when the run must pass.
check()
{
    local mode="$1" status="$2" error="$3" rc=0

    {
        cat <<'PTY'
wait_timeout: 0.3
timeout: 3
steps:
  - type: hello
  - wait: Done.
    timeout: session
PTY
        cat
    } >"$TEST_DIR/$mode$status.yaml"
    "$FYAI_BIN" __pty-driver "$TEST_DIR/$mode$status.yaml" \
        "$TEST_DIR/$mode$status.out" "$PYTHON" -c "$CHILD" "$mode" "$status" \
        "$TEST_DIR/release" 2>"$TEST_DIR/err" || rc=$?
    if [ -z "$error" ]; then
        [ "$rc" -eq 0 ] || { cat "$TEST_DIR/err" >&2; fail "$mode: the run failed"; }
    else
        [ "$rc" -ne 0 ] || fail "$mode: the run passed, expected: $error"
        grep -q -F "$error" "$TEST_DIR/err" ||
            { cat "$TEST_DIR/err" >&2; fail "$mode: not the expected report: $error"; }
    fi
}

# A frame end after the text, since the last key.
check fresh 0 '' <<'PTY'
  - write: x
  - wait-frame: Done.
PTY
check held 0 '' <<'PTY'
  - write: x
  - touch: "${TEST_DIR}/release"
  - wait-frame: Done.
PTY
check stale 0 'never contained' <<'PTY'
  - write: x
  - wait-frame: Done.
PTY
check partial 0 'never contained' <<'PTY'
  - write: x
  - wait-frame: Done.
PTY

# What is still on the screen, and how many frames were painted: a step that
# waits for either must read the screen and the frames, not the bytes that
# once carried them.
check gone 0 '' <<'PTY'
  - write: x
  - wait-gone: Done.
PTY
check stays 0 'never left the screen' <<'PTY'
  - write: x
  - wait-gone: Done.
PTY
check frames 0 '' <<'PTY'
  - write: x
  - frame: 2
PTY
check partial 0 'fewer than 1 frames' <<'PTY'
  - write: x
  - frame: 1
PTY
check fresh 7 'exited with status 7' <<'PTY'
PTY

# A count that is relative to the last key, a name from the environment, and
# a script that names a step it does not know.
check echo 0 '' <<'PTY'
  - write: x
  - wait-count: PONG
    more: 2
  - wait-screen: PONG PONG
PTY
check echo 0 "unknown key 'nonsense'" <<'PTY'
  - nonsense: x
PTY
check echo 0 'is not set' <<'PTY'
  - wait: "${PTYDRV_TEST_UNSET_NAME}"
PTY
check echo 0 '' <<'PTY'
  - touch: "${TEST_DIR}/made"
  - wait-file: "${TEST_DIR}/made"
    equals: ""
PTY

pass
