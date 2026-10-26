#!/bin/bash
# SPDX-License-Identifier: MIT
# A plain wait ends when an event arrives.
#
# The model starts a named wait that fires, then waits an hour with no name.
# The event must end the hour: a turn that sleeps on after the task it waited
# for has ended cannot be broken out of by the user either.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start wait_plain_event.json

run_fyai --set display/stream=false --set tools=true --set api=chat-completions \
	 --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model "wait"
assert_status 0

"$PYTHON" - "$TEST_DIR/requests.jsonl" <<'PYEOF' || fail "the plain wait slept on"
import json
import sys

reqs = [json.loads(l) for l in open(sys.argv[1]).read().splitlines()]
msgs = reqs[-1]["body"]["messages"]
results = [m["content"] for m in msgs if m.get("role") == "tool"]

if not any("ended early" in r for r in results):
    raise SystemExit("the event did not end the wait: %r" % results)
PYEOF

mock_stop 3
