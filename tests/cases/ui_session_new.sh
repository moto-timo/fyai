#!/bin/bash
# SPDX-License-Identifier: MIT
# /session new continues on a new session branch with an empty conversation.
# The branch that the session leaves keeps its conversation.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start chat_basic.json
run_fyai -b main --set api=chat-completions \
	--set "api_url=$MOCK_URL/v1/chat/completions" \
	--set display/stream=false
assert_status 0

pty_run "$TEST_DIR/new.out" \
	"$FYAI_BIN" -k test-key -m mock-model -b main -i <<'PTY'
steps:
  - type: say hello
  - wait: Hello from the mock provider.
    timeout: session
  - wait-screen: Hello from the mock provider.
  - type: "/session new"
  - wait-screen: new session session/
PTY
mock_stop 1

run_fyai -b main dump state
assert_status 0
[ "$(grep -c "Hello from the mock provider." "$TEST_DIR/stdout")" = 1 ] || \
	fail "the branch left by /session new changed"

run_fyai branch list
assert_status 0
session=$(grep -o 'session/[A-Za-z0-9_./-]*' "$TEST_DIR/stdout" | head -n 1)
[ -n "$session" ] || fail "no session branch was made"
assert_state_absent "Hello from the mock provider." -b "$session" dump state

pass
