#!/bin/bash
# SPDX-License-Identifier: MIT
# Verify the scope of an exchange: a program that a tool detaches lives for the
# next call of the same exchange and ends with the exchange. The program holds a
# lock, so the case reads its state from the lock and not from a process id,
# which differs inside a namespace. A terminal session keeps the scope while it
# is open, and `sandbox_scope: call` ends the program with its call.
set -eu
[ "$(uname -s)" = Linux ] || exit 77
command -v flock >/dev/null || exit 77
. "$(dirname "$0")/../harness.sh"

# The sandbox grants the system scratch trees whole: keep the project out of them.
FYAI_TMPDIR_BASE="$(dirname "$FYAI_BIN")"
fyai_test_setup
# A host with no namespace cannot create entries in the project root: use a directory.
mkdir work

OPTS=(--set sandbox_profile=dev --set api=chat-completions --set display/stream=false
      --set tools=true)

# tool_results: the results of the tools in the last request, one for each line.
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

# lock_free: wait until the program has gone. A program that stays fails by the limit.
lock_free() {
	flock -w 30 work/scope.lock true || fail "$1: the program of the tool is still running"
}

run_scope() {
	local scenario="$1" cover="$2" scope="$3"

	mock_start "$scenario"
	run_fyai "${OPTS[@]}" --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model \
		 --set "sandbox_cover=$cover" --set "sandbox_scope=$scope" --new "go"
	assert_status 0
	tool_results >"$TEST_DIR/results"
	mock_stop "$4"
}

for cover in auto none; do
	# The program lives for the second call, and the first call says that it left one.
	run_scope sandbox_scope.json "$cover" exchange 4
	grep -q 'LOCK-HELD' "$TEST_DIR/results" || fail "$cover: the program ended with its call"
	grep -q 'daemon' "$TEST_DIR/results" ||
		fail "$cover: the call did not say that it left a daemon"
	# The list of daemons names it.
	grep -q '"name": "sleep"\|name.*sleep' "$TEST_DIR/results" ||
		fail "$cover: list did not name the daemon"
	# It has gone when the exchange has ended.
	lock_free "$cover exchange"

	# A scope of one call ends the program with the call.
	run_scope sandbox_scope_call.json "$cover" call 3
	grep -q 'LOCK-FREE' "$TEST_DIR/results" || fail "$cover: a scope of a call kept the program"
	grep -q 'daemon' "$TEST_DIR/results" &&
		fail "$cover: a scope of a call named a daemon that ended"
	lock_free "$cover call"

	# A session whose program left one: the scope ends it when the session has ended.
	run_scope sandbox_scope_session.json "$cover" exchange 3
	lock_free "$cover session"
done

# Three exchanges in one session: the scope ends with an exchange, and a terminal
# session keeps it past the exchange that started it until the session closes.
mock_start sandbox_scope_exchanges.json
pty_run "$TEST_DIR/pty.out" \
    "$FYAI_BIN" -k test-key --theme dark --set display/markdown=true \
    "${OPTS[@]}" --set sandbox_cover=auto --set sandbox_scope=exchange \
    --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model -i <<'PTY'
timeout: 60
steps:
  - type: first
  - wait: first done.
    timeout: session
  - type: second
  - wait: second done.
    timeout: session
  - type: third
  - wait: third done.
    timeout: session
  - type: fourth
  - wait: fourth done.
    timeout: session
  - type: fifth
  - wait: fifth done.
    timeout: session
PTY
"$PYTHON" - "$TEST_DIR/requests.jsonl" <<'PYEOF' || fail "the scope did not follow the exchanges"
import json
import sys

last = json.loads(open(sys.argv[1]).read().splitlines()[-1])["body"]
out = [m["content"] for m in last["messages"] if m.get("role") == "tool"]
text = "\n".join(out)
# The first exchange: held. The second: free, as the first exchange ended.
if text.count("LOCK-HELD") != 2:
    sys.exit("expected the program held in the first and the fourth exchange: %r" % text)
if text.count("LOCK-FREE") != 2:
    sys.exit("expected the program gone in the second and the fifth exchange: %r" % text)
PYEOF
mock_stop 13
lock_free "session"

pass
