#!/bin/bash
# SPDX-License-Identifier: MIT
# The Claude Agent SDK protocol: a session with a tool call, its resumption,
# an interrupt, and the options and requests that fyai refuses.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
printf 'hello\n' > notes.txt
mock_start claude_sdk.json

# An SDK gives only the options of the Claude CLI, so the session takes the
# provider from the configuration of the project.
export MOCK_KEY=test-key
"$FYAI_BIN" --set api=chat-completions --set display/stream=false \
	--set "api_url=$MOCK_URL/v1/chat/completions" --set model=mock-model \
	--set 'api_key={type: env, value: MOCK_KEY}' >/dev/null 2>&1 ||
	fail "configure the project"

ln -s "$FYAI_BIN" "$TEST_DIR/claude"
version="$("$TEST_DIR/claude" -v)"
case "$version" in
2.*" (fyai "*) ;;
*) fail "claude -v printed '$version'" ;;
esac

"$PYTHON" - "$FYAI_BIN" "$TEST_DIR" "$FYAI_TIMEOUT_SCALE" <<'PYEOF' || fail "Claude SDK session"
import json
import os
import select
import subprocess
import sys
import time

binary, cwd, scale = sys.argv[1], sys.argv[2], int(sys.argv[3])
base = ["--output-format", "stream-json", "--verbose",
        "--system-prompt", "", "--input-format", "stream-json"]

def start(extra=()):
    return subprocess.Popen([binary] + base + list(extra), cwd=cwd,
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, bufsize=0)

def send(proc, frame):
    proc.stdin.write((json.dumps(frame) + "\n").encode())
    proc.stdin.flush()

def recv(proc, timeout=20):
    deadline = time.monotonic() + timeout * scale
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

def until_result(proc):
    frames = []
    while True:
        frame = recv(proc)
        frames.append(frame)
        if frame["type"] == "result":
            return frames

def finish(proc, status):
    proc.stdin.close()
    proc.wait(timeout=10 * scale)
    err = proc.stderr.read().decode()
    assert proc.returncode == status, (proc.returncode, err)
    return err

def user(text):
    return {"type": "user", "session_id": "", "parent_tool_use_id": None,
            "message": {"role": "user", "content": text}}

proc = start()
send(proc, {"type": "control_request", "request_id": "req_1",
            "request": {"subtype": "initialize", "hooks": None}})
reply = recv(proc)
assert reply["type"] == "control_response", reply
assert reply["response"]["subtype"] == "success", reply
assert reply["response"]["request_id"] == "req_1", reply
send(proc, user("read the notes"))
frames = until_result(proc)
init = frames[0]
assert init["type"] == "system" and init["subtype"] == "init", init
sid = init["session_id"]
assert "Read" in init["tools"] and "ask_user" not in init["tools"], init
uses = [b for f in frames if f["type"] == "assistant"
        for b in f["message"]["content"] if b["type"] == "tool_use"]
assert uses == [{"type": "tool_use", "id": "call_sdk_read",
                 "name": "Read", "input": {"file_path": "notes.txt"}}], uses
results = [b for f in frames if f["type"] == "user"
           for b in f["message"]["content"]]
assert len(results) == 1 and results[0]["type"] == "tool_result", results
assert results[0]["tool_use_id"] == "call_sdk_read", results
assert "hello" in json.dumps(results[0]["content"]), results
result = frames[-1]
assert result["subtype"] == "success" and result["is_error"] is False, result
assert result["result"] == "The notes say hello.", result
assert result["num_turns"] == 2 and result["session_id"] == sid, result
assert result["usage"]["input_tokens"] == 85, result
assert all(f.get("session_id") == sid for f in frames), frames
finish(proc, 0)

proc = start(["--resume=" + sid])
send(proc, user("again"))
frames = until_result(proc)
assert frames[0]["session_id"] == sid, frames[0]
assert frames[-1]["result"] == "Resumed.", frames[-1]
finish(proc, 0)

