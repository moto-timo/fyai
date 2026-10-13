#!/bin/bash
# SPDX-License-Identifier: MIT
# Structured output, stream events, forked and continued sessions, the turn
# limit and the agents of the Claude Agent SDK protocol.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start claude_sdk_extra.json

export MOCK_KEY=test-key
"$FYAI_BIN" --set api=chat-completions --set display/stream=false \
	--set "api_url=$MOCK_URL/v1/chat/completions" --set model=mock-model \
	--set 'api_key={type: env, value: MOCK_KEY}' >/dev/null 2>&1 ||
	fail "configure the project"

"$PYTHON" - "$FYAI_BIN" "$TEST_DIR" "$FYAI_TIMEOUT_SCALE" <<'PYEOF' || fail "Claude SDK extra"
import json
import os
import select
import subprocess
import sys
import time

binary, cwd, scale = sys.argv[1], sys.argv[2], int(sys.argv[3])
base = ["--output-format", "stream-json", "--verbose",
        "--input-format", "stream-json"]

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

def until(proc, kind):
    frames = []
    while True:
        frames.append(recv(proc))
        if frames[-1]["type"] == kind:
            return frames

def control(proc, request_id, request):
    send(proc, {"type": "control_request", "request_id": request_id,
                "request": request})
    frame = recv(proc)
    assert frame["response"]["request_id"] == request_id, frame
    return frame["response"]

def prompt(proc, text, **extra):
    send(proc, {"type": "user", "session_id": "", "parent_tool_use_id": None,
                "message": {"role": "user", "content": text}, **extra})
    return until(proc, "result")

def finish(proc, status):
    proc.stdin.close()
    proc.wait(timeout=10 * scale)
    err = proc.stderr.read().decode()
    assert proc.returncode == status, (proc.returncode, err)
    return err

schema = {"type": "object", "properties": {"answer": {"type": "integer"}},
          "required": ["answer"]}
proc = start(["--include-partial-messages", "--json-schema",
              json.dumps(schema)])
frames = prompt(proc, "answer", origin={"kind": "human"})
sid = frames[0]["session_id"]
events = [f["event"]["type"] for f in frames if f["type"] == "stream_event"]
assert events == ["message_start", "content_block_start",
                  "content_block_delta", "content_block_stop",
                  "message_delta", "message_stop"], events
delta = next(f["event"]["delta"] for f in frames
             if f["type"] == "stream_event" and
             f["event"]["type"] == "content_block_delta")
assert delta == {"type": "text_delta", "text": "Thinking about it."}, delta
uses = [b["name"] for f in frames if f["type"] == "assistant"
        for b in f["message"]["content"] if b["type"] == "tool_use"]
assert uses == ["StructuredOutput", "StructuredOutput"], uses
result = frames[-1]
assert result["subtype"] == "success", result
assert result["terminal_reason"] == "completed", result
assert result["structured_output"] == {"answer": 42}, result
assert result["origin"] == {"kind": "human"}, result
usage = control(proc, "req_ctx", {"subtype": "get_context_usage"})
assert usage["response"]["totalTokens"] == 24, usage
finish(proc, 0)

proc = start(["--resume=" + sid, "--fork-session"])
frames = prompt(proc, "fork it")
fork = frames[0]["session_id"]
assert fork != sid and frames[-1]["result"] == "forked", frames
assert "origin" not in frames[-1], frames[-1]
finish(proc, 0)

proc = start(["--continue"])
frames = prompt(proc, "go on")
assert frames[0]["session_id"] == fork, frames[0]
assert frames[-1]["result"] == "continued", frames[-1]
finish(proc, 0)

proc = start(["--max-turns", "1"])
result = prompt(proc, "loop")[-1]
assert result["subtype"] == "error_max_turns" and result["is_error"], result
assert result["terminal_reason"] == "max_turns", result
finish(proc, 1)

proc = start(["--max-budget-usd", "0.4"])
result = prompt(proc, "spend")[-1]
assert result["subtype"] == "error_max_budget_usd", result
assert result["total_cost_usd"] == 0.5, result
finish(proc, 1)

proc = start(["--json-schema", json.dumps(schema)])
frames = prompt(proc, "seven")
assert frames[-1]["structured_output"] == {"answer": 7}, frames[-1]
finish(proc, 0)

proc = start()
reply = control(proc, "req_a", {"subtype": "initialize", "hooks": None,
    "agents": {"reviewer": {"description": "Reviews code",
                            "prompt": "You review code.", "model": "haiku"}}})
