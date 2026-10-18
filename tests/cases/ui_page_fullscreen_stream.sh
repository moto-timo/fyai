#!/bin/bash
# SPDX-License-Identifier: MIT
set -eu
. "$(dirname "$0")/../harness.sh"

# The header row shows the working directory, then the elapsed time. A long
# $TMPDIR, as on macOS, cuts the elapsed time off the row.
FYAI_TMPDIR_BASE=/tmp
fyai_test_setup
mock_start chat_fullscreen_stream.json
# Hold the stream across a PageUp event and observe two later status ticks.
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
  - wait: Streaming
    timeout: session
  - wait-screen: Streaming begins here.
  - wait-screen: " 1s"
  - write: "\e[5~"
  - wait-screen: " 3s"
  - snapshot: "${TEST_DIR}/activity.out"
  - touch: "${TEST_DIR}/resume-stream"
  - wait-screen: continues
PTY

if ! "$PYTHON" - "$TEST_DIR/activity.out" "$TESTS_DIR" <<'PY'
import sys

sys.path.insert(0, sys.argv[2])
from tile_assert import frames

marks = set()
for rows in frames(open(sys.argv[1], "rb").read(), 20, 100):
    if not any(" 2s" in row or " 3s" in row for row in rows):
        continue
    for row in rows:
        if "mock-model" in row:
            marks.add(row[:2])
if len(marks) < 2:
    raise SystemExit("status activity mark stopped after transcript scroll")
PY
then
    fail "fullscreen transcript scroll stopped the status activity mark"
fi

if ! "$PYTHON" - "$TEST_DIR/pty.out" "$TESTS_DIR" <<'PY'
import sys

sys.path.insert(0, sys.argv[2])
from screen import Screen

data = open(sys.argv[1], "rb").read()
screen = Screen(20, 100)
end = b"\x1b[?2026l"
pos = 0
live = final = None
while True:
    at = data.find(end, pos)
    if at < 0:
        break
    screen.feed(data[pos:at + len(end)])
    pos = at + len(end)
    rows = screen.display()
    complete = any("And continues." in row for row in rows)
    for y, row in enumerate(rows):
        if "Streaming begins here." not in row:
            continue
        if complete:
            final = y
        else:
            live = y
if live is None or final is None or live != final:
    raise SystemExit(f"live row {live}, committed row {final}")
PY
then
    fail "the live fullscreen response moved when it committed"
fi

mock_stop 1
pass
