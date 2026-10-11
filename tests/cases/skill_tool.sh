#!/bin/bash
# SPDX-License-Identifier: MIT
# A skill is branch state: `skill import` stores a SKILL.md and its files, the
# skill tool lists the skills to the model and loads one with its arguments,
# `file` reads a supporting file, and "/NAME ARGS" runs a skill as a user
# turn while the transcript keeps the line as typed.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mkdir -p "$TEST_DIR/skills/greet/scripts" "$TEST_DIR/skills/hidden"
cat >"$TEST_DIR/skills/greet/SKILL.md" <<'MD'
---
name: greet
description: Greet a person by name.
argument-hint: "[first] [last]"
---
Say hello to $0 warmly. Family: $ARGUMENTS[1]. Run ${CLAUDE_SKILL_DIR}/scripts/hello.sh
MD
echo 'echo HELLO_FROM_SCRIPT $((40+2))' >"$TEST_DIR/skills/greet/scripts/hello.sh"
chmod +x "$TEST_DIR/skills/greet/scripts/hello.sh"
cat >"$TEST_DIR/skills/hidden/SKILL.md" <<'MD'
---
description: Only the user runs this one.
disable-model-invocation: true
---
HIDDEN_BODY $ARGUMENTS
MD
# A skill whose name a command takes runs only through `skill exec`.
mkdir -p "$TEST_DIR/skills/todo"
cat >"$TEST_DIR/skills/todo/SKILL.md" <<'MD'
---
description: A skill named as a command.
---
TODO_SKILL_BODY $ARGUMENTS
MD

run_fyai skill import "$TEST_DIR/skills"
assert_status 0
assert_stdout_contains 'skill: imported'
run_fyai skill list --output json
assert_status 0
assert_stdout_contains '"name": "greet"'
assert_stdout_contains '"files": 1'
assert_stdout_contains '"invocation": "user"'

# A second import of the same name needs --force.
run_fyai skill import "$TEST_DIR/skills/greet"
assert_status_nonzero
assert_stderr_contains 'already stored'

mock_start skill_inline.json
run_fyai --set api=responses --set display/stream=false --set tools=true \
	 --set api_url="$MOCK_URL/v1/responses" -m mock-model "greet Ada"
assert_status 0
assert_stdout_contains 'Greeted.'

# The tool lists the skills that the model may load, and not the others.
assert_request 0 '"greet" in json.dumps(r["body"]["tools"]) and "Greet a person by name." in json.dumps(r["body"]["tools"])'
assert_request 0 '"Only the user runs this one." not in json.dumps(r["body"]["tools"])'
# The loaded skill has its arguments in place, and names its files.
assert_request 1 '"Say hello to Ada warmly. Family: Lady Lovelace." in json.dumps(r["body"]["input"])'
# The files are written out under $TMPDIR, and the skill names them there.
assert_request 1 "\"Base directory for this skill: $TMPDIR/fyai-skills-\" in json.dumps(r[\"body\"][\"input\"])"
assert_request 1 "\"/greet/scripts/hello.sh\" in json.dumps(r[\"body\"][\"input\"]) and \"skill:greet/\" not in json.dumps(r[\"body\"][\"input\"])"
assert_request 2 '"HELLO_FROM_SCRIPT $((40+2))" in json.dumps(r["body"]["input"])'
# The script runs from there, with the executable bit it was imported with.
assert_request 3 '"HELLO_FROM_SCRIPT 42" in json.dumps(r["body"]["input"])'
# The invocation removes what it wrote out.
ls "$TMPDIR" | grep -q fyai-skills- && fail 'the skill directory was left behind'

# A prompt "/NAME ARGS" runs the skill; the model gets its text.
run_fyai --set api=responses --set display/stream=false --set tools=true \
	 --set api_url="$MOCK_URL/v1/responses" -m mock-model "/hidden one two"
assert_status 0
assert_stdout_contains 'Ran the slash skill.'
assert_request 4 '"HIDDEN_BODY one two" in json.dumps(r["body"]["input"])'
assert_request 4 '"The user ran the skill `hidden`" in json.dumps(r["body"]["input"])'

