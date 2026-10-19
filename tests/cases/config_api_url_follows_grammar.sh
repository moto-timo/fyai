#!/bin/bash
# SPDX-License-Identifier: MIT
# When `api` and `api_url` disagree, the grammar wins if the URL is the
# catalogue URL of another grammar. A URL outside the catalogue, such as a
# proxy, stays.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup

cat > catalog.yaml <<EOF
models:
- name: foo
  capabilities: []
providers:
- name: mockprov
  root_url: http://127.0.0.1:9
  endpoints:
  - protocol: chat_completions
    endpoint: /v1/chat/completions
  - protocol: messages
    endpoint: /v1/messages
  models:
  - canonical_id: foo
    provider_model_id: bar
EOF
run_fyai catalog import catalog.yaml
assert_status 0

run_fyai config set model mockprov/foo
assert_status 0
run_fyai config set api_url "'http://127.0.0.1:9/v1/chat/completions'"
assert_status 0
run_fyai config set api messages
assert_status 0
run_fyai api
assert_status 0
assert_stdout_contains "url http://127.0.0.1:9/v1/messages"

run_fyai config set api_url "'http://proxy.invalid/v1/chat/completions'"
assert_status 0
run_fyai api
assert_stdout_contains "url http://proxy.invalid/v1/chat/completions"

pass
