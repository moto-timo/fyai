#!/bin/bash
# SPDX-License-Identifier: MIT
# fyai cast: play a recording again, list its markers, and show its header. The
# recording is written by hand, with pauses short enough that the case waits for
# nothing, and one pause that the idle limit cuts.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup

"$PYTHON" - "$TEST_DIR/run.cast" <<'PY'
import json
import sys

with open(sys.argv[1], "w") as f:
    f.write(json.dumps({"version": 2, "width": 80, "height": 24, "timestamp": 1,
                        "command": "fyai",
                        "fyai": {"version": "9.9", "pid": 7, "model": "m"}}) + "\n")
    for event in ([0.01, "o", "first "], [0.02, "m", "turn"],
                  [0.03, "o", "second\r\n"], [0.04, "i", "k"],
                  [3600, "o", "after a long pause\r\n"],
                  [3600.01, "m", "turn: end, done, 2 rounds"]):
        f.write(json.dumps(event) + "\n")
PY

# The output events are written, in order, and the terminal is put back after them.
run_fyai cast play "$TEST_DIR/run.cast" --speed 100 --idle-limit 0.01
assert_status 0
assert_stdout_contains 'first second'
assert_stdout_contains 'after a long pause'
assert_stdout_not_contains 'turn: end'
assert_stdout_contains "$(printf '\033[?25h')"

# The markers are listed with their time.
run_fyai cast markers "$TEST_DIR/run.cast"
assert_status 0
assert_stdout_contains 'turn: end, done, 2 rounds'
assert_stdout_contains '3600'

# The header says what the program knew.
run_fyai cast info "$TEST_DIR/run.cast"
assert_status 0
assert_stdout_contains '9.9'
assert_stdout_contains 'Width'

# A file that is not a recording is refused with a cause.
printf 'not json\n' >"$TEST_DIR/bad.cast"
run_fyai cast info "$TEST_DIR/bad.cast"
assert_status_nonzero
assert_stderr_contains 'asciicast'

pass
