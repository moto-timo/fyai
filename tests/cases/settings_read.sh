#!/bin/bash
# SPDX-License-Identifier: MIT
# The settings tool reads the configuration by the access of the schema: a
# search gives the key and its access, a hidden key is refused, and
# model_access none offers no tool.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start settings_read.json

run_fyai --set api=chat-completions --set display/stream=false --set tools=true \
	 --set api_url="$MOCK_URL/v1/chat/completions" -m mock-model "find the setting"
assert_status 0
assert_stdout_contains 'Found it.'

assert_request 0 'any(t["function"]["name"] == "settings" for t in r["body"]["tools"])'
# The search result names the key and its access.
assert_request 1 'any(m["role"] == "tool" and "display/tool_preview_lines" in m["content"] and "\"review\"" in m["content"] for m in r["body"]["messages"])'
# A credential reference is not read.
assert_request 2 'any(m["role"] == "tool" and "api_key is hidden from the model" in m["content"] for m in r["body"]["messages"])'
assert_request 2 'not any(m["role"] == "tool" and "OPENAI_API_KEY" in m["content"] for m in r["body"]["messages"])'

run_fyai --set model_access=none --transient --set api=chat-completions \
	 --set display/stream=false --set tools=true \
	 --set api_url="$MOCK_URL/v1/chat/completions" -m mock-model "anything"
assert_status 0
assert_stdout_contains 'No settings tool.'
assert_request 3 'not any(t["function"]["name"] == "settings" for t in r["body"]["tools"])'

mock_stop 4
pass
