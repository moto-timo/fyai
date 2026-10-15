#!/bin/bash
# SPDX-License-Identifier: MIT
# A fullscreen session keeps the results of its slash commands, notices and
# diagnostics in a log. Escape hides the popup of the log and the indicator in
# the header, which counts the results, shows it again: a click on it and a key
# bound to fyai.messages.toggle both do. A result of the log has no module
# prefix.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start chat_basic_twice.json
driver=0
FYAI_PTY_ROWS=30 FYAI_PTY_COLS=100 FYAI_PTY_INPUT="first question" \
FYAI_PTY_NEEDLE="Hello" FYAI_PTY_TIMEOUT=20 \
FYAI_PTY_AFTER="wait-screen:Hello from the mock provider.|send:/help|wait-screen:Esc closes|raw:1b|wait-gone:Esc closes|wait-screen:≡1|click:≡1|wait-screen:Esc closes|raw:1b|wait-gone:Esc closes|raw:07|wait-screen:Esc closes|raw:07|wait-gone:Esc closes|send:/help|wait-screen:log · all · 2|raw:6c|wait-screen:log · notices|raw:78|wait-gone:Esc closes|send:/theme zzz|wait-screen:invalid display.theme" \
FYAI_PTY_AFTER_PAUSE=0 FYAI_PTY_AFTER_TIMEOUT=10 \
"$PYTHON" "$TESTS_DIR/pty_driver.py" "$TEST_DIR/pty.out" \
    "$FYAI_BIN" -k test-key --theme dark \
    --set display/markdown=true --set display/stream=false \
    --set display/screen=fullscreen \
    --set 'display/keys={prompt: {Ctrl-G: fyai.messages.toggle}}' \
    --set api=chat-completions \
    --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model -i ||
    driver=$?
if grep -a -q "needs a libfytimui" "$TEST_DIR/pty.out" 2>/dev/null; then
    skip "this build has no page support"
fi
if [ "$driver" -ne 0 ]; then
    tail -c 2000 "$TEST_DIR/pty.out" >&2
    fail "the log popup did not go as the case says"
fi
mock_stop 1
# A configuration error reaches the log as a diagnostic, without its module.
grep -a -q "invalid display.theme" "$TEST_DIR/pty.out" ||
    fail "the error of an unknown theme was not shown"
if grep -a -q "config: invalid display.theme" "$TEST_DIR/pty.out"; then
    fail "the log shows the module prefix of a configuration error"
fi
pass
