#!/bin/bash
# SPDX-License-Identifier: MIT
# Slash checkout forks historical state; reset and rewind retain the old head.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
run_fyai branch create source
assert_status 0
run_fyai -b source config set display/stream false
assert_status 0
run_fyai -b source config set display/stream true
assert_status 0

pty_run "$TEST_DIR/checkout.out" \
	"$FYAI_BIN" -k test-key -m mock-model -b main -i <<'PTY'
steps:
  - type: "/checkout source"
  - wait: switched to branch source
    timeout: session
PTY

pty_run "$TEST_DIR/snapshot.out" \
	"$FYAI_BIN" -k test-key -m mock-model -b source -i <<'PTY'
steps:
  - type: "/checkout source@{2}"
  - wait: switched to branch session/
    timeout: session
PTY

snapshot_name="$(grep -aoE 'created branch session/[0-9T.-]+' \
	"$TEST_DIR/snapshot.out" | head -1 | sed 's/^created branch //')"
[ -n "$snapshot_name" ] || fail "checkout did not name the snapshot branch"

run_fyai config get display/stream
assert_status 0
assert_stdout_contains "false"
run_fyai list reflog
assert_status 0
assert_stdout_contains "checkout"

pty_run "$TEST_DIR/rewind.out" \
	"$FYAI_BIN" -k test-key -m mock-model -b "$snapshot_name" -i <<'PTY'
steps:
  - type: "/rewind source@{0}"
  - wait: the previous head is session/
    timeout: session
PTY

run_fyai config get display/stream
assert_status 0
assert_stdout_contains "false"
run_fyai list reflog
assert_status 0
assert_stdout_contains "reset"

pty_run "$TEST_DIR/named.out" \
	"$FYAI_BIN" -k test-key -m mock-model -b source -i <<'PTY'
steps:
  - type: "/checkout -b named source@{2}"
  - wait: switched to branch named
    timeout: session
PTY

run_fyai -b named config get display/stream
assert_status 0
assert_stdout_contains "false"

pty_run "$TEST_DIR/reset.out" \
	"$FYAI_BIN" -k test-key -m mock-model -b named -i <<'PTY'
steps:
  - type: "/reset source@{0}"
  - wait: "the previous head is named@{1}"
    timeout: session
PTY

run_fyai -b named list reflog
assert_status 0
assert_stdout_contains "reset"

pass
