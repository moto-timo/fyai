#!/bin/bash
# SPDX-License-Identifier: MIT
# A program that writes to a pipe but draws as for a terminal: the result is what
# its screen shows, as a terminal run gives, and not the bytes that moved the
# cursor. Output that does not draw stays as the program wrote it.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup

# Cursor movement and erase: the screen after them is the answer.
run_fyai tool shell '{"command": "printf \"line1\\n\\033[2K\\033[1Aover\\033[0m\\rX\\nlast\\n\""}'
assert_status 0
assert_stdout_contains 'Xver1'
assert_stdout_contains 'last'
assert_stdout_not_contains 'line1'
assert_stdout_not_contains "$(printf '\033')"

# A carriage return that overwrites a row, as a progress meter does.
run_fyai tool shell '{"command": "for i in 1 2 3; do printf \"%d%%\\r\" $i; done; printf \"done\\n\""}'
assert_stdout_contains 'done'
assert_stdout_not_contains '1%'

# Rows that scroll off the screen stay in the result, in order.
run_fyai tool shell '{"command": "printf \"\\033[1mhead\\033[0m\\n\"; i=1; while [ $i -le 200 ]; do echo row$i; i=$((i+1)); done"}'
assert_stdout_contains 'head'
assert_stdout_contains 'row1'
assert_stdout_contains 'row200'
assert_stdout_not_contains "$(printf '\033')"

# Standard error is drawn on its own screen.
run_fyai tool shell '{"command": "printf \"out\\n\"; printf \"a\\033[2Kb\\n\" >&2"}'
assert_stdout_contains 'out'
assert_stdout_contains 'b'
assert_stdout_not_contains "$(printf '\033')"

# Output that does not draw is not changed: a tab and a line that ends in CR LF stay.
run_fyai tool shell '{"command": "printf \"a\\tb\\nc\\r\\nd\\n\""}'
[ "$(head -n 2 "$TEST_DIR/stdout" | od -An -c | tr -d ' \n')" = 'a\tb\nc\r\n' ] ||
	fail 'output that does not draw was changed'

pass
