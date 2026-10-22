#!/bin/bash
# SPDX-License-Identifier: MIT
# `fyai schema` exports the command definitions and the schemas, so a front
# end offers the commands with no list of its own; `catalog list --available`
# lists only the models of a provider that has a credential.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup

# check_json EXPR VERB...: the output parses as JSON and EXPR holds for it.
check_json() {
	local expr="$1"
	shift
	run_fyai "$@" --output json
	assert_status 0
	"$PYTHON" - "$TEST_DIR/stdout" "$expr" <<'PYEOF' ||
import json, sys

doc = json.load(open(sys.argv[1]))
if not eval(sys.argv[2], {"d": doc}):
    raise SystemExit("unexpected: %r" % (doc,))
PYEOF
		fail "'$*' --output json: $(cat "$TEST_DIR/stdout")"
}

names='[c["command"] for c in d["commands"]]'

check_json "d['surface'] == 'all' and 'branch' in $names and 'init' in $names and 'exit' in $names" schema
check_json "next(c for c in d['commands'] if c['command'] == 'init')['surfaces'] == ['cli']" schema
check_json "next(c for c in d['commands'] if c['command'] == 'resume')['flags'] == ['model', 'interactive']" schema
check_json "d['surface'] == 'session' and 'branch' in $names and 'exit' in $names and 'init' not in $names" \
	schema commands --surface session
# A hidden command and a command of the other surface are not offered.
check_json "'__complete' not in $names" schema
check_json "d['surface'] == 'cli' and 'init' in $names and 'exit' not in $names" \
	schema commands --surface cli
# The arguments are JSON Schema, with the properties that a user may give.
check_json "next(c for c in d['commands'] if c['command'] == 'model')['arguments']['type'] == 'object'" schema
# A group carries its subcommands.
check_json "any(s['command'] == 'list' for c in d['commands'] if c['command'] == 'branch' for s in c['commands'])" schema
check_json "d['type'] == 'object' and 'properties' in d" schema config
check_json "'properties' in d or '\$defs' in d" schema catalog
pass
