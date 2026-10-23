#!/bin/bash
# SPDX-License-Identifier: MIT
# A program that a tool detaches gets SIGTERM and time to clean up when the
# invocation ends, before it is killed. Its cleanup takes a moment, so a run that
# kills it at once leaves no mark.
set -eu
[ "$(uname -s)" = Linux ] || exit 77
. "$(dirname "$0")/../harness.sh"

FYAI_TMPDIR_BASE="$(dirname "$FYAI_BIN")"
fyai_test_setup
mkdir work

for cover in auto none; do
	rm -f work/term.done work/term.pid
	mock_start sandbox_scope_term.json
	run_fyai --set sandbox_profile=dev --set api=chat-completions --set display/stream=false \
		 --set tools=true --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model \
		 --set "sandbox_cover=$cover" --set sandbox_scope=exchange --new "go"
	assert_status 0
	[ -f work/term.done ] || fail "$cover: the program was killed before it cleaned up"
	mock_stop 2
done
pass
