#!/bin/bash
# SPDX-License-Identifier: MIT
# The settings tool reads and proposes changes to the branch catalogue.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup

run_fyai tool settings '{"document":"catalog","action":"search","query":"opus"}'
assert_status 0
assert_stdout_contains '"models/claude-opus-5.5"'
assert_stdout_contains '"anthropic"'

run_fyai tool settings '{"document":"catalog","action":"get","path":"models/claude-opus-5.5"}'
assert_status 0
assert_stdout_contains '"context_window"'

run_fyai tool settings '{"document":"catalog","action":"list","path":"agents"}'
assert_status 0
assert_stdout_contains '"codex"'

# The cheapest model of a provider, in one call.
run_fyai tool settings '{"document":"catalog","action":"select","from":"providers/anthropic/models","fields":["canonical_id","pricing/blended"],"sort":"pricing/blended","limit":1}'
assert_status 0
assert_stdout_contains '"matched"'
assert_stdout_contains '"pricing/blended"'

# An export is a file that a program reads while the invocation runs.
run_fyai tool settings '{"document":"catalog","action":"export"}'
assert_status 0
assert_stdout_contains 'catalog.json'

run_fyai tool settings '{"document":"catalog","action":"change","changes":[{"path":"models","value":[]}]}'
assert_stdout_contains 'give a source'

run_fyai config set model_access read
assert_status 0
run_fyai tool settings '{"document":"catalog","action":"change","source":"https://example.test/new-model","changes":[{"path":"models/manual-new","value":{"name":"manual-new"}}]}'
assert_stdout_contains 'model_access allows reads only'
run_fyai config set model_access review
assert_status 0

# A sourced model can be added without the configured scraper.
run_fyai tool settings '{"document":"catalog","action":"change","source":"https://example.test/new-model","changes":[{"path":"models/manual-new","value":{"name":"manual-new","context_window":64000}},{"path":"providers/openai/models/manual-new","value":{"canonical_id":"manual-new","provider_model_id":"manual-new"}}]}'
assert_status 0
assert_stdout_contains '"status": "pending"'
assert_stdout_contains '"id": "p1"'
run_fyai config proposals --output json
assert_stdout_contains '"document": "catalog"'
run_fyai catalog get models/manual-new
assert_status_nonzero
run_fyai --set display/markdown=false config review p1
assert_status 0
assert_stdout_contains 'manual-new'
assert_stdout_contains 'https://example.test/new-model'
run_fyai config approve p1
assert_status 0
assert_stdout_contains 'approved'
run_fyai catalog get providers/openai/models/manual-new/canonical_id
assert_stdout_contains 'manual-new'

run_fyai tool settings '{"document":"catalog","action":"change","source":"https://example.test/prices","changes":[{"path":"providers/openai/models/manual-new/pricing/input","value":0.25},{"path":"providers/openai/models/manual-new/pricing/output","value":1}]}'
assert_status 0
assert_stdout_contains '"status": "pending"'
assert_stdout_contains '"id": "p2"'
run_fyai config approve p2
assert_status 0
run_fyai catalog get providers/openai/models/manual-new/pricing
assert_stdout_contains '0.25'

run_fyai tool settings '{"document":"catalog","action":"change","source":"https://example.test/prices","changes":[{"path":"providers/openai/models/manual-new/pricing/input","value":0.1}]}'
assert_stdout_contains '"id": "p3"'
run_fyai config reject p3
assert_status 0
run_fyai catalog get providers/openai/models/manual-new/pricing/input
assert_stdout_contains '0.25'

# A schema failure leaves every path in the batch unchanged.
run_fyai tool settings '{"document":"catalog","action":"change","source":"https://example.test/models","changes":[{"path":"providers/openai/models/manual-new/pricing/input","value":0.1},{"path":"models/manual-new/context_window","value":"many"}]}'
assert_stdout_contains 'catalogue change is invalid'
run_fyai catalog get providers/openai/models/manual-new/pricing/input
assert_stdout_contains '0.25'

run_fyai tool settings '{"document":"catalog","action":"change","source":"https://example.test/prices","changes":[{"path":"providers/openai/root_url","value":"https://bad.example"}]}'
assert_stdout_contains 'catalogue change is invalid'

pass