proc = start(["--tools", "Read"])
send(proc, user("limited"))
assert until_result(proc)[-1]["result"] == "Limited."
finish(proc, 0)

proc = start()
send(proc, {"type": "control_request", "request_id": "req_h",
            "request": {"subtype": "initialize", "hooks": {
                "PreToolUse": [{"matcher": "(",
                                "hookCallbackIds": ["hook_0"]}]}}})
reply = recv(proc)
assert reply["response"]["subtype"] == "error", reply
assert "regular expression" in reply["response"]["error"], reply
send(proc, {"type": "control_request", "request_id": "req_x",
            "request": {"subtype": "rewind_files"}})
reply = recv(proc)
assert reply["response"]["subtype"] == "error", reply
finish(proc, 0)

proc = start(["--permission-prompt-tool", "mcp__perm__ask"])
err = finish(proc, 1)
assert "the permission prompt tool 'mcp__perm__ask' is not supported" in err, err

proc = start(["--fork-session"])
err = finish(proc, 1)
assert "--fork-session needs a session to fork" in err, err

proc = start(["--plugin-dir", "plugins"])
err = finish(proc, 1)
assert "--plugin-dir is not supported" in err, err

proc = start(["--resume=no-such-session"])
err = finish(proc, 1)
assert "no session with ID 'no-such-session'" in err, err
PYEOF

mock_stop 4
assert_request 0 'all(t["function"]["name"] != "ask_user" for t in r["body"]["tools"])'
assert_request 3 '[t["function"]["name"] for t in r["body"]["tools"]] == ["read_file"]'
assert_request 3 '"web_search_options" not in r["body"]'
assert_request 2 'r["body"]["messages"][-1]["content"] == "again"'
assert_request 2 'any(m.get("content") == "The notes say hello." for m in r["body"]["messages"])'

mock_start claude_sdk_interrupt.json
"$FYAI_BIN" --set "api_url=$MOCK_URL/v1/chat/completions" >/dev/null 2>&1 ||
	fail "point the project at the second mock"
"$PYTHON" - "$FYAI_BIN" "$TEST_DIR" "$FYAI_TIMEOUT_SCALE" <<'PYEOF' || fail "Claude SDK interrupt"
import json
import os
import select
import subprocess
import sys
import time

binary, cwd, scale = sys.argv[1], sys.argv[2], int(sys.argv[3])
proc = subprocess.Popen([binary, "--output-format", "stream-json",
                         "--input-format", "stream-json"], cwd=cwd,
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE, bufsize=0)

def send(frame):
    proc.stdin.write((json.dumps(frame) + "\n").encode())
    proc.stdin.flush()

def recv(timeout=20):
    deadline = time.monotonic() + timeout * scale
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

send({"type": "user", "session_id": "", "parent_tool_use_id": None,
      "message": {"role": "user", "content": "wait for me"}})
assert recv()["subtype"] == "init"
# The mock holds its reply: interrupt once the request is in flight.
requests = os.path.join(cwd, "requests.jsonl")
deadline = time.monotonic() + 20 * scale
while not (os.path.exists(requests) and os.path.getsize(requests)):
    assert time.monotonic() < deadline, "the request did not arrive"
    select.select([], [], [], 0.02)
send({"type": "control_request", "request_id": "req_i",
      "request": {"subtype": "interrupt"}})
frames = []
while True:
    frame = recv()
    frames.append(frame)
    if frame["type"] == "result":
        break
acks = [f for f in frames if f["type"] == "control_response"]
assert acks and acks[0]["response"]["subtype"] == "success", frames
result = frames[-1]
assert result["is_error"] is True, result
assert result["subtype"] == "error_during_execution", result
open(os.path.join(cwd, "release"), "w").close()
proc.stdin.close()
proc.wait(timeout=10 * scale)
assert proc.returncode == 1, proc.stderr.read().decode()
PYEOF

mock_stop_quiet
[ ! -e "$TEST_DIR/stream-wait-failed" ] || fail "the mock reply was not released"
pass
