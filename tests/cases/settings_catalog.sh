#!/bin/bash
# SPDX-License-Identifier: MIT
# The settings tool reads the catalogue of the branch: a search finds a model
# and the providers that offer it, get reads one item by its path, and the
# catalogue cannot be changed through the tool.
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

run_fyai tool settings '{"document":"catalog","action":"change","changes":[{"path":"models","value":[]}]}'
assert_stdout_contains 'the catalogue is read only'

pass
