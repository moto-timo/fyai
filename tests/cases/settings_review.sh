#!/bin/bash
# SPDX-License-Identifier: MIT
# A change of a review key is put to the user in the review panel: the
# proposal that the model wrote and the diff that fyai made stand under
# headings of their own. Reject is the first option, so Enter alone rejects;
# Down and Enter accept and fyai applies the change. A typed reply rejects
# the change and goes back to the model.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start settings_review.json

review_run() {
	local input=$1 rows=${2:-40} driver=0 steps

	steps="$(cat)"

	export input
	export rows
	{
	    cat <<'PTY'
rows: ${rows}
cols: 100
timeout: 20
wait_timeout: 10
steps:
  - type: "${input}"
  - wait: "Proposal · written by the model"
    timeout: session
PTY
	    printf '%s\n' "$steps"
	} | pty_run "$TEST_DIR/pty.out" \
	    "$FYAI_BIN" -k test-key --theme dark --branch main \
	    --set display/markdown=true --set display/stream=false \
	    --set tools=true \
	    --set api=chat-completions \
	    --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model -i ||
	    driver=$?
	if grep -a -q "needs a libfytimui" "$TEST_DIR/pty.out"; then
		skip "this build has no page support"
	fi
	if [ "$driver" -ne 0 ]; then
		tail -c 2000 "$TEST_DIR/pty.out" >&2
		fail "the review panel did not act as expected"
	fi
}

# The panel shows both parts; Down and Enter accept.
review_run "make it warmer" <<'PTY'
  - wait-screen: "Diff · made by fyai"
  - wait-screen: warmer
  - wait-screen: "1. Reject"
  - snapshot: "${TEST_DIR}/reply-screen.out"
  - write: "\e[6~\e[6~\e[6~\e[6~\e[6~\e[6~\e[6~\e[6~"
  - wait-screen: Review row 50
  - write: "\e[5~\e[5~\e[5~\e[5~\e[5~\e[5~\e[5~\e[5~"
  - wait-screen: system_prompt
  - write: "\e[B\r"
  - wait-screen: Temperature changed.
PTY
"$PYTHON" - "$TEST_DIR/reply-screen.out" "$TESTS_DIR" <<'PY' ||
import sys

sys.path.insert(0, sys.argv[2])
from screen import Screen

screen = Screen(40, 100)
screen.feed(open(sys.argv[1], "rb").read())
shown = "\n".join(screen.lines())
for text in ("make it warmer", "Your reply (optional)", "Diff"):
    if text not in shown:
        raise SystemExit("review covered %r: %s" % (text, shown))
PY
	fail "the review covered the conversation or main input box"
assert_request 1 'json.loads([m for m in r["body"]["messages"] if m.get("role") == "tool"][-1]["content"])["status"] == "applied"'

run_fyai config get temperature
assert_status 0
assert_stdout_contains '0.5'
run_fyai config changes --output json
assert_status 0
assert_stdout_contains '"c1"'

# A typed reply rejects the change and reaches the model.
review_run "warmer still" 24 <<'PTY'
  - wait-screen: "+temperature: 1.5"
  - click: Much warmer still.
  - write: "\e[C"
  - frame: 1
  - write: "\e[D"
  - frame: 1
  - write: "\e[B\e[B"
  - frame: 1
  - write: "\e[A"
  - frame: 1
  - write: "\e[C"
  - frame: 1
  - write: "\t"
  - frame: 1
  - write: "\e[Z"
  - frame: 1
  - write: "\t"
  - frame: 1
  - write: "too warm 12"
  - wait-screen: too warm 12
  - write: "\e[D\x7f"
  - wait-screen: too warm 2
  - snapshot: "${TEST_DIR}/reply-screen.out"
  - write: "\r"
  - wait-screen: Left as it is.
PTY

"$PYTHON" - "$TEST_DIR/reply-screen.out" "$TESTS_DIR" <<'PY' ||
import sys

sys.path.insert(0, sys.argv[2])
from screen import Screen

screen = Screen(24, 100)
screen.feed(open(sys.argv[1], "rb").read())
shown = "\n".join(screen.lines())
for text in ("too warm 2", "Your reply (optional)", "Diff", "Reject", "Accept", "Other:"):
    if text not in shown:
        raise SystemExit("reply editor covered %r: %s" % (text, shown))
PY
	fail "the reply editor was covered by the review panel"
assert_request 3 'json.loads([m for m in r["body"]["messages"] if m.get("role") == "tool"][-1]["content"])["status"] == "rejected"'
assert_request 3 'json.loads([m for m in r["body"]["messages"] if m.get("role") == "tool"][-1]["content"])["reply"] == "too warm 2"'

run_fyai config get temperature
assert_status 0
assert_stdout_contains '0.5'

mock_stop 4
pass
