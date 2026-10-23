#!/bin/bash
# SPDX-License-Identifier: MIT
# The player of fyai cast play on a terminal: it replays the recording on the
# alternate screen, jumps between markers by key, lists the markers, and acts on
# a click on a control. The recording is written by hand and short.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup

"$PYTHON" - "$TEST_DIR/run.cast" <<'PY'
import json
import sys

with open(sys.argv[1], "w") as f:
    f.write(json.dumps({"version": 2, "width": 60, "height": 12}) + "\n")
    for event in ([0.01, "o", "\x1b[2J\x1b[Hfirst screen"],
                  [0.1, "m", "turn: begin"],
                  [0.2, "o", "\x1b[2J\x1b[Hsecond screen"],
                  [0.3, "m", "turn: end, done"]):
        f.write(json.dumps(event) + "\n")
PY

pty_run "$TEST_DIR/pty.out" "$FYAI_BIN" cast play "$TEST_DIR/run.cast" <<'PTY'
timeout: 30
ready: "\x1b[?1049h"
steps:
  # The recording plays to its end, and the controls stay while it is not playing.
  - wait-screen: second screen
  - wait-screen: events
  # A marker back and forth by key.
  - write: "["
  - wait-screen: first screen
  - write: "]"
  - wait-screen: second screen
  # The list of markers, by key and by click.
  - write: "e"
  - wait-screen: "turn: end, done"
  - write: "e"
  - wait-gone: "turn: begin"
  - click: events
  - wait-screen: "turn: begin"
  - write: "q"
  - write: "q"
PTY

pass
