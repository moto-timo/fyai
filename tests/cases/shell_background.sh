#!/bin/bash
# SPDX-License-Identifier: MIT
# A shell call with `background` returns at once, and the end of the command
# reaches the model as `[shell 'NAME' ended: status N]`. A command with no name
# is `bg-N`. `wait` with `for` holds the turn until the end.
set -eu
[ "$(uname -s)" = Linux ] || exit 77
. "$(dirname "$0")/../harness.sh"

FYAI_TMPDIR_BASE="$(dirname "$FYAI_BIN")"
fyai_test_setup
mkdir work

tool_results() {
	"$PYTHON" - "$TEST_DIR/requests.jsonl" <<'PYEOF'
import json
import sys

last = json.loads(open(sys.argv[1]).read().splitlines()[-1])["body"]
for m in last["messages"]:
    if m.get("role") == "tool":
        print(m["content"].replace("\n", " "))
PYEOF
}

mock_start shell_background.json
run_fyai --set sandbox_profile=dev --set api=chat-completions --set display/stream=false \
	 --set tools=true --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model \
	 --new "go"
assert_status 0
tool_results >"$TEST_DIR/results"
mock_stop 5
grep -q "shell 'job' started in the background" "$TEST_DIR/results" || fail "the call did not start the job"
grep -q "shell 'job' ended: status 3" "$TEST_DIR/results" || fail "the end of the job was not reported"
grep -q "shell 'bg-1' started in the background" "$TEST_DIR/results" || fail "a job with no name got no bg- name"
grep -q "shell 'bg-1' ended: status 0" "$TEST_DIR/results" || fail "the end of the unnamed job was not reported"
[ "$(cat work/bg.out)" = ran ] || fail "the command did not run"
pass
