#!/bin/bash
# SPDX-License-Identifier: MIT
# The resume picker opens on the session tree, resumes the one Enter selects,
# and stores nothing when it is cancelled.
set -eu
. "$(dirname "$0")/../harness.sh"

# A temporary base can end in a slash, as it does on macOS runners.
FYAI_TMPDIR_BASE="${TMPDIR:-/tmp}/"
fyai_test_setup

run_fyai branch create older
assert_status 0
run_fyai branch describe older "<command-name>/clear</command-name>"
assert_status 0
run_fyai branch create newer
assert_status 0
run_fyai branch describe newer "the newest session"
assert_status 0

# Make `newer` the most recently updated session, so the row the picker opens
# on is the one this case names.
# It also holds the mock provider settings that the resumed session uses.
mock_start chat_basic.json
run_fyai -b newer --set temperature=0.5 --set api=chat-completions \
	--set "api_url=$MOCK_URL/v1/chat/completions" \
	--set display/stream=false
assert_status 0

# The picker holds the keys as soon as it opens, so the line the driver sends
# first is read as keys: Enter resumes, Escape cancels.

# --- Enter resumes the selected session ----------------------------------
# The resumed session publishes its first exchange to the branch the picker
# chose, so the stored state says which session was resumed.
# The picker draws its footer before its rows, and Enter with no row does
# nothing: Enter waits for the header of the selected session.
pty_run "$TEST_DIR/pick.out" \
	"$FYAI_BIN" -k test-key -m mock-model resume <<'PTY'
rows: 24
cols: 90
ready: toggle foreign sessions
steps:
  - wait: toggle foreign sessions
    timeout: session
  - wait-screen: "fyai · newer"
  - write: "\r"
  - wait-gone: toggle foreign sessions
  - type: say hello
  - wait-screen: Hello from the mock provider.
  - type: "/help"
  - wait-screen: "/transcript-system"
  - write: "\x1d"
PTY
mock_stop 1

# The picker drew the sessions it offers and selected the newest one.
grep -qF "toggle foreign sessions" "$TEST_DIR/pick.out" || \
	fail "the picker did not open"
grep -qF "the newest session" "$TEST_DIR/pick.out" || \
	fail "the picker did not describe the sessions"
"$PYTHON" - "$TEST_DIR/pick.out" <<'EOF' || \
	fail "the picker did not use the configured colour theme"
import sys

data = open(sys.argv[1], "rb").read()
end = data.find(b"Hello from the mock provider.")
if end < 0 or b"\x1b[38;2;" not in data[:end]:
    raise SystemExit("no themed foreground in the picker")
if b"/clear" in data[:end]:
    raise SystemExit("injected Claude command metadata in the picker")
EOF
# Enter resumed the newest of them, and the exchange went to it.
assert_state_contains "Hello from the mock provider." -b newer dump state
assert_state_absent "Hello from the mock provider." -b main dump state
"$PYTHON" - "$TEST_DIR/pick.out" <<'EOF' || \
	fail "resumed session lost automatic colour"
import sys

data = open(sys.argv[1], "rb").read()
start = data.rfind(b"Hello from the mock provider.")
help_text = data.find(b"Topics", start)
if start < 0 or help_text < 0 or b"\x1b[" not in data[start:help_text]:
    raise SystemExit("no styling after branch configuration was adopted")
EOF

# A source transcript appears beside native sessions and Enter imports it
# before resuming its generated branch.
mkdir -p "$TEST_DIR/claude-root/projects/project-a"
sed "s|@CWD@|$TEST_DIR|g" \
	"$TESTS_DIR/data/claude-session-picker.jsonl" > \
	"$TEST_DIR/claude-root/projects/project-a/claude-picker.jsonl"
touch -t 203001010000 \
	"$TEST_DIR/claude-root/projects/project-a/claude-picker.jsonl"
mock_start chat_basic.json
CLAUDE_CONFIG_DIR="$TEST_DIR/claude-root" \
pty_run "$TEST_DIR/foreign-pick.out" \
	"$FYAI_BIN" -k test-key --color off -m mock-model \
		--set api=chat-completions \
		--set "api_url=$MOCK_URL/v1/chat/completions" \
		--set display/stream=false \
		--set display/branch_preview=bottom resume <<'PTY'
rows: 24
cols: 100
ready: toggle foreign sessions
steps:
  - wait: toggle foreign sessions
    timeout: session
  - write: "f"
  - wait-screen: claude-code
  - write: "f"
  - wait-gone: Continue this imported session
  - write: "f"
  - wait-screen: Continue this imported session
  - write: "\e[H"
  - wait-screen: "Group · import"
  - write: "j"
  - wait-screen: "/claude-code"
  - write: "j"
  - wait-screen: "2030-01-01"
  - snapshot: "${TEST_DIR}/foreign-picker.snap"
  - write: "i"
  - wait-screen: Ready to continue.
  - write: "\e"
  - frame: 2
  - write: "\r"
  - wait-gone: toggle foreign sessions
  - type: say hello
  - wait-screen: Hello from the mock provider.
  - write: "\x1d"
PTY
mock_stop 1

