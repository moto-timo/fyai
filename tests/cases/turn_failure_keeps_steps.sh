#!/bin/bash
# SPDX-License-Identifier: MIT
# A failure in the tool loop keeps the steps before it. The turn stops at the
# failure, the cause is reported, and the stored conversation holds the first
# round of tools with its result.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
# The turn fails when the second request would start.
mock_start turn_rounds.json
OPTS=(--set api=chat-completions --set display/stream=false --set tools=true
      --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model)
FYAI_TEST_TURN_ABORT=1 run_fyai "${OPTS[@]}" "run two rounds"
assert_stderr_contains 'injected failure of the turn'
run_fyai history --raw
assert_stdout_contains ROUND-ONE
assert_stdout_not_contains ROUND-TWO
mock_stop 1

pass
