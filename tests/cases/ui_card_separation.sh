#!/bin/bash
# SPDX-License-Identifier: MIT
# A card typed after a turn stands off the answer above it by the separation
# that the stored exchange has. The rows of a live frame and of the frame after
# the next answer must agree.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start ui_card_separation.json
pty_run "$TEST_DIR/pty.out" \
    "$FYAI_BIN" -k test-key --theme dark \
    --set display/markdown=true --set display/stream=true \
    --set display/screen=fullscreen \
    --set api=chat-completions \
    --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model -i <<'PTY'
rows: 20
cols: 100
steps:
  - type: first question
  - wait: banana
    timeout: session
  - type: "yellow?"
  - wait-screen: second
PTY

if ! "$PYTHON" - "$TEST_DIR/pty.out" "$TESTS_DIR" <<'PY'
import sys

sys.path.insert(0, sys.argv[2])
from screen import Screen

data = open(sys.argv[1], "rb").read()
screen = Screen(20, 100)
end = b"\x1b[?2026l"
pos = 0
gaps = []
while True:
    at = data.find(end, pos)
    if at < 0:
        break
    screen.feed(data[pos:at + len(end)])
    pos = at + len(end)
    rows = [r.rstrip() for r in screen.display()]
    answer = [y for y, r in enumerate(rows) if r.strip() == "banana"]
    card = [y for y, r in enumerate(rows) if r.endswith("yellow?") and "│" in r]
    if answer and card:
        gap = card[0] - answer[0]
        if not gaps or gaps[-1] != gap:
            gaps.append(gap)
if len(gaps) != 1:
    raise SystemExit(f"the card moved from the answer: gaps {gaps}")
PY
then
    fail "the live card separation differs from the committed one"
fi

mock_stop 2
pass