grep -qF "import/claude-code/claude-picker" "$TEST_DIR/foreign-pick.out" || \
	fail "the picker did not show the Claude session"
grep -qF "import [group]" "$TEST_DIR/foreign-pick.out" &&
	grep -qF "claude-code [group]" "$TEST_DIR/foreign-pick.out" || \
	fail "the picker did not group foreign sessions in the branch tree"
assert_state_contains "Hello from the mock provider." \
	-b import/claude-code/claude-picker dump state
"$PYTHON" - "$TEST_DIR/foreign-picker.snap" "$TESTS_DIR" <<'EOF' || \
	fail "the picker regions were not separated"
import sys

sys.path.insert(0, sys.argv[2])
from screen import Screen

screen = Screen(24, 100)
screen.feed(open(sys.argv[1], "rb").read())
rows = screen.display()
selected = next(i for i, row in enumerate(rows) if "claude-code · claude-p" in row)
if "3 turns · 130 tokens" not in rows[selected + 1]:
    raise SystemExit("the selected session has no turn and token summary")
session = next(i for i, row in enumerate(rows)
               if "Continue this imported session with a title longer" in row)
if "than forty-eight bytes." not in rows[session]:
    raise SystemExit("the session title was clipped before layout")
tree = next(i for i, row in enumerate(rows) if "import [group]" in row)
commands = next(i for i, row in enumerate(rows)
                if "toggle foreign sessions" in row)
if tree < selected + 2 or rows[tree - 1].strip():
    raise SystemExit("no blank row before the session tree")
if commands <= session or rows[commands - 1].strip():
    raise SystemExit("no blank row before the command legend")
if "select" not in rows[commands + 1] or "fold" not in rows[commands + 1]:
    raise SystemExit("the command legend is incomplete")
if not any("Ready to continue." in row for row in rows):
    raise SystemExit("the foreign session has no automatic preview")
EOF
"$PYTHON" - "$TEST_DIR/foreign-pick.out" <<'EOF' || \
	fail "foreign discovery delayed the initial native-session frame"
import sys

data = open(sys.argv[1], "rb").read()
native = data.find(b"main [current]")
foreign = data.find(b"claude-code")
if native < 0 or foreign < 0 or native > foreign:
    raise SystemExit("foreign row preceded the native-session frame")
EOF

# Modern Codex rollouts put injected user-role context before turn_context.
# Both picker views name the session with the real prompt after that boundary.
mkdir -p "$TEST_DIR/codex-root/sessions/2026/01/01"
cp "$TESTS_DIR/data/codex-session-index.jsonl" \
	"$TEST_DIR/codex-root/session_index.jsonl"
sed "s|@CWD@|$TEST_DIR|g" \
	"$TESTS_DIR/data/codex-session-picker.jsonl" > \
	"$TEST_DIR/codex-root/sessions/2026/01/01/codex-picker.jsonl"
# g must change nothing here, so no frame says it was read: g and Escape go in
# one write, which keeps their order.
CODEX_HOME="$TEST_DIR/codex-root" \
CLAUDE_CONFIG_DIR="$TEST_DIR/no-claude" \
pty_run "$TEST_DIR/codex-picker.out" \
	"$FYAI_BIN" -k test-key --color off -m mock-model \
		--set display/branch_preview=off resume <<'PTY'
rows: 24
cols: 100
ready: toggle foreign sessions
steps:
  - wait: toggle foreign sessions
    timeout: session
  - write: "f"
  - wait-screen: Repair session picker
  - write: "g\e"
PTY

grep -qF "Repair session picker" "$TEST_DIR/codex-picker.out" || \
	fail "the picker did not show the Codex thread name"
grep -qF "codex [group]" "$TEST_DIR/codex-picker.out" || \
	fail "the picker did not group Codex sessions"
grep -qF "gitgraph overview" "$TEST_DIR/codex-picker.out" && \
	fail "the resume picker switched to gitgraph" || true
grep -qF "the newest session" "$TEST_DIR/codex-picker.out" || \
	fail "tree view did not show the native session description"
grep -qF "Injected repository instructions" "$TEST_DIR/codex-picker.out" && \
	fail "the picker displayed injected Codex context" || true

# Selecting a session does not move HEAD.
run_fyai root show
assert_status 0
assert_stdout_contains "main"

# --- Escape cancels and stores nothing -----------------------------------
run_fyai list reflog
assert_status 0
cp "$TEST_DIR/stdout" "$TEST_DIR/reflog.before"

pty_run "$TEST_DIR/cancel.out" \
	"$FYAI_BIN" -k test-key --color off -m mock-model resume <<'PTY'
rows: 24
cols: 90
ready: toggle foreign sessions
steps:
  - type: "\e"
  - wait: toggle foreign sessions
    timeout: session
PTY

grep -qF "toggle foreign sessions" "$TEST_DIR/cancel.out" || \
	fail "the picker did not open"

# A cancelled picker publishes nothing.
run_fyai list reflog
assert_status 0
cmp -s "$TEST_DIR/reflog.before" "$TEST_DIR/stdout" || \
	fail "a cancelled picker changed the stored state"

pass
