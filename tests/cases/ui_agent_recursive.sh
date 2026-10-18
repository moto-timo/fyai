#!/bin/bash
# SPDX-License-Identifier: MIT
# Grandchildren have compact progress in their parent's terminal.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start agent_recursive_progress.json

pty_run "$TEST_DIR/pty.out" \
	"$FYAI_BIN" -k test-key --theme dark \
	--set display/markdown=true --set display/stream=false \
	--set tools=true --set api=responses \
	--set "api_url=$MOCK_URL/v1/responses" -m mock-model -i <<'PTY'
steps:
  - type: delegate recursively
  - wait: Agent progress
    timeout: 8
  - wait: Recursive delegation complete.
    timeout: session
PTY

mock_stop 5
pass
