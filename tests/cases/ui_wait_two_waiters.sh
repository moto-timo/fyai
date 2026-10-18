#!/bin/bash
# SPDX-License-Identifier: MIT
# Two waits in one response wake on the same event.
#
# Both calls wait for one background sub-agent. The event is delivered once
# for each waiter: both results hold the report, and the turn loop does not
# deliver it again.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start wait_two_waiters.json

pty_run "$TEST_DIR/pty.out" \
    "$FYAI_BIN" -k test-key --theme dark \
    --set display/markdown=true --set display/stream=false \
    --set tools=true --set api=chat-completions \
    --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model -i <<'PTY'
timeout: 30
steps:
  - type: two waiters one event
  - wait: Both woke.
    timeout: session
PTY

"$PYTHON" - "$TEST_DIR/requests.jsonl" <<'PYEOF' || fail "the waiters did not both wake"
import json
import sys

reqs = [json.loads(l) for l in open(sys.argv[1]).read().splitlines()]
msgs = reqs[-1]["body"]["messages"]
results = [m["content"] for m in msgs if m.get("role") == "tool"]
users = [m["content"] for m in msgs if m.get("role") == "user"]

if sum("REPORT-ONE" in r for r in results) != 2:
    raise SystemExit("each waiter must get the report: %r" % results)
if any("REPORT-ONE" in u for u in users):
    raise SystemExit("the report came again as a turn: %r" % users)
PYEOF

mock_stop 4
pass
