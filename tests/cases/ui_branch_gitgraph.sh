#!/bin/bash
# SPDX-License-Identifier: MIT
# The gitgraph overview toggles to tree and back without closing the browser.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
run_fyai branch create main/feature
assert_status 0
run_fyai branch create main/feature/worker
assert_status 0

pty_run "$TEST_DIR/gitgraph.out" \
    "$FYAI_BIN" -k test-key --theme dark \
    --set display/markdown=true --set display/branch_view=gitgraph \
    --set display/diagram_charset=unicode -m mock-model -i <<'PTY'
steps:
  - type: "/branches"
  - wait: gitgraph overview
    timeout: session
  - write: "g"
  - wait-screen: "tree · / filter"
  - write: "g"
  - wait-screen: gitgraph overview
  - write: "\e"
  - wait-gone: Esc close
PTY

pty_run "$TEST_DIR/fallback.out" \
    "$FYAI_BIN" -k test-key --theme dark \
    --set display/branch_view=gitgraph --set display/diagram_theme=missing-theme \
    -m mock-model -i <<'PTY'
steps:
  - type: "/branches"
  - wait: "Diagram unavailable; showing plain rows."
    timeout: session
  - wait-screen: Esc close
  - write: "\e"
  - wait-gone: Esc close
PTY

pass
