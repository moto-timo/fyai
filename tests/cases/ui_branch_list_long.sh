#!/bin/bash
# SPDX-License-Identifier: MIT
# A branch view is a record: it must reach the scrollback whole, not a pane.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup

for i in $(seq -w 1 20); do
	run_fyai branch create "row$i"
	assert_status 0
done
run_fyai checkout main
assert_status 0

pty_run "$TEST_DIR/branch-list.out" \
    "$FYAI_BIN" -k test-key --theme catppuccin:dark \
    --set display/markdown=true -m mock-model -i <<'PTY'
steps:
  - type: "/branch --all"
  - wait: row20
    timeout: session
PTY

"$PYTHON" - "$TEST_DIR/branch-list.out" <<'EOF' || \
    fail "long branch list did not reach the scrollback"
import re
import sys

data = open(sys.argv[1], "rb").read()
plain = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", data)
if "● branch".encode() in plain:
    raise SystemExit("branch view received status-pane chrome")
for i in range(1, 21):
    needle = ("row%02d" % i).encode()
    if needle not in plain:
        raise SystemExit("branch %s never reached the scrollback" % needle)
EOF

pass
