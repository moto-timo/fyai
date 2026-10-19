#!/bin/bash
# SPDX-License-Identifier: MIT
# A unified diff inside a "*** Begin Patch" envelope applies as a unified diff,
# and its title row names the file.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start tools_envelope_unified.json

printf 'int main(void)\n{\n\tputs("old");\n\treturn 0;\n}\n' > hello.c

run_fyai --set display/markdown=true --set api=chat-completions \
	 --set display/stream=false --set tools=true \
	 --set api_url="$MOCK_URL/v1/chat/completions" -m mock-model "patch it"
assert_status 0
assert_file_content hello.c 'int main(void)
{
	puts("new");
	puts("extra");
	return 0;
}'
assert_stdout_contains "update"

mock_stop 2
pass
