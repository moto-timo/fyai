#!/bin/bash
# SPDX-License-Identifier: MIT
# Verify the default shell of a tool call: bash where the system has it, else
# /bin/sh. shell/shell and the shell of the call choose another.
set -eu
. "$(dirname "$0")/../harness.sh"

BASH_PATH=""
for p in /bin/bash /usr/bin/bash /usr/local/bin/bash; do
	[ -x "$p" ] && { BASH_PATH="$p"; break; }
done
[ -n "$BASH_PATH" ] || exit 77

fyai_test_setup

# No shell is named: $0 is the name that the shell was started as.
run_fyai tool shell '{"command": "echo name=$0"}'
assert_status 0
assert_stdout_contains 'name=bash'

# A bash feature that /bin/sh may lack runs.
run_fyai tool shell '{"command": "echo arr=${BASH_VERSION:+bash}"}'
assert_stdout_contains 'arr=bash'

# shell/shell names another shell for every call.
run_fyai --set shell/shell=/bin/sh tool shell '{"command": "echo name=$0"}'
assert_stdout_contains 'name=sh'

# The call names its own, which wins over shell/shell.
run_fyai --set shell/shell=/bin/sh tool shell '{"command": "echo name=$0", "shell": "'"$BASH_PATH"'"}'
assert_stdout_contains 'name=bash'
pass
