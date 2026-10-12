#!/bin/bash
# SPDX-License-Identifier: MIT
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start mcp_discovery.json
STDIO_LOG="$TEST_DIR/mcp-discovery-only.jsonl"
run_fyai --set api=chat-completions --set tools=false \
	--set display/stream=false --set mcp/enabled=true \
	--set "mcp/servers/local={transport: stdio, command: '$PYTHON', args: ['$TESTS_DIR/mock/mock_mcp_stdio.py'], env: {MCP_STDIO_LOG: '$STDIO_LOG', MCP_MANY_TOOLS: '1'}}" \
	--set api_url="$MOCK_URL/v1/chat/completions" -m mock-model "find echo"
assert_status 0
assert_stdout_contains "Discovery completed."
assert_request 0 'any(t["function"]["name"] == "tool_search" for t in r["body"]["tools"]) and not any(t["function"]["name"] == "read_file" for t in r["body"]["tools"])'
assert_request 1 'any(t["function"]["name"] == "mcp__local__echo" for t in r["body"]["tools"])'
mock_stop 3
pass
