#!/bin/bash
# SPDX-License-Identifier: MIT
# A logout keeps the client registration and drops the tokens. Such a record
# is no login: auto mode goes on to the API key, and auth=chatgpt says that
# nobody is logged in. Only a record with a token that lacks the plan scope
# asks for a new login.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
unset OPENAI_API_KEY
export FYAI_AUTH_STORAGE=file
store="$XDG_STATE_HOME/fyai"
mkdir -p "$store"
chmod 700 "$store"

# No key at all: run_fyai gives one. Each run stops in setup, before a
# request: there is no key and no usable login.
run_nokey() {
	set +e
	"$FYAI_BIN" --color off "$@" >"$TEST_DIR/stdout" 2>"$TEST_DIR/stderr" \
		</dev/null
	FYAI_STATUS=$?
	set -e
}

write_record() {
	printf '%s\n' "$1" > "$store/auth.json"
	chmod 600 "$store/auth.json"
}

write_record '{"client_id": "oaiapp_test", "registrations": {}}'
run_nokey -m gpt-5.4-mini "hello"
assert_status_nonzero
assert_stderr_contains 'no API key'
assert_stderr_not_contains 'does not authorize'

run_nokey --set auth=chatgpt -m gpt-5.4-mini "hello"
assert_status_nonzero
assert_stderr_contains 'not logged in'

write_record '{"client_id": "oaiapp_test", "access_token": "a", "refresh_token": "r", "id_token": "i", "scope": "openid"}'
run_nokey --set auth=chatgpt -m gpt-5.4-mini "hello"
assert_status_nonzero
if [ "${FYAI_TEST_TRANSPORT:-}" = level-b ]; then
	assert_stderr_contains 'not logged in'
else
	assert_stderr_contains 'does not authorize ChatGPT plan usage'
fi

pass
