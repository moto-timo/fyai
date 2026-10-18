#!/bin/bash
# SPDX-License-Identifier: MIT
# Escape at an idle prompt does not end the session: it is too easy to press
# by mistake. With text typed it clears the text, as ^C does.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start ui_card_separation.json
# An Escape goes in one write with a NUL, which edits nothing: a control byte
# after ESC makes it a lone Escape at once, where a printable byte would make
# it Alt. Escape clears typed text, and on the empty prompt that follows it
# does nothing: the next command still runs.
pty_run "$TEST_DIR/pty.out" \
    "$FYAI_BIN" -k test-key --theme dark \
    --set display/markdown=true --set display/stream=true \
    --set display/screen=fullscreen \
    --set api=chat-completions \
    --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model -i <<'PTY' ||
rows: 40
cols: 100
steps:
  - type: first question
  - wait: banana
    timeout: session
  - write: "not sent"
  - wait-screen: not sent
  - write: "\e\x00"
  - wait-gone: not sent
  - write: "\e\x00"
  - type: "/status"
  - click: "□"
  - wait-screen: Auth / provider
  - write: "\e\x00"
  - wait-gone: Auth / provider
PTY
	fail "Escape at an idle prompt ended the session"

mock_stop 1
pass
