#!/bin/bash
# SPDX-License-Identifier: MIT
# A queued user message joins the next request after a tool call completes.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
printf 'tool input\n' > data.txt
mock_start chat_tool_pending_user.json

pty_run "$TEST_DIR/pending.out" \
	"$FYAI_BIN" -b main -k test-key -m mock-model -i \
	--set display/stream=false --set api=chat-completions \
	--set tools=true --set "api_url=$MOCK_URL/v1/chat/completions" <<'PTY'
steps:
  - type: read the file
  - wait-file: "${TEST_DIR}/served"
    equals: "1"
    timeout: 1.5
  - write: "also explain the result\n"
  - wait: also explain the result
    timeout: 1.5
  - wait-frame: also explain the result
    from: start
    timeout: session
  - touch: "${TEST_DIR}/release-1"
  - wait: I saw the follow-up during the tool loop.
    timeout: session
PTY

mock_stop 2
assert_request 0 'r["body"]["messages"][-1]["content"] == "read the file"'
assert_request 1 'any(m.get("role") == "user" and m.get("content") == "also explain the result" for m in r["body"]["messages"])'
assert_request 1 'any(m.get("role") == "tool" for m in r["body"]["messages"])'
assert_state_contains "also explain the result" dump state

"$PYTHON" - "$SCENARIOS_DIR/responses_tools_read_file.json" \
	"$TEST_DIR/responses-pending.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fp:
    scenario = json.load(fp)
scenario["steps"][0]["wait_for"] = "release-2"
with open(sys.argv[2], "w", encoding="utf-8") as fp:
    json.dump(scenario, fp)
PY
mock_start "$TEST_DIR/responses-pending.json"

pty_run "$TEST_DIR/responses.out" \
	"$FYAI_BIN" -b main -k test-key -m mock-model -i \
	--set display/stream=false --set api=responses \
	--set response_chain=true --set tools=true \
	--set "api_url=$MOCK_URL/v1/responses" <<'PTY'
steps:
  - type: read the file
  - wait-file: "${TEST_DIR}/served"
    equals: "1"
    timeout: 1.5
  - write: "also explain the result\n"
  - wait: also explain the result
    timeout: 1.5
  - wait-frame: also explain the result
    from: start
    timeout: session
  - touch: "${TEST_DIR}/release-2"
  - wait: "The file says: mock data payload."
    timeout: session
PTY

mock_stop 2
assert_request 1 'any(i.get("role") == "user" for i in r["body"]["input"])'
assert_request 1 'any(i.get("type") == "function_call_output" for i in r["body"]["input"])'
pass
