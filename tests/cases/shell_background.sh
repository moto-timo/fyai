#!/bin/bash
# SPDX-License-Identifier: MIT
# A shell call with `background` starts the command detached and returns at once.
# The command has a session of its own and /dev/null for standard input and error,
# it is still there for the next call of the exchange, and it ends with the exchange.
set -eu
[ "$(uname -s)" = Linux ] || exit 77
command -v flock >/dev/null || exit 77
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

for cover in auto none; do
	rm -f work/bg.*
	mock_start shell_background.json
	run_fyai --set sandbox_profile=dev --set api=chat-completions --set display/stream=false \
		 --set tools=true --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model \
		 --set "sandbox_cover=$cover" --set sandbox_scope=exchange --new "go"
	assert_status 0
	tool_results >"$TEST_DIR/results"
	mock_stop 3
	grep -q 'runs in the background' "$TEST_DIR/results" || fail "$cover: the call did not say it detached"
	grep -q 'fd0=/dev/null fd2=/dev/null' "$TEST_DIR/results" ||
		fail "$cover: standard input and error are not /dev/null"
	grep -q 'OWN-SESSION' "$TEST_DIR/results" || fail "$cover: the command has no session of its own"
	grep -q 'LOCK-HELD' "$TEST_DIR/results" || fail "$cover: the command did not outlive its call"
	# It ends with the exchange.
	flock -w 30 work/bg.lock true || fail "$cover: the command is still running after the exchange"
done
pass
