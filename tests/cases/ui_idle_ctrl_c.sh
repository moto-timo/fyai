#!/bin/bash
# SPDX-License-Identifier: MIT
# Verify SIGINT handling at an idle PTY prompt.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup

"$PYTHON" - "$FYAI_BIN" <<'EOF' || fail "idle Ctrl-C behaviour regressed"
import fcntl
import os
import pty
import select
import struct
import sys
import termios
import time
from term_reply import answer_da1

BIN = sys.argv[1]


def spawn():
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.execv(BIN, [BIN, "-k", "test-key", "-i"])
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
    return pid, fd


def drain(fd, seconds):
    end = time.monotonic() + seconds
    out = b""
    while time.monotonic() < end:
        if select.select([fd], [], [], 0.1)[0]:
            try:
                chunk = os.read(fd, 65536)
                answer_da1(fd, chunk)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
    return out


def settle(fd, pid):
    """Wait for the prompt: a fixed sleep races ASAN and slow runners."""
    deadline = time.monotonic() + 15
    seen = b""
    while time.monotonic() < deadline and b"\x1b[?25h" not in seen:
        seen += drain(fd, 0.2)
    if b"\x1b[?25h" not in seen:
        raise SystemExit("fyai never reached an interactive prompt")


def read_until(fd, needle, seconds=15):
    """Read the terminal until @needle appears; return what was read."""
    end = time.monotonic() + seconds
    seen = b""
    while time.monotonic() < end and needle not in seen:
        seen += drain(fd, 0.1)
    if needle not in seen:
        raise SystemExit("the terminal never showed %r" % needle)
    return seen


def wait_exit(fd, pid, seconds):
    """Read the terminal until the child ends: a pty holds 1 KiB on macOS."""
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        w, status = os.waitpid(pid, os.WNOHANG)
        if w:
            return status
        drain(fd, 0.1)
    return None


def kill(pid):
    try:
        os.kill(pid, 9)
        os.waitpid(pid, 0)
    except OSError:
        pass


# 1. Ctrl-C on an empty idle prompt ends the session.
pid, fd = spawn()
try:
    settle(fd, pid)
    os.write(fd, b"\x03")
    status = wait_exit(fd, pid, 5)
    if status is None:
        raise SystemExit("Ctrl-C on an idle prompt did not end the session")
    if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
        raise SystemExit("idle Ctrl-C exit was not clean: %r" % (status,))
finally:
    kill(pid)

# 2. Ctrl-C with a half-typed line discards the line and keeps the session;
#    a further Ctrl-C, now on an empty prompt, ends it.
pid, fd = spawn()
try:
    settle(fd, pid)
    os.write(fd, b"do not submit me")
    read_until(fd, b"do not submit me")
    os.write(fd, b"\x03")
    # The session is alive after the line went if it takes more input.
    os.write(fd, b"alive")
    read_until(fd, b"alive")
    if os.waitpid(pid, os.WNOHANG)[0]:
        raise SystemExit("Ctrl-C threw away a typed line and the session")
    os.write(fd, b"\x03")
    os.write(fd, b"\x03")
    if wait_exit(fd, pid, 5) is None:
        raise SystemExit("Ctrl-C after the line was discarded did not exit")
finally:
    kill(pid)
EOF

pass
