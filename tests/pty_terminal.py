#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""A terminal for a Python test that drives a program through a PTY itself.

The PTY driver of the suite is the hidden verb `__pty-driver` of fyai. A case
that must hold the descriptors, such as one that signals the process group,
plays the terminal with this class.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from screen import Screen                                     # noqa: E402

QUERY = b"\x1b[6n"
# A program asks for the background with OSC 11, ended by ST or BEL.
BACKGROUND_QUERIES = (b"\x1b]11;?\x1b\\", b"\x1b]11;?\x07")
# Every terminal answers DA1, and the fyai terminal probe ends with it.
DA1_QUERY = b"\x1b[c"
DA1_REPLY = b"\x1b[?62;22c"
TERMINAL = None


class Terminal:
    """The terminal a program under test asks where its cursor is.

    A program that stands inline on the screen asks with CSI 6n and waits for
    CSI row;col R, which a terminal always answers. A pseudo-terminal answers
    nothing, so the driver answers from a screen fed every byte before the
    question. It answers DA1, as every terminal does, which ends the probe
    that fyai makes at start. A case that sets $FYAI_PTY_BACKGROUND, such as
    rgb:1e1e/1e1e/2e2e, also gets that answer to an OSC 11 query; without it
    the background query goes unanswered, as on a terminal that does not
    answer it. $FYAI_PTY_BACKGROUND_WHILE_STARTING stops answering OSC 11
    once the driver has typed: a query made after the session started goes
    unanswered.
    """

    def __init__(self, rows, cols):
        self.screen = Screen(rows, cols)
        self.held = b""
        self.background = os.environ.get("FYAI_PTY_BACKGROUND")
        self.background_starting = bool(
            os.environ.get("FYAI_PTY_BACKGROUND_WHILE_STARTING"))

    def started(self):
        """The driver has typed: a later query is the live display's."""
        if self.background_starting:
            self.background = None

    def resize(self, rows, cols):
        clipboard = self.screen.clipboard
        self.screen = Screen(rows, cols)
        self.screen.clipboard = clipboard
        self.held = b""

    def read(self, fd):
        chunk = os.read(fd, 65536)
        if not chunk:
            return chunk
        buf = self.held + chunk
        queries = [QUERY, DA1_QUERY]
        if self.background:
            queries += BACKGROUND_QUERIES
        start = 0
        while True:
            found = [(buf.find(q, start), q) for q in queries]
            found = [f for f in found if f[0] >= 0]
            if not found:
                break
            at, query = min(found)
            self.screen.feed(buf[start:at + len(query)])
            if query == QUERY:
                os.write(fd, b"\x1b[%d;%dR" % (self.screen.row + 1,
                                                self.screen.col + 1))
            elif query == DA1_QUERY:
                os.write(fd, DA1_REPLY)
            else:
                os.write(fd, b"\x1b]11;%s\x1b\\" % self.background.encode())
            start = at + len(query)
        # A question can be split between two reads: hold its start.
        keep = 0
        for query in queries:
            for k in range(len(query) - 1, 0, -1):
                if buf.endswith(query[:k]):
                    keep = max(keep, k)
                    break
        self.screen.feed(buf[start:len(buf) - keep])
        self.held = buf[len(buf) - keep:]
        return chunk