assert reply["subtype"] == "success", reply
reply = control(proc, "req_b", {"subtype": "initialize", "hooks": None})
assert reply["subtype"] == "error", reply
frames = prompt(proc, "agents")
assert frames[0]["agents"] == ["reviewer"], frames[0]
assert frames[-1]["result"] == "Agents ready.", frames[-1]
finish(proc, 0)


# A failed provider request ends a loop that completed, as Claude Code says.
proc = start()
result = prompt(proc, "broken")[-1]
assert result["subtype"] == "success" and result["is_error"], result
assert result["terminal_reason"] == "api_error", result
assert result["api_error_status"] == 404, result
assert result["errors"] == [], result
assert "mock: no such model" in result["result"], result
finish(proc, 1)

# A sub-agent asks the gate of the session, and its steps belong to the call.
proc = start(["--allowedTools", "Task"])
reply = control(proc, "req_g", {"subtype": "initialize", "hooks": None,
    "forwardSubagentText": True,
    "agents": {"greeter": {"description": "Greets", "prompt": "Greet."}}})
assert reply["subtype"] == "success", reply
frames = prompt(proc, "delegate")
sub = [(f["type"], [b["type"] for b in f["message"]["content"]])
       for f in frames if f.get("parent_tool_use_id") == "call_agent"]
assert sub == [("assistant", ["tool_use"]), ("user", ["tool_result"]),
               ("assistant", ["text"])], sub
result = frames[-1]
assert result["result"] == "DONE", result
assert result["permission_denials"] == [{
    "tool_name": "Bash", "tool_use_id": "call_sub",
    "tool_input": {"command": "echo sub > s.txt"}}], result
assert not os.path.exists(os.path.join(cwd, "s.txt"))
finish(proc, 0)

# /clear starts a new session, which keeps nothing of the old one.
proc = start(["--append-system-prompt", "Be brief."])
old = prompt(proc, "one")[-1]["session_id"]
frames = prompt(proc, "/clear")
reset = frames[0]
assert reset["type"] == "conversation_reset", reset
assert reset["session_id"] == old and reset["uuid"], reset
assert frames[-1]["session_id"] == reset["new_conversation_id"] != old, frames
frames = prompt(proc, "two")
assert frames[0]["session_id"] == reset["new_conversation_id"], frames[0]
assert frames[-1]["result"] == "second answer", frames[-1]
finish(proc, 0)

# A prompt carries the file that it names as @PATH, unless the SDK composed it.
secret = os.path.join(cwd, "outside", "secret.txt")
os.makedirs(os.path.dirname(secret))
with open(secret, "w") as f:
    f.write("MARKER-42\n")
proc = start()
assert prompt(proc, "Look at @%s." % secret)[-1]["result"] == "seen"
frames = prompt(proc, "Look at @%s." % secret, client_composed=True)
assert frames[-1]["result"] == "not seen", frames[-1]
finish(proc, 0)

# An agent that names its tools gets only those.
proc = start(["--allowedTools", "Task"])
reply = control(proc, "req_t", {"subtype": "initialize", "hooks": None,
    "agents": {"reader": {"description": "Reads", "prompt": "Read.",
                          "tools": ["Read"]}}})
assert reply["subtype"] == "success", reply
assert prompt(proc, "read")[-1]["result"] == "DONE2"
finish(proc, 0)

proc = start(["--max-budget-usd", "-1"])
err = finish(proc, 1)
assert "--max-budget-usd must be positive" in err, err
PYEOF

mock_stop 21
assert_request 7 'r["body"]["messages"][-1]["content"].startswith("Give the answer now")'
assert_request 8 '"reviewer" in json.dumps(r["body"]["tools"])'
assert_request 1 'r["body"]["messages"][-1]["content"].startswith("the output does not match")'
assert_request 2 'r["body"]["messages"][-1]["content"] == "fork it"'
assert_request 2 'any(m.get("content") == "The structured output was accepted." for m in r["body"]["messages"])'
assert_request 3 'any(m.get("content") == "forked" for m in r["body"]["messages"])'
assert_request 12 'r["body"]["messages"][-1]["content"] == "permission to use Bash was not granted"'
assert_request 15 '[m["role"] for m in r["body"]["messages"]] == ["system", "user"]'
assert_request 15 'r["body"]["messages"][0]["content"].endswith("\n\nBe brief.")'
assert_request 15 'r["body"]["messages"][1]["content"] == "two"'
assert_request 16 '"Called the Read tool with the following input" in r["body"]["messages"][-1]["content"]'
assert_request 16 '"MARKER-42" in r["body"]["messages"][-1]["content"]'
assert_request 17 '"MARKER-42" not in r["body"]["messages"][-1]["content"]'
assert_request 19 '[t["function"]["name"] for t in r["body"]["tools"]] == ["read_file"]'
pass
