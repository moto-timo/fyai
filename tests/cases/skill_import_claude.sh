#!/bin/bash
# SPDX-License-Identifier: MIT
# `skill import --claude` reads the skills and commands of Claude Code: the
# project .claude, the user directory with its synced skills, and the
# installed plugins, each skill named after its plugin. The first source of a
# name wins, and a file that cannot be read is skipped with a warning.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
C="$TEST_DIR/claude"
export CLAUDE_CONFIG_DIR="$C"
skill() {
	mkdir -p "$1"
	printf -- '---\ndescription: %s\n---\n%s\n' "$2" "$3" >"$1/SKILL.md"
}
skill "$C/skills/shared" 'User shared.' USER_SHARED
skill "$C/skills/solo" 'User solo.' USER_SOLO
skill "$C/skills/synced/bucket-1/synced-one" 'Synced.' SYNCED
mkdir -p "$C/skills/broken"
printf '  ---\n  description: indented\n  ---\n' >"$C/skills/broken/SKILL.md"
mkdir -p "$C/commands/group"
printf -- '---\ndescription: A command.\nargument-hint: "[x]"\n---\nCMD $ARGUMENTS\n' \
	>"$C/commands/group/deploy.md"
P="$TEST_DIR/plugin-install"
skill "$P/skills/lint" 'Plugin lint.' PLUGIN_LINT
mkdir -p "$P/commands" "$C/plugins"
printf -- '---\ndescription: Plugin command.\n---\nPCMD\n' >"$P/commands/go.md"
cat >"$C/plugins/installed_plugins.json" <<JSON
{"version": 2, "plugins": {"tools@market": [{"scope": "user", "installPath": "$P"}]}}
JSON
# The project has its own skill of a name that the user has too.
skill "$TEST_DIR/.claude/skills/shared" 'Project shared.' PROJECT_SHARED

run_fyai skill import --claude all
assert_status 0
assert_stdout_contains 'skill: imported'
assert_stderr_contains 'broken/SKILL.md: SKILL.md must start with a front matter'
run_fyai skill list --output json
assert_status 0
for n in shared solo synced-one deploy tools-lint tools-go; do
	assert_stdout_contains "\"name\": \"$n\""
done
assert_stdout_not_contains '"name": "broken"'
run_fyai skill show shared
assert_status 0
assert_stdout_contains 'PROJECT_SHARED'
run_fyai skill show tools-lint
assert_status 0
assert_stdout_contains 'name: tools-lint'

# A second import keeps what is stored, and --force replaces it.
run_fyai skill import --claude user
assert_status 0
assert_stdout_contains 'imported nothing new'
run_fyai skill import --claude user --force
assert_status 0
run_fyai skill show shared
assert_status 0
assert_stdout_contains 'USER_SHARED'

# A scope with no skill is an error.
rm -rf "$C/plugins"
run_fyai skill import --claude plugins
assert_status_nonzero
assert_stderr_contains 'found no Claude Code skill'
pass
