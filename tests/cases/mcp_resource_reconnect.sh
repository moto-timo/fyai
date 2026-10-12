#!/bin/bash
# SPDX-License-Identifier: MIT
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start mcp_resource_reconnect.json
run_fyai --set api=chat-completions --set display/stream=false \
	--set mcp/enabled=true --set "mcp/endpoint='$MOCK_URL/mcp'" \
	--set api_url="$MOCK_URL/v1/chat/completions" -m mock-model "list resources"
assert_status 0
assert_stdout_contains "Resource reconnect completed."
assert_request 3 'any(t["function"]["name"] == "mcp_resource" for t in r["body"]["tools"])'
assert_request 4 'r["body"]["method"] == "resources/list" and r["mcp_session_id"] == "old-session"'
assert_request 5 'r["body"]["method"] == "initialize" and not r["mcp_session_id"]'
assert_request 7 'r["body"]["method"] == "resources/list" and r["mcp_session_id"] == "new-session"'
assert_request 8 'any(m.get("role") == "tool" and "test://recovered" in m.get("content", "") for m in r["body"]["messages"])'
mock_stop 10
pass
