#!/bin/bash
# SPDX-License-Identifier: MIT
# A tool call that has no result is answered with a tool error. The model sees
# the failure and the turn goes on.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start turn_rounds.json
OPTS=(--set api=chat-completions --set display/stream=false --set tools=true
      --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model)
FYAI_TEST_COLLECT_FAIL=1 run_fyai "${OPTS[@]}" "run two rounds"
assert_stdout_contains 'finished.'
"$PYTHON" - "$TEST_DIR/requests.jsonl" <<'PYEOF' || fail 'the call was not answered'
import json
import sys

last = json.loads(open(sys.argv[1]).read().splitlines()[-1])["body"]
results = [m["content"] for m in last["messages"] if m.get("role") == "tool"]
if len(results) != 2 or any("returned no result" not in r for r in results):
    sys.stderr.write("expected two tool errors, got %r\n" % (results,))
    sys.exit(1)
PYEOF
mock_stop 3

pass