# `skill exec` runs a skill that a command shadows, as one turn.
run_fyai --set api=responses --set display/stream=false --set tools=true \
	 --set api_url="$MOCK_URL/v1/responses" -m mock-model skill exec todo now please
assert_status 0
assert_stdout_contains 'Exec done.'
assert_request 5 '"TODO_SKILL_BODY now please" in json.dumps(r["body"]["input"])'
mock_stop 6

# A disabled skill stays stored, but nothing runs it.
run_fyai skill disable greet
assert_status 0
run_fyai skill list --output json
assert_status 0
assert_stdout_contains '"enabled": false'
run_fyai skill exec greet
assert_status_nonzero
assert_stderr_contains 'no enabled skill'
run_fyai skill enable greet
assert_status 0

# Show gives the front matter as YAML and the body as Markdown.
run_fyai skill show greet
assert_status 0
assert_stdout_contains '````yaml'
assert_stdout_contains 'argument-hint: "[first] [last]"'
assert_stdout_contains 'Say hello to $0 warmly.'
assert_stdout_not_contains '````markdown'
run_fyai skill show greet scripts/hello.sh
assert_status 0
assert_stdout_contains '````bash'
# Rendered as Markdown, the '$' of the arguments is not read as math.
run_fyai --set display/markdown=true skill show greet
assert_status 0
assert_stdout_contains 'Say hello to $0 warmly. Family: $ARGUMENTS[1].'
assert_stdout_contains '${CLAUDE_SKILL_DIR}/scripts/hello.sh'
assert_stdout_contains 'Files:'
run_fyai --set display/markdown=false skill files greet --output json
assert_status 0
assert_stdout_contains '"path": "scripts/hello.sh"'
assert_stdout_contains '"lines": 1'
assert_stdout_contains '"executable": true'

# One supporting file goes to a directory, or to standard output as it is.
run_fyai skill export greet "$TEST_DIR/one" --file scripts/hello.sh
assert_status 0
grep -q HELLO_FROM_SCRIPT "$TEST_DIR/one/scripts/hello.sh" || fail 'file not exported'
run_fyai skill export greet "$TEST_DIR/one" --file scripts/hello.sh
assert_status_nonzero
assert_stderr_contains 'File exists'
run_fyai skill export greet - --file scripts/hello.sh
assert_status 0
[ "$(cat "$TEST_DIR/stdout")" = 'echo HELLO_FROM_SCRIPT $((40+2))' ] || fail 'stdout export is not the file'
[ -x "$TEST_DIR/one/scripts/hello.sh" ] || fail 'the export lost the executable bit'

# Help lists the skills that /NAME runs, but not one that a command shadows.
run_fyai help
assert_status 0
assert_stdout_contains '/greet [first] [last]'
assert_stdout_not_contains '/todo'
run_fyai help greet
assert_status 0
assert_stdout_contains 'Greet a person by name.'

# A SKILL.md named on its own comes without the files beside it.
run_fyai skill import --force "$TEST_DIR/skills/greet/SKILL.md"
assert_status 0
run_fyai skill list --output json
assert_status 0
"$PYTHON" - "$TEST_DIR/stdout" <<'PY' || fail 'a SKILL.md alone brought its files'
import json, sys
rows = {r["name"]: r for r in json.load(open(sys.argv[1]))}
sys.exit(0 if rows["greet"]["files"] == 0 else 1)
PY
run_fyai skill import --force "$TEST_DIR/skills/greet"
assert_status 0

# The skill travels with the configuration: a new branch has it.
run_fyai branch create child main
assert_status 0
run_fyai --branch child skill list --output json
assert_status 0
assert_stdout_contains '"name": "greet"'

# Export writes SKILL.md and the files; remove drops the skill.
run_fyai skill export greet "$TEST_DIR/out"
assert_status 0
grep -q 'name: greet' "$TEST_DIR/out/SKILL.md" || fail "$TEST_DIR/out/SKILL.md lacks 'name: greet'"
grep -q 'HELLO_FROM_SCRIPT' "$TEST_DIR/out/scripts/hello.sh" || fail "$TEST_DIR/out/scripts/hello.sh lacks 'HELLO_FROM_SCRIPT'"
run_fyai skill remove greet hidden todo
assert_status 0
run_fyai skill list
assert_status 0
assert_stdout_contains 'no skills'
pass
