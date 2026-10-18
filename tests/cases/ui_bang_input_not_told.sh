#!/bin/bash
# SPDX-License-Identifier: MIT
# A bang session that waits for input is not reported to the model.
#
# The user owns a bang session and reads its screen. The model must not get
# its output, and a turn started for it would take the screen from the user.
set -eu
. "$(dirname "$0")/../harness.sh"

# Only Linux reports which descriptor a stopped process reads. See
# fyai_process_reads_stdin().
[ "$(uname -s)" = "Linux" ] || skip "an input wait is reported on Linux only"

fyai_test_setup
mock_start shell_input_wanted.json

# The bang session waits in cat. Then the model opens a shell of its own that
# waits too, and is told so. The watch of the bang session started first and
# polls at the same interval, so by the time the model answers its own shell,
# the bang session was looked at at least as many times.
pty_run "$TEST_DIR/pty.out" \
    "$FYAI_BIN" -k test-key --theme dark \
    --set display/stream=false --set tools=true \
    --set api=chat-completions \
    --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model -i <<'PTY' ||
rows: 30
cols: 100
timeout: 40
wait_timeout: 20
steps:
  - type: "!sh -c 'printf \"%s-%s\\n\" ASK ME; exec cat'"
  - wait: bang-1
    timeout: session
  - wait-screen: ASK-ME
  - write: "\x1d"
  - wait-gone: "Ctrl-]"
  - type: open a shell that asks
  - wait-screen: It answered.
  - type: "/kill bang-1"
  - wait-screen: stopping shell bang-1
PTY
    fail "the sessions did not run"

"$PYTHON" - "$TEST_DIR/requests.jsonl" <<'PYEOF' || fail "the model was told about a bang session"
import json
import sys

reqs = [json.loads(l)["body"] for l in open(sys.argv[1])]
users = [m["content"] for m in reqs[-1]["messages"] if m.get("role") == "user"]
asked = [u for u in users if "waiting for input" in u]
# The shell of the model was reported: the watch ran.
if not any("'asker'" in u for u in asked):
    raise SystemExit("the shell of the model was not reported: %r" % asked)
# The bang session was not.
if any("bang-1" in u or "ASK-ME" in u for u in asked):
    raise SystemExit("the bang session was reported: %r" % asked)
PYEOF

mock_stop 4
pass
