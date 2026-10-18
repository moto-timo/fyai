#!/bin/bash
# SPDX-License-Identifier: MIT
# $FYAI_CAST records what the terminal shows as an asciicast: a debug aid for a
# glitch of the display. The recording holds the output of the UI, a marker for
# a turn, and a resize. Only its owner can read it, and a program that the
# session starts does not record to the same file.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start chat_basic.json

mkdir "$TEST_DIR/casts"
FYAI_CAST="$TEST_DIR/casts" \
pty_run "$TEST_DIR/pty.out" \
    "$FYAI_BIN" -k test-key --theme dark \
    --set display/markdown=true --set display/stream=false \
    --set api=chat-completions \
    --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model -i <<'PTY'
steps:
  - type: first question
  - wait-screen: Hello from the mock provider.
  - resize: "24x80"
  - frame: 2
PTY

set -- "$TEST_DIR"/casts/fyai-*.cast
[ -f "$1" ] && [ "$#" -eq 1 ] || fail "expected one recording, found: $*"
"$PYTHON" - "$1" <<'PY' || fail "the recording is not the session"
import json
import os
import sys

lines = [json.loads(line) for line in open(sys.argv[1])]
head, events = lines[0], lines[1:]
assert head["version"] == 2 and head["width"] == 100, head
assert oct(os.stat(sys.argv[1]).st_mode & 0o777) == "0o600"
out = "".join(e[2] for e in events if e[1] == "o")
assert "Hello from the mock provider." in out, out[-400:]
assert any(e[1] == "m" and e[2] == "turn" for e in events), events
assert any(e[1] == "r" and e[2] == "80x24" for e in events), events
times = [e[0] for e in events]
assert times == sorted(times)
PY
mock_stop 1
pass
