#!/bin/bash
# SPDX-License-Identifier: MIT
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start chat_stream_tool_overlap.json

pty_run "$TEST_DIR/pty.out" \
	"$FYAI_BIN" -k test-key --theme dark \
	--set display/markdown=true --set display/stream=true \
	--set tools=true --set api=chat-completions \
	--set "api_url=$MOCK_URL/v1/chat/completions" \
	-m mock-model -i <<'PTY'
steps:
  - type: run a streamed tool
  - wait: "1"
    timeout: 1.5
  - wait: Streaming tool overlap verified.
    timeout: session
PTY

"$PYTHON" - "$TEST_DIR/pty.out" <<'EOF' ||
	fail "streamed tool workband touched unterminated assistant prose"
import re
import sys

data = open(sys.argv[1], "rb").read()
plain = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", data)
bad = rb"shellshellshell[^\r\n]*touch s"
if re.search(bad, plain):
    raise SystemExit("tool invocation shared the assistant prose row")
EOF

mock_stop 2
pass
