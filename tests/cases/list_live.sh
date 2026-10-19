#!/bin/bash
# SPDX-License-Identifier: MIT
# The list verb names the kinds of live work. A verb has none, so each kind is
# an empty table, and --output json gives an empty sequence.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup

for what in sessions shells agents waits monitors questions messages; do
	run_fyai list "$what"
	assert_status 0
	assert_stdout_contains "none"
	run_fyai list "$what" --output json
	assert_status 0
	assert_stdout_contains "[]"
done

run_fyai list nonsense
assert_status 1

pass
