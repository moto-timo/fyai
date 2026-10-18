#!/bin/bash
# SPDX-License-Identifier: MIT
# An option of a question that allows one choice can carry a preview in
# Markdown. The page renders the preview of the option under the cursor below
# the options, and it follows the cursor. A fenced mermaid block is drawn as a
# diagram. An option with no preview shows none.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start ask_user_preview.json
driver=0
pty_run "$TEST_DIR/pty.out" \
    "$FYAI_BIN" -k test-key --theme dark \
    --set display/markdown=true --set display/stream=false \
    --set tools=true \
    --set api=chat-completions \
    --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model -i <<'PTY' ||
cols: 100
timeout: 20
wait_timeout: 10
steps:
  - type: ask me about the layout
  - wait: "Which layout?"
    timeout: session
  - wait-screen: "Preview · flat"
  - wait-screen: main.c
  - write: "\e[B"
  - wait-screen: "Preview · tree"
  - wait-gone: main.c
  - wait-screen: "│ Parser │"
  - wait-screen: "│ Emitter │"
  - write: "\e[B"
  - wait-gone: "Preview · tree"
  - wait-gone: Emitter
  - write: "\e[A"
  - wait-screen: "Preview · tree"
  - write: "\r"
  - wait-screen: Layout chosen.
PTY
    driver=$?
if grep -a -q "needs a libfytimui" "$TEST_DIR/pty.out"; then
    skip "this build has no page support"
fi
if [ "$driver" -ne 0 ]; then
    tail -c 2000 "$TEST_DIR/pty.out" >&2
    fail "the previews did not follow the cursor"
fi
assert_request 1 'json.loads([m for m in r["body"]["messages"] if m.get("role") == "tool"][-1]["content"])["answers"][0]["selected"] == ["tree"]'
mock_stop 2

pass
