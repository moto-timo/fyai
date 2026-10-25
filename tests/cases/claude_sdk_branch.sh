#!/bin/bash
# SPDX-License-Identifier: MIT
# A branch named with -b is the SDK session, whatever its name: a name that
# does not exist starts the session, and the same name later continues it, so
# a conversation of the CLI and one of the SDK front are the same thing.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start claude_sdk_branch.json

cat > catalog.yaml <<CAT
models:
- name: br-chat
  capabilities: []
providers:
- name: chat-prov
  root_url: $MOCK_URL
  endpoints:
  - protocol: chat_completions
    endpoint: /v1/chat/completions
  models:
  - canonical_id: br-chat
    provider_model_id: br-chat
CAT
run_fyai catalog import catalog.yaml
assert_status 0

export MOCK_KEY=test-key
"$FYAI_BIN" --set api=chat-completions --set display/stream=false \
	--set "api_url=$MOCK_URL/v1/chat/completions" --set model=chat-prov/br-chat \
	--set 'api_key={type: env, value: MOCK_KEY}' >/dev/null 2>&1 ||
	fail "configure the project"

BRANCH=session/20260101T000000.000001

"$PYTHON" - "$FYAI_BIN" "$TEST_DIR" "$BRANCH" "$FYAI_TIMEOUT_SCALE" <<'PYEOF' || fail "SDK on a named branch"
import json
import os
import select
import subprocess
import sys
import time

binary, cwd, branch, scale = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])

def start():
    return subprocess.Popen(
        [binary, "-b", branch, "claude-sdk", "--output-format", "stream-json",
         "--verbose", "--system-prompt", "", "--input-format", "stream-json"],
        cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, bufsize=0)

def recv(proc):
    deadline = time.monotonic() + 20 * scale
    data = bytearray()
    while time.monotonic() < deadline:
        if not select.select([proc.stdout], [], [],
                             max(0, deadline - time.monotonic()))[0]:
            break
        ch = os.read(proc.stdout.fileno(), 1)
        if not ch:
            raise AssertionError("the SDK process closed: " +
                                 proc.stderr.read().decode())
        if ch == b"\n":
            return json.loads(data)
        data.extend(ch)
    raise AssertionError("timed out waiting for a frame: " + repr(data))

def ask(text):
    proc = start()
    frame = {"type": "user", "session_id": "", "parent_tool_use_id": None,
             "message": {"role": "user", "content": text}}
    proc.stdin.write((json.dumps(frame) + "\n").encode())
    proc.stdin.flush()
    while True:
        frame = recv(proc)
        if frame["type"] == "result":
            break
    proc.stdin.close()
    proc.wait(timeout=10 * scale)
    return frame

result = ask("first question")
assert result["is_error"] is False and result["result"] == "First answer.", result
assert result["session_id"] == branch, result
result = ask("second question")
assert result["is_error"] is False and result["result"] == "Second answer.", result
PYEOF

# The branch holds both exchanges, and no sdk/ branch was made.
run_fyai branch list --output json
assert_status 0
"$PYTHON" - "$TEST_DIR/stdout" "$BRANCH" <<'PYEOF' || fail "the branches after the session"
import json
import sys

rows = json.load(open(sys.argv[1]))
names = [r["branch"] for r in rows]
assert sys.argv[2] in names, names
assert not [n for n in names if n.startswith("sdk/")], names
PYEOF
run_fyai -b "$BRANCH" history --output json
assert_status 0
assert_stdout_contains "first question"
assert_stdout_contains "Second answer"

assert_request 1 'any(m.get("content") == "First answer." for m in r["body"]["messages"])'

mock_stop 2
pass
