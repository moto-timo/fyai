#!/bin/bash
# SPDX-License-Identifier: MIT
# A verb returns its result for the caller to present: --output json writes
# one JSON document of it, and --output yaml one YAML document.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup

# check_json EXPR VERB...: the output parses as JSON and EXPR holds for it.
check_json() {
	local expr="$1"
	shift
	run_fyai "$@" --output json
	assert_status 0
	"$PYTHON" - "$TEST_DIR/stdout" "$expr" <<'EOF' ||
import json, sys

doc = json.load(open(sys.argv[1]))
if not eval(sys.argv[2], {"d": doc}):
    raise SystemExit("unexpected: %r" % (doc,))
EOF
		fail "'$*' --output json: $(cat "$TEST_DIR/stdout")"
}

check_json 'any(b["branch"] == "main" for b in d)' branch
check_json 'isinstance(d, list) and all("active" in p for p in d)' \
	list providers
check_json '"total" in d' stats
check_json '"output_max" in d' context
check_json '"status" in d' auth
check_json 'd["root"] and d["head"] == "main"' root show
check_json 'set(d) == {"wire", "stream", "conversation", "mcp", "transport"}' log
check_json 'd == {"valid": True}' config validate
check_json '"model" in d and "api" in d' api
check_json 'isinstance(d, list) and d and "name" in d[0]' catalog list
check_json '"models" in d and "providers" in d' catalog show

# The image verbs answer with a document too: the waiting set, the image that
# was attached, and the count that was dropped.
check_json 'isinstance(d, list)' image list
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x04\x00\x00\x00\x03\x00\x08\x06\x00\x00\x00' \
	>"$TEST_DIR/shot.png"
check_json 'd["media_type"] == "image/png" and d["pending"]' \
	image add "$TEST_DIR/shot.png"
# An attachment waits in one invocation, so a later one has nothing to drop;
# the document still names the count it answered with.
check_json 'set(d) == {"count"}' image clear

run_fyai branch show main --output yaml
assert_status 0
assert_stdout_contains "branch: main"

pass
