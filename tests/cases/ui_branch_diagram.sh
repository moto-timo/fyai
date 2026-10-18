#!/bin/bash
# SPDX-License-Identifier: MIT
# Tree view retains selection and applies live display settings.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
run_fyai branch create main/child
assert_status 0
run_fyai branch create main/child/deep
assert_status 0
run_fyai branch create main-sibling
assert_status 0

pty_run "$TEST_DIR/diagram.out" \
    "$FYAI_BIN" -k test-key --theme dark \
    --set display/markdown=true --set display/diagram_charset=unicode \
    -m mock-model -i <<'PTY'
steps:
  - type: "/branches"
  - wait: "╰─"
    timeout: session
  - write: "\e[H"
  - write: "jj"
  - write: "\e[D"
  - wait-gone: "- deep"
  - write: "j\r"
  - wait-screen: switched to branch main-sibling
  - type: "/config set display/diagram_charset ascii"
  - type: "/branches"
  - wait-screen: "+-"
  - write: "\e"
  - wait-gone: Esc close
PTY

grep -qF "switched to branch main-sibling" "$TEST_DIR/diagram.out" || \
	fail "tree navigation skipped the row after a collapsed group"

pass
