#!/bin/bash
# SPDX-License-Identifier: MIT
# A proposal that nobody could review is approved in a session: the review
# panel shows the diff of now, and the model is told the decision by an
# event that its next turn reads.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
run_fyai tool settings '{"action":"change","changes":[{"path":"temperature","value":0.5}],"explanation":"Warmer."}'
assert_status 0
assert_stdout_contains '"id": "p1"'

mock_start settings_approve.json
driver=0
pty_run "$TEST_DIR/pty.out" \
    "$FYAI_BIN" -k test-key --theme dark --branch main \
    --set display/markdown=true --set display/stream=false \
    --set tools=true \
    --set api=chat-completions \
    --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model -i <<'PTY' ||
rows: 40
cols: 100
timeout: 20
wait_timeout: 10
steps:
  - type: "/config approve p1"
  - wait: "Diff · made by fyai"
    timeout: session
  - wait-screen: "+temperature: 0.5"
  - wait-screen: "1. Reject"
  - write: "\e[B\r"
  - wait-screen: Noted the approval.
PTY
    driver=$?
if grep -a -q "needs a libfytimui" "$TEST_DIR/pty.out"; then
	skip "this build has no page support"
fi
if [ "$driver" -ne 0 ]; then
	tail -c 2000 "$TEST_DIR/pty.out" >&2
	fail "the approval did not reach the model"
fi
assert_request 0 'any("[config \x27p1\x27 approved]" in str(m.get("content")) for m in r["body"]["messages"])'
mock_stop 1

run_fyai config get temperature
assert_stdout_contains '0.5'
run_fyai config proposals --output json
assert_stdout_contains '"approved"'

# A catalogue proposal uses the same session review and approval path.
run_fyai tool settings '{"document":"catalog","action":"change","source":"https://example.test/model","changes":[{"path":"models/claude-opus-5.5/context_window","value":123456}],"explanation":"Correct the context window."}'
assert_status 0
assert_stdout_contains '"id": "p2"'
mock_start settings_approve.json
driver=0
pty_run "$TEST_DIR/pty.out" \
    "$FYAI_BIN" -k test-key --theme dark --branch main \
    --set display/markdown=true --set display/stream=false \
    --set tools=true \
    --set api=chat-completions \
    --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model -i <<'PTY' ||
rows: 40
cols: 100
timeout: 20
wait_timeout: 10
steps:
  - type: "/config approve p2"
  - wait: "Diff · made by fyai"
    timeout: session
  - wait-screen: "1. Reject"
  - write: "\e[B\r"
  - wait-screen: "config: proposal p2 is approved"
PTY
    driver=$?
if [ "$driver" -ne 0 ]; then
	tail -c 2000 "$TEST_DIR/pty.out" >&2
	fail "the catalogue approval did not reach the model"
fi
assert_request 0 'any("[config \x27p2\x27 approved]" in str(m.get("content")) for m in r["body"]["messages"])'
mock_stop 1
run_fyai catalog get models/claude-opus-5.5/context_window
assert_stdout_contains '123456'

pass
