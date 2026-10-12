#!/bin/bash
# SPDX-License-Identifier: MIT
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start mcp_stdio.json
STDIO_LOG="$TEST_DIR/mcp-no-resources.jsonl"
run_fyai --set api=chat-completions --set display/stream=false \
	--set mcp/enabled=true \
	--set "mcp/servers/local={transport: stdio, command: '$PYTHON', args: ['$TESTS_DIR/mock/mock_mcp_stdio.py'], env: {MCP_STDIO_LOG: '$STDIO_LOG', MCP_NO_RESOURCES: '1'}}" \
	--set api_url="$MOCK_URL/v1/chat/completions" -m mock-model "use local echo"
assert_status 0
assert_request 0 'not any(t["function"]["name"] == "mcp_resource" for t in r["body"]["tools"])'
mock_stop 2
pass
