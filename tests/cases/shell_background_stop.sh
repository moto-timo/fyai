#!/bin/bash
# SPDX-License-Identifier: MIT
# `list` shows a command in the background as a monitor, and `cancel` with its
# name stops the command: nothing of it is left running afterwards.
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

mock_start shell_background_stop.json
run_fyai --set sandbox_profile=dev --set api=chat-completions --set display/stream=false \
	 --set tools=true --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model \
	 --new "go"
assert_status 0
tool_results >"$TEST_DIR/results"
mock_stop 6
grep -q 'srv' "$TEST_DIR/results" || fail "list does not show the command"
grep -q 'LOCK-FREE' "$TEST_DIR/results" || fail "the command is still running after the cancel"
pass
