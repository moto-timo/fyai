#!/bin/bash
# SPDX-License-Identifier: MIT
# A skill that a session imports runs as "/NAME ARGS" in the same session:
# Tab completes its name, the model gets the loaded skill, and
# "/skill exec NAME ARGS" runs it too.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mkdir -p "$TEST_DIR/pony"
printf -- '---\nname: ponytail\ndescription: Lazy mode.\nargument-hint: "[lite|full]"\n---\nPONY_BODY level $0\n' \
	>"$TEST_DIR/pony/SKILL.md"
mock_start skill_session.json

FYAI_PTY_INPUT="/skill import $TEST_DIR/pony/SKILL.md" \
FYAI_PTY_NEEDLE="imported ponytail" FYAI_PTY_TIMEOUT=30 \
FYAI_PTY_AFTER="raw:2f706f6e09|wait-screen:/ponytail|send:lite|wait-screen:PONY_REPLY|send:/skill exec ponytail full|wait-screen:PONY_EXEC" \
"$PYTHON" "$TESTS_DIR/pty_driver.py" "$TEST_DIR/pty.out" \
	"$FYAI_BIN" -k test-key --set api=responses --set display/stream=false \
	--set "api_url=$MOCK_URL/v1/responses" -m mock-model -i
assert_request 0 '"PONY_BODY level lite" in json.dumps(r["body"]["input"])'
assert_request 0 '"The user ran the skill `ponytail`" in json.dumps(r["body"]["input"])'
# The import offers the skill to the model through the skill tool at once.
assert_request 0 '"Lazy mode." in json.dumps(r["body"]["tools"])'
# Tab completes /pon to the skill, as it completes a command.
assert_request 0 '"PONY_BODY level lite" in json.dumps(r["body"]["input"])'
assert_request 1 '"PONY_BODY level full" in json.dumps(r["body"]["input"])'
mock_stop 2
pass
