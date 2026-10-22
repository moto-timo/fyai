#!/bin/bash
# SPDX-License-Identifier: MIT
# `catalog list --available` lists only the models and the providers that have
# a credential.
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

# Only a provider with a credential offers a model.
unset OPENAI_API_KEY OPENROUTER_API_KEY DEEPSEEK_API_KEY ANTHROPIC_API_KEY \
      GOOGLE_API_KEY FIREWORKS_API_KEY META_API_KEY OPENCODE_API_KEY || true
check_json "isinstance(d, list) and d and all(m['key_provider'] == '' for m in d)" \
	catalog list models
check_json "d == []" catalog list models --available
check_json "d == []" catalog list providers --available
ANTHROPIC_API_KEY=test check_json \
	"d and all(m['key_provider'] == 'anthropic' for m in d)" \
	catalog list models --available
ANTHROPIC_API_KEY=test check_json "[p['name'] for p in d] == ['anthropic']" \
	catalog list providers --available
pass
