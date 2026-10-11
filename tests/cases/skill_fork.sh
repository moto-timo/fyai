#!/bin/bash
# SPDX-License-Identifier: MIT
# A skill with `context: fork` runs as a fresh sub-agent: its task is the
# expanded skill, its model is the model of the skill, and it is offered only
# the tools that `allowed-tools` names, mapped from Claude Code names. The
# report of the sub-agent is the result of the skill call.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mkdir -p "$TEST_DIR/skills/review"
cat >"$TEST_DIR/skills/review/SKILL.md" <<'MD'
---
description: Review a change in a sub-agent.
context: fork
model: mock-model-mini
allowed-tools: Read, Bash(git:*)
---
REVIEW_TASK of $ARGUMENTS
MD
run_fyai skill import "$TEST_DIR/skills/review"
assert_status 0

mock_start skill_fork.json
run_fyai --set api=responses --set display/stream=false --set tools=true \
	 --set api_url="$MOCK_URL/v1/responses" -m mock-model "review the last commit"
assert_status 0
assert_stdout_contains 'Reviewed.'

# The sub-agent starts from the skill alone, with the model of the skill.
assert_request 1 '"REVIEW_TASK of HEAD~1" in json.dumps(r["body"]["input"])'
assert_request 1 '"review the last commit" not in json.dumps(r["body"]["input"])'
assert_request 1 'r["body"]["model"] == "mock-model-mini"'
# It is offered the tools of the skill and the ones every skill keeps.
assert_request 1 'set(t.get("name") or t["function"]["name"] for t in r["body"]["tools"] if t.get("type") == "function") <= {"read_file", "exec_command", "shell_input", "shell_output", "shell_close", "skill", "ask_parent", "time"}'
assert_request 1 'any((t.get("name") or "") == "read_file" for t in r["body"]["tools"])'
assert_request 1 'not any((t.get("name") or "") == "write_file" for t in r["body"]["tools"])'
# The parent gets the report as the result of its skill call.
assert_request 2 '"SUBAGENT_REPORT: looks fine." in json.dumps(r["body"]["input"])'
assert_request 2 'r["body"]["model"] == "mock-model"'
mock_stop 3
pass
