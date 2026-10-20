#!/bin/bash
# SPDX-License-Identifier: MIT
# Tab completes the @PATH a line ends with: "see @no" becomes
# "see @notes\ one.txt " with the blank of the name escaped, a quote and a
# backslash in a name are escaped too, a directory goes on with a slash,
# "@sr" to "@src/", and a second Tab goes on inside it. ~/ is the home
# directory and stays in the line. The path of /attach takes ~/ the same way.
# A "!" line is a command of the shell and completes no path.
#
# Both modes of display/completion are run. With tab, the default, Tab opens
# the popup, and with one candidate it completes at once. With auto the popup
# is open as the line is typed, and with one candidate Tab completes at once.
# With three, Tab moves the cursor and Enter takes the one under it, and the
# popup stands under the "@" of the mention.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mkdir -p src three a-rather-long-directory-prefix-for-the-test
printf 'one\n' >"notes one.txt"
printf 'two\n' >src/inner.txt
printf 'q\n' >"it's.txt"
printf 'b\n' >'back\slash.txt'
for name in aa.txt ab.txt ac.txt; do
	printf 'x\n' >"three/$name"
	printf 'y\n' >"a-rather-long-directory-prefix-for-the-test/$name"
done
# the harness redirects HOME into the scratch directory: this is no real home
printf 'three\n' >"$HOME/far.txt"

for mode in tab auto; do
	mock_start chat_basic.json
	driver=0
	pty_run "$TEST_DIR/pty-$mode.out" \
	    "$FYAI_BIN" -k test-key --theme dark \
	    --set display/markdown=true --set display/stream=false \
	    --set display/screen=fullscreen --set display/completion=$mode \
	    --set api=chat-completions \
	    --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model -i <<'PTY' ||
rows: 24
cols: 100
timeout: 20
wait_timeout: 10
steps:
  - type: first question
  - wait: Hello
    timeout: session
  - wait-screen: Hello from the mock provider.
  - write: "see @no"
  - write: "\t"
  - wait-screen: "see @notes\\ one.txt"
  - write: "@sr"
  - write: "\t"
  - wait-screen: "@src/"
  - write: "\t"
  - wait-screen: "@src/inner.txt"
  - write: "@~/fa"
  - write: "\t"
  - wait-screen: "@~/far.txt"
  - write: "\x15"
  - wait-gone: "see @notes"
  - wait-gone: "inner.txt"
  - write: "@it"
  - write: "\t"
  - wait-screen: "@it\\'s.txt"
  - write: "\x15"
  - wait-gone: "@it"
  - write: "@ba"
  - write: "\t"
  - wait-screen: "@back\\\\slash.txt"
  - write: "\x15"
  - wait-gone: "@back"
  - write: "!echo @no\tZ"
  - wait-screen: "!echo @noZ"
  - write: "\x15"
  - wait-gone: "!echo"
  - write: "/attach ~/fa"
  - write: "\t"
  - wait-screen: "/attach ~/far.txt"
  - write: "\x15"
  - wait-gone: "/attach"
PTY
	    driver=$?
	if [ "$driver" -ne 0 ]; then
		tail -c 2000 "$TEST_DIR/pty-$mode.out" >&2
		fail "$mode: Tab did not complete the @PATH of the line"
	fi
	mock_stop 1
done

# The script of the popup run: with tab, a Tab opens the popup first.
popup_script() {
	cat <<'PTY'
rows: 24
cols: 100
timeout: 20
wait_timeout: 10
steps:
  - type: first question
  - wait-screen: Hello from the mock provider.
  - write: "see @a-rather-long-directory-prefix-for-the-test/a"
PTY
	if [ "$1" = tab ]; then
		printf '  - write: "\\t"\n'
	fi
	cat <<'PTY'
  - wait-screen: "@a-rather-long-directory-prefix-for-the-test/ac.txt"
  - snapshot: "${TEST_DIR}/popup.snap"
  - write: "\e[B"
  - write: "\r"
  - wait-gone: "ac.txt"
  - wait-input: "ab.txt"
  - write: "\x15"
  - wait-gone: "ab.txt"
PTY
}

# Three candidates: the popup lists them in the order of the names, Down moves
# the cursor to the second, and Enter takes it. The popup stands under the "@"
# of the mention, whatever the length of the directory before the name.
for mode in tab auto; do
	mock_start chat_basic.json
	driver=0
	popup_script $mode >"$TEST_DIR/popup-$mode.yaml"
	pty_run "$TEST_DIR/pty-popup-$mode.out" \
	    "$FYAI_BIN" -k test-key --theme dark \
	    --set display/markdown=true --set display/stream=false \
	    --set display/screen=fullscreen --set display/completion=$mode \
	    --set api=chat-completions \
	    --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model -i \
	    <"$TEST_DIR/popup-$mode.yaml" || driver=$?
	if [ "$driver" -ne 0 ]; then
		tail -c 2000 "$TEST_DIR/pty-popup-$mode.out" >&2
		fail "$mode: Enter did not take the second of three candidates"
	fi
	mock_stop 1

"$PYTHON" - "$TEST_DIR/popup.snap" "$TESTS_DIR" <<'PY' || fail "$mode: the popup is not under the @ of the mention"
import sys

sys.path.insert(0, sys.argv[2])
from screen import Screen

term = Screen(24, 100)
term.feed(open(sys.argv[1], "rb").read())
rows = term.display()
prompt = next(r for r in rows if "see @a-rather" in r)
labels = [r for r in rows if "│" in r and "@a-rather" in r]
if len(labels) != 3:
    raise SystemExit("the popup does not list three names: %r" % rows)
want = prompt.index("@")
for label in labels:
    got = label.index("@")
    if got != want:
        raise SystemExit("the label starts at column %d, the @ is at %d: %r"
                         % (got, want, rows))
names = [l.split("/")[-1].strip(" │") for l in labels]
if names != sorted(names):
    raise SystemExit("the names are not in order: %r" % names)
PY
done

pass
