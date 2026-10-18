#!/bin/bash
# SPDX-License-Identifier: MIT
# The browser renders the end of the selected session beside the branch view.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start responses_basic.json

pty_run "$TEST_DIR/preview.out" \
	"$FYAI_BIN" -k test-key --theme dark \
	--set display/markdown=true --set display/stream=false \
	--set api=responses --set display/branch_preview=right \
	--set display/branch_preview_width=48 \
	--set "api_url=$MOCK_URL/v1/responses" -m mock-model -i <<'PTY'
rows: 40
cols: 140
steps:
  - type: hello
  - wait: Hello from the mock responses provider.
    timeout: session
  - type: "/branches"
  - wait-screen: session end
  - write: "\e"
  - wait-gone: Esc close
PTY

mock_stop 1
pass
