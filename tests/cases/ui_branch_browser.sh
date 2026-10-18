#!/bin/bash
# SPDX-License-Identifier: MIT
# A browser opens in the work pane and creates a branch through the editor.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
run_fyai branch create existing
assert_status 0

pty_run "$TEST_DIR/browser.out" \
	"$FYAI_BIN" -b main -k test-key --theme catppuccin:dark \
	--set display/markdown=true -m mock-model -i <<'PTY'
steps:
  - type: "/branches"
  - wait: Branches
    timeout: 1.5
  - write: "nreview\r\r"
  - wait: created branch review
    timeout: session
  - write: "i"
  - wait-screen: Field
  - write: "\e"
  - wait-gone: Field
  - write: "k\r"
  - wait-gone: Branches
  - wait-screen: existing
  - write: "\x1d"
PTY

run_fyai branch list
assert_status 0
assert_stdout_contains "review"
pass
