#!/bin/bash
# SPDX-License-Identifier: MIT
# Several questions in the input area of the page: one is shown at a time with
# its position, a question that allows many choices toggles with the number
# keys and Space, Left goes back, and a review of every answer ends the series
# before it is sent.
set -eu
. "$(dirname "$0")/../harness.sh"

# Ask the questions of the scenario and drive the keys $1; the result that the
# model was given is checked by $2, a Python expression over res.
ask()
{
    local steps
    steps="$(cat)"
    name=$1
    fyai_test_setup
    mock_start ask_user_multi.json
    driver=0
    {
        cat <<'PTY'
cols: 100
timeout: 20
wait_timeout: 10
steps:
  - type: ask me two things
  - wait: "How wide?"
    timeout: session
PTY
        printf '%s\n' "$steps"
    } | pty_run "$TEST_DIR/pty.out" \
        "$FYAI_BIN" -k test-key --theme dark \
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
        fail "the questions were not answered by $name"
    fi
    assert_request 1 "$2"
}

RES='json.loads([m for m in r["body"]["messages"] if m.get("role") == "tool"][-1]["content"])'

# The first question names its position, its options and their descriptions.
# The key 2 chooses and goes on; the second question toggles with the number
# keys; Enter ends the series at the review, and Enter again sends it.
ask review \
    "$RES[\"answers\"][0][\"selected\"] == [\"medium\"] and $RES[\"answers\"][1][\"selected\"] == [\"lint\", \"asan\"]" <<'PTY'
  - wait-screen: "(1 of 2)"
  - wait-screen: The medium choice
  - write: "2"
  - wait-screen: "Which checks?"
  - wait-screen: "(2 of 2)"
  - wait-screen: Space toggles
  - write: "1"
  - wait-screen: "1. [x] lint"
  - write: "3"
  - wait-screen: "3. [x] asan"
  - write: "\r"
  - wait-screen: "Send these answers?"
  - wait-screen: "Scope: medium"
  - wait-screen: "Checks: lint, asan"
  - write: "\r"
  - wait-screen: Answers received.
PTY
mock_stop 2

# Left goes back to the first question, which keeps its answer: choosing
# another changes it, and the review shows the change.
ask back \
    "$RES[\"answers\"][0][\"selected\"] == [\"large\"] and $RES[\"answers\"][1][\"selected\"] == [\"lint\"]" <<'PTY'
  - wait-screen: "(1 of 2)"
  - write: "2"
  - wait-screen: "(2 of 2)"
  - write: "\e[D"
  - wait-screen: "(1 of 2)"
  - write: "3"
  - wait-screen: "(2 of 2)"
  - write: " "
  - wait-screen: "1. [x] lint"
  - write: "\r"
  - wait-screen: "Scope: large"
  - write: "\r"
  - wait-screen: Answers received.
PTY
mock_stop 2

# Text typed answers a question in place of its options, and Escape at the
# review declines the whole series.
ask text \
    "$RES[\"status\"] == \"declined\"" <<'PTY'
  - wait-screen: "(1 of 2)"
  - write: "m"
  - frame: 2
  - write: "\r"
  - wait-screen: "(2 of 2)"
  - write: "\e"
  - wait-screen: Answers received.
PTY
mock_stop 2

pass
