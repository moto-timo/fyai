#!/bin/bash
# SPDX-License-Identifier: MIT
# Reasoning value "none" sends no reasoning field and keeps temperature.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup

mock_start reasoning_responses.json
run_fyai --set api=responses --set display/stream=false --set api_url="$MOCK_URL/v1/responses" -m mock-model \
	 --set reasoning/effort=none --set reasoning/summary=none "no reasoning"
assert_status 0
assert_request 0 '"reasoning" not in r["body"]'
mock_stop 1

mock_start reasoning_chat.json
run_fyai --set api=chat-completions --set display/stream=false --set api_url="$MOCK_URL/v1/chat/completions" \
	 -m mock-model --set reasoning/effort=none --new "no reasoning"
assert_status 0
assert_request 0 '"reasoning_effort" not in r["body"]'
assert_request 0 '"reasoning" not in r["body"]'
mock_stop 1

pass
