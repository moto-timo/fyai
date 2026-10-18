#!/bin/bash
# SPDX-License-Identifier: MIT
# With display/completion=auto the popup opens as a slash command is typed,
# without a Tab. Enter then takes the selection, and Escape closes the popup
# until the line changes.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start chat_basic.json
driver=0
pty_run "$TEST_DIR/pty.out" \
    "$FYAI_BIN" -k test-key --theme dark \
    --set display/markdown=true --set display/stream=false \
    --set display/screen=fullscreen \
    --set display/completion=auto \
    --set api=chat-completions \
    --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model -i <<'PTY' ||
rows: 24
cols: 100
timeout: 20
wait_timeout: 10
steps:
  - type: first question
  - wait: Hello
    timeout: session
  - wait-screen: Hello from the mock provider.
  - write: "/bra"
  - wait-screen: open the branch browser
  - wait-screen: list, create, and manage branches
  - write: "\e[B"
  - write: "\r"
  - wait-gone: open the branch browser
  - wait-screen: "/branches"
  - write: "\x7f\x7f\x7f\x7f\x7f\x7f\x7f\x7f\x7f\x7f"
  - wait-gone: "/branches"
  - write: "/bra"
  - wait-screen: open the branch browser
  - write: "\e[27u"
  - wait-gone: open the branch browser
  - write: "n"
  - wait-screen: open the branch browser
  - write: "\x7f\x7f\x7f\x7f\x7f"
  - wait-gone: open the branch browser
PTY
    driver=$?
if [ "$driver" -ne 0 ]; then
    tail -c 2000 "$TEST_DIR/pty.out" >&2
    fail "the automatic completion popup did not go as the case says"
fi
mock_stop 1
pass
