#!/bin/bash
# SPDX-License-Identifier: MIT
# `expose: [userns]` lets a program in the sandbox make a user namespace of its own,
# as bitbake does to cut off the network of a task. Without it the write to
# /proc/self/uid_map is denied. The paths of /proc that change the kernel stay
# read-only, and the schema rejects an exposure that fyai does not know.
set -eu
[ "$(uname -s)" = Linux ] || exit 77
command -v unshare >/dev/null || exit 77
. "$(dirname "$0")/../harness.sh"

FYAI_TMPDIR_BASE="$(dirname "$FYAI_BIN")"
fyai_test_setup
unshare -Urm true 2>/dev/null || exit 77

# shell_with EXPOSE COMMAND: run a command in the shell tool under a profile.
shell_with() {
	cat >"$TEST_DIR/userns.yaml" <<YAML
sandbox_profile: ns
sandbox_profiles:
  ns:
    extends: dev
    expose: $1
YAML
	run_fyai --config "$TEST_DIR/userns.yaml" tool shell '{"command": "'"$2"'"}'
}

nested="unshare -Ur sh -c 'id -u; echo nested-ok' 2>&1 || echo nested-denied"
# BitBake makes the namespace from Python, and writes each map with open(path, "w"),
# which truncates: util-linux opens the map without truncation and does not show it.
cat >"$TEST_DIR/nsprobe.py" <<'PYEOF'
import ctypes
import os

libc = ctypes.CDLL(None)
uid, gid = os.getuid(), os.getgid()
assert libc.unshare(0x50000000) == 0
with open("/proc/self/uid_map", "w") as f:
    f.write("%d %d 1" % (uid, uid))
with open("/proc/self/setgroups", "w") as f:
    f.write("deny")
with open("/proc/self/gid_map", "w") as f:
    f.write("%d %d 1" % (gid, gid))
print("py-ok")
PYEOF
bitbake="python3 $TEST_DIR/nsprobe.py 2>&1 || echo py-denied"
kernel='echo x > /proc/sys/kernel/hostname 2>&1 && echo sys-written || echo sys-protected'

shell_with '[]' "$nested; $bitbake"
assert_stdout_contains nested-denied
assert_stdout_contains py-denied

shell_with '[userns]' "$nested; $bitbake; $kernel"
assert_stdout_contains nested-ok
assert_stdout_contains py-ok
assert_stdout_not_contains py-denied
assert_stdout_not_contains nested-denied
assert_stdout_contains sys-protected
assert_stdout_not_contains sys-written

# A profile that grants /proc read-only already: the exposure adds the write.
cat >"$TEST_DIR/userns.yaml" <<YAML
sandbox_profile: ns
sandbox_profiles:
  ns:
    extends: dev
    allow:
      - { path: /proc, mode: ro }
    expose: [userns]
YAML
run_fyai --config "$TEST_DIR/userns.yaml" tool shell '{"command": "'"$bitbake"'"}'
assert_stdout_contains py-ok

# The build profile of the sample has the exposure.
printf 'sandbox_profile: build\n' >"$TEST_DIR/userns.yaml"
run_fyai --config "$TEST_DIR/userns.yaml" tool shell '{"command": "'"$nested"'"}'
assert_stdout_contains nested-ok

shell_with '[nosuch]' 'echo ran' || true
assert_stdout_not_contains ran
grep -q "expose/0: not in enum" "$TEST_DIR/stderr" || fail "an unknown exposure is not rejected"
pass
