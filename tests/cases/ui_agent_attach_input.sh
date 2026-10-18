#!/bin/bash
# SPDX-License-Identifier: MIT
# Attached input is processed by the existing grandchild before publication.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start agent_recursive_attach_input.json

pty_run "$TEST_DIR/pty.out" \
	"$FYAI_BIN" -b main -k test-key --theme dark \
	--set display/markdown=true --set display/stream=false \
	--set tools=true --set api=responses \
	--set "api_url=$MOCK_URL/v1/responses" -m mock-model -i <<'PTY'
steps:
  - type: delegate recursively
  - wait: Agent progress
    timeout: 8
  - write: "/branch attach main/agent:child/agent:grandchild\rATTACHED_INPUT\n"
  - wait: Agent progress
    timeout: 8
  - wait: ATTACHED_REPLY
    timeout: session
  - type: "/branch detach"
  - wait-screen: Recursive delegation complete.
PTY

assert_request 3 '"ATTACHED_INPUT" in json.dumps(r["body"])'
run_fyai -b main/agent:child/agent:grandchild transcript
assert_status 0
assert_stdout_contains "ATTACHED_REPLY"
mock_stop 6
pass
