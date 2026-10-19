#!/bin/bash
# SPDX-License-Identifier: MIT
# A pinned root reads one published state and writes nothing. An attachment
# goes into the next message, so it is refused there rather than silently
# written.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup

printf '\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x04\x00\x00\x00\x03\x00\x08\x06\x00\x00\x00' \
    >"$TEST_DIR/shot.png"

run_fyai --set model=first
assert_status 0

"$FYAI_BIN" root print >"$TEST_DIR/root" 2>"$TEST_DIR/stderr" || fail "root print"
ROOT="$(cat "$TEST_DIR/root")"
[ -n "$ROOT" ] || fail "root print produced nothing"

# The live tree takes the attachment.
run_fyai --image "$TEST_DIR/shot.png" image list --output json
assert_status 0
assert_stdout_contains "image/png"

# A pinned root refuses it, and says why.
run_fyai --root "$ROOT" --image "$TEST_DIR/shot.png" image list --output json
assert_status_nonzero
assert_stderr_contains "read-only"

pass
