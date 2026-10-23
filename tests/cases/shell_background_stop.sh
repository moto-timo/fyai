#!/bin/bash
# SPDX-License-Identifier: MIT
# A command in the background that has a name shows it as the label of its daemon, and
# `cancel` with that name stops it: the daemon gets SIGTERM and time to clean up. Its
# cleanup runs before the exchange ends, so the case reads what it left.
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
	rm -f work/st.*
	mock_start shell_background_stop.json
	run_fyai --set sandbox_profile=dev --set api=chat-completions --set display/stream=false \
		 --set tools=true --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model \
		 --set "sandbox_cover=$cover" --set sandbox_scope=exchange --new "go"
	assert_status 0
	tool_results >"$TEST_DIR/results"
	mock_stop 6
	grep -q '"label": "srv"\|label.*srv' "$TEST_DIR/results" || fail "$cover: list does not show the label"
	grep -q "daemon 'srv' was asked to stop" "$TEST_DIR/results" || fail "$cover: cancel did not stop it"
	grep -q 'CLEANED' "$TEST_DIR/results" || fail "$cover: the daemon did not get SIGTERM and time to clean up"
	grep -q 'LOCK-FREE' "$TEST_DIR/results" || fail "$cover: the daemon is still running after the stop"
done
pass
