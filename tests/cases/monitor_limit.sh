#!/bin/bash
# SPDX-License-Identifier: MIT
# The time limit of a monitor is the one the model asked for, up to the limit of
# the monitor tool. The ceiling of `shell/max_timeout_ms` is for a call that
# holds the turn, and it must not cut a monitor short: the model was told that
# the monitor runs as long as it asked.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start monitor_limit.json
export FYAI_TRACE="$TEST_DIR/trace.log"

run_fyai --set api=chat-completions --set display/stream=false --set tools=true \
	 --set shell/max_timeout_ms=60000 \
	 --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model "watch it"
assert_status 0
assert_stdout_contains 'finished.'
grep -q 'tool: shell limit 1800000 ms' "$TEST_DIR/trace.log" ||
	fail 'the monitor did not get the limit that it asked for'

# A monitor that reaches its limit says which limit it was, so the model can tell
# how long it ran. The wait for it is the one wait that this case makes: the limit is
# the state that it tests.
"$PYTHON" - "$TEST_DIR/requests.jsonl" <<'PYEOF' || fail 'the end of the monitor does not say its limit'
import json
import sys

last = json.loads(open(sys.argv[1]).read().splitlines()[-1])["body"]
results = [m["content"] for m in last["messages"] if m.get("role") == "tool"]
assert any("its time limit of 1 seconds passed" in r for r in results), results
PYEOF

mock_stop 5
pass
