#!/bin/bash
# SPDX-License-Identifier: MIT
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start mcp_resources.json
STDIO_LOG="$TEST_DIR/mcp-resources.jsonl"
run_fyai --set api=chat-completions --set display/stream=false \
	--set mcp/enabled=true \
	--set "mcp/servers/local={transport: stdio, command: '$PYTHON', args: ['$TESTS_DIR/mock/mock_mcp_stdio.py'], env: {MCP_STDIO_LOG: '$STDIO_LOG'}}" \
	--set api_url="$MOCK_URL/v1/chat/completions" -m mock-model "read resources"
assert_status 0
assert_stdout_contains "Resources completed."
assert_request 0 'any(t["function"]["name"] == "mcp_resource" for t in r["body"]["tools"])'
assert_request 1 'any(m.get("role") == "tool" and "page-2" in m.get("content", "") for m in r["body"]["messages"])'
assert_request 2 'any(m.get("role") == "tool" and "test://second" in m.get("content", "") for m in r["body"]["messages"])'
assert_request 3 'any(m.get("role") == "tool" and "uriTemplate" in m.get("content", "") for m in r["body"]["messages"])'
assert_request 4 'any(m.get("role") == "tool" and "resource body" in m.get("content", "") for m in r["body"]["messages"])'
"$PYTHON" - "$STDIO_LOG" <<'PY'
import json, sys
methods = [json.loads(row)["request"]["method"] for row in open(sys.argv[1]) if '"request"' in row]
assert methods == ["initialize", "notifications/initialized", "tools/list",
                   "resources/list", "resources/list",
                   "resources/templates/list", "resources/read"]
PY
mock_stop 5
pass
