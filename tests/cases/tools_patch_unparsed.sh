#!/bin/bash
# SPDX-License-Identifier: MIT
# An apply_patch call that does not parse still has a title row, in the live
# view and in the stored history, with the cause beside it.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start tools_patch_unparsed.json

run_fyai --set display/markdown=true --set api=chat-completions \
	 --set display/stream=false --set tools=true \
	 --set api_url="$MOCK_URL/v1/chat/completions" -m mock-model "patch it"
assert_status 0
assert_stdout_contains "expected file operation"

run_fyai history
assert_status 0
grep -qE "●  patch" "$TEST_DIR/stdout" || fail "the history has no title row for the patch"
assert_stdout_contains "expected file operation"

mock_stop 2
pass
