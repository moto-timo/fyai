#!/bin/bash
# SPDX-License-Identifier: MIT
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup

# Each command prints, waits until the case has seen its output on the
# screen, and prints again. The case releases both by one file.
"$PYTHON" - "$SCENARIOS_DIR/ui_responses_shell_parallel.json" \
    "$TEST_DIR/shell-parallel.json" "$TEST_DIR/release-shells" <<'PY'
import json
import sys

scenario = json.load(open(sys.argv[1]))
for call in scenario["steps"][0]["response"]["output"]:
    cmd = call["action"]["commands"][0]
    for sleep in ("sleep 2", "sleep 3"):
        cmd = cmd.replace(sleep, 'until [ -e "%s" ]; do sleep 0.02; done' %
                          sys.argv[3])
    call["action"]["commands"][0] = cmd
with open(sys.argv[2], "w") as out:
    json.dump(scenario, out)
PY
mock_start "$TEST_DIR/shell-parallel.json"

pty_run "$TEST_DIR/pty.out" \
	"$FYAI_BIN" -k test-key --theme dark \
	--set display/markdown=true --set display/stream=false \
	--set display/tool_preview_lines=5 --set tools=true \
	--set api=responses --set builtin_shell=true \
	--set "api_url=$MOCK_URL/v1/responses" \
	-m mock-model -i <<'PTY'
snapshot: "${TEST_DIR}/snapshot.out"
steps:
  - type: run both
  - wait: native-early-a
    timeout: 3
  - wait-frame: native-early-a
    from: start
    timeout: session
  - touch: "${TEST_DIR}/release-shells"
  - wait: Native interactive tools done.
    timeout: session
  - type: "/status"
  - wait-screen: Usage / total
PTY

"$PYTHON" - "$TEST_DIR/pty.out" <<'EOF' || \
	fail "native shell workbands did not update progressively"
import re
import sys

data = open(sys.argv[1], "rb").read()
plain = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", data)
for marker in (b"native-early-a", b"native-early-b",
               b"native-late-a", b"native-late-b"):
    if marker not in plain:
        raise SystemExit("missing native progress marker: %r" % marker)
EOF

"$PYTHON" "$TESTS_DIR/assert_work_retired.py" \
    "$TEST_DIR/snapshot.out" "● shell" || fail "completed native shells remained in the work pane"

assert_request 1 \
	'all(any(i.get("type") == "shell_call_output" and '\
'i.get("call_id") == call for i in r["body"]["input"]) for call in '\
'("call_ui_native_a", "call_ui_native_b"))'
mock_stop 2
pass
