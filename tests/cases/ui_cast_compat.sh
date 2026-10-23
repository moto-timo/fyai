#!/bin/bash
# SPDX-License-Identifier: MIT
# --cast-compat writes a plain asciicast: the header holds only the members of
# the format, and the markers that fyai adds from its trace stay out. The turn
# marker is a marker of the format and stays.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start chat_basic.json

pty_run "$TEST_DIR/pty.out" \
    "$FYAI_BIN" -k test-key --theme dark --cast "$TEST_DIR/run.cast" --cast-compat \
    --set display/markdown=true --set display/stream=false \
    --set api=chat-completions \
    --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model -i <<'PTY'
steps:
  - type: first question
  - wait-screen: Hello from the mock provider.
PTY

"$PYTHON" - "$TEST_DIR/run.cast" <<'PY' || fail "the recording is not a plain asciicast"
import json
import sys

lines = [json.loads(line) for line in open(sys.argv[1])]
head, events = lines[0], lines[1:]
assert set(head) <= {"version", "width", "height", "timestamp", "command"}, head
assert "fyai" not in head, head
marks = [e[2] for e in events if e[1] == "m"]
assert "turn" in marks, marks
assert all(m == "turn" for m in marks), marks
out = "".join(e[2] for e in events if e[1] == "o")
assert "Hello from the mock provider." in out, out[-400:]
PY
mock_stop 1
pass
