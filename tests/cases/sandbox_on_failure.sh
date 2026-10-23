#!/bin/bash
# SPDX-License-Identifier: MIT
# A sandbox that cannot be set up stops the tool, unless `sandbox_on_failure` is
# `warn`: the tool then runs without it, and one warning gives the cause and the
# setting. A profile with a private home and no cover fails on every Linux host.
set -eu
[ "$(uname -s)" = Linux ] || exit 77
. "$(dirname "$0")/../harness.sh"

FYAI_TMPDIR_BASE="$(dirname "$FYAI_BIN")"
fyai_test_setup

config() {
	cat >"$TEST_DIR/onfail.yaml" <<YAML
sandbox_profile: broken
sandbox_cover: none
sandbox_on_failure: $1
sandbox_profiles:
  broken:
    extends: dev
    home:
      private: true
      method: overlay
YAML
}

config fail
run_fyai --config "$TEST_DIR/onfail.yaml" tool shell '{"command": "echo marker-4417"}' || true
assert_stdout_not_contains marker-4417

config warn
run_fyai --config "$TEST_DIR/onfail.yaml" tool shell '{"command": "echo marker-4417"}'
assert_status 0
assert_stdout_contains marker-4417
assert_stderr_contains 'the sandbox could not be set up'
assert_stderr_contains 'need a user namespace'
assert_stderr_contains 'sandbox_on_failure'
pass
