#!/bin/bash
# SPDX-License-Identifier: MIT
# A model of another provider arrives while the stored grammar is one that
# provider does not speak (the Responses default of `fyai init`, the model an
# Anthropic one). The grammar and its URL are one choice: the turn must speak
# the grammar of the endpoint it is sent to, not the stored one. A request
# built for Responses and sent to a Messages endpoint is rejected by the
# server (`tool_choice: Input should be an object`).
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start messages_tools_read_file.json

cat > catalog.yaml <<EOF
models:
- name: mock-model
  capabilities: [tool_calling]
providers:
- name: anthropic
  root_url: $MOCK_URL
  endpoints:
  - protocol: messages
    endpoint: /v1/messages
  models:
  - canonical_id: mock-model
    provider_model_id: mock-model
EOF
run_fyai catalog import catalog.yaml
assert_status 0

# What `fyai init` leaves behind: the Responses grammar and its OpenAI URL.
run_fyai config set api responses
assert_status 0
run_fyai config set api_url https://api.openai.com/v1/responses
assert_status 0

printf 'mock data payload\n' > data.txt

# The model of the turn belongs to the messages provider.
run_fyai --set display/stream=false --set tools=true -m mock-model "read data.txt"
assert_status 0
assert_stdout_contains "The file says: mock data payload."

assert_request 0 'r["path"] == "/v1/messages"'
# the grammar of the body is the grammar of the endpoint
assert_request 0 '"input" not in r["body"] and "messages" in r["body"]'
assert_request 0 'r["body"]["tool_choice"]["type"] == "auto"'
assert_request 0 'any(t.get("name") == "read_file" and "input_schema" in t for t in r["body"]["tools"])'

mock_stop 2
pass
