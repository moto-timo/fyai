#!/bin/bash
# SPDX-License-Identifier: MIT
# A monitor turns the lines of a command into events.
#
# The command prints three lines at once and ends a second later. The model
# holds its turn on the monitor twice: the first wait returns the lines, the
# second returns the end of the command.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start monitor_lines.json

pty_run "$TEST_DIR/pty.out" \
    "$FYAI_BIN" -k test-key --theme dark \
    --set display/markdown=true --set display/stream=false \
    --set tools=true --set api=chat-completions \
    --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model -i <<'PTY'
timeout: 30
steps:
  - type: watch the lines
  - wait: Monitor done.
    timeout: session
PTY

"$PYTHON" - "$TEST_DIR/requests.jsonl" <<'PYEOF' || fail "the monitor events did not reach the model"
import json
import sys

reqs = [json.loads(l) for l in open(sys.argv[1]).read().splitlines()]
msgs = reqs[-1]["body"]["messages"]
results = "\n".join(m["content"] for m in msgs if m.get("role") == "tool")

for want in ("[monitor 'feed' started", "[monitor 'feed'] line-a",
             "line-b", "line-c", "[monitor 'feed' ended]"):
    if want not in results:
        raise SystemExit("missing %r in %r" % (want, results))
PYEOF

mock_stop 4
pass
