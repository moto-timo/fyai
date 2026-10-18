#!/bin/bash
# SPDX-License-Identifier: MIT
# A grandchild's ask_user call cannot open the root input prompt.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start agent_recursive_question.json

pty_run "$TEST_DIR/pty.out" \
	"$FYAI_BIN" -k test-key --theme dark \
	--set display/markdown=true --set display/stream=false \
	--set tools=true --set api=responses \
	--set "api_url=$MOCK_URL/v1/responses" -m mock-model -i <<'PTY'
steps:
  - type: delegate recursively
  - wait: Recursive delegation complete.
    timeout: session
PTY

assert_request 3 '"ask_user is available only in the root session" in json.dumps(r["body"])'
mock_stop 6
pass
