#!/bin/bash
# SPDX-License-Identifier: MIT
# The control requests of the Claude Agent SDK protocol: rules, hooks and
# can_use_tool decide on tool calls, an MCP server of the SDK runs through
# mcp_message, and Stop and UserPromptSubmit hooks shape the turn.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start claude_sdk_control.json

export MOCK_KEY=test-key
"$FYAI_BIN" --set api=chat-completions --set display/stream=false \
	--set "api_url=$MOCK_URL/v1/chat/completions" --set model=mock-model \
	--set 'api_key={type: env, value: MOCK_KEY}' >/dev/null 2>&1 ||
	fail "configure the project"

"$PYTHON" - "$FYAI_BIN" "$TEST_DIR" "$FYAI_TIMEOUT_SCALE" <<'PYEOF' || fail "Claude SDK control"
import json
import os
import select
import subprocess
import sys
import time

binary, cwd, scale = sys.argv[1], sys.argv[2], int(sys.argv[3])
mcp = json.dumps({"mcpServers": {"calc": {"type": "sdk", "name": "calc"}}})
proc = subprocess.Popen([binary, "--output-format", "stream-json",
                         "--verbose", "--input-format", "stream-json",
                         "--permission-prompt-tool", "stdio",
                         "--allowedTools", "mcp__calc__add",
                         "--disallowedTools", "Bash(echo one:*)",
                         "--mcp-config", mcp], cwd=cwd,
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE, bufsize=0)
log = []

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

def reply(request_id, response):
    send({"type": "control_response",
          "response": {"subtype": "success", "request_id": request_id,
                       "response": response}})

def mcp_reply(message):
    method = message.get("method")
    if method == "initialize":
        result = {"protocolVersion": message["params"]["protocolVersion"],
                  "capabilities": {"tools": {}},
                  "serverInfo": {"name": "calc", "version": "1"}}
    elif method == "tools/list":
        result = {"tools": [{"name": "add", "description": "Add numbers",
                             "inputSchema": {"type": "object",
                                             "properties": {
                                                 "a": {"type": "number"},
                                                 "b": {"type": "number"}}}}]}
    elif method == "tools/call":
        args = message["params"]["arguments"]
        result = {"content": [{"type": "text",
                               "text": str(args["a"] + args["b"])}]}
    elif "id" not in message:
        return {"jsonrpc": "2.0", "result": {}}
    else:
        return {"jsonrpc": "2.0", "id": message["id"],
                "error": {"code": -32601, "message": "no method " + method}}
    return {"jsonrpc": "2.0", "id": message["id"], "result": result}

hook_outputs = {
    "hook_prompt": lambda i: {"hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit", "additionalContext": "prompt-ctx"}},
    "hook_pre": lambda i: {},
    "hook_post": lambda i: {"hookSpecificOutput": {
        "hookEventName": "PostToolUse", "additionalContext": "after-bash"}},
    "hook_stop": lambda i: {} if i["stop_hook_active"] else
        {"decision": "block", "reason": "keep going"},
}

def serve(frame):
    """Answer a control request of fyai; return True when it was one."""
    if frame["type"] != "control_request":
        return False
    request = frame["request"]
    kind = request["subtype"]
    if kind == "can_use_tool":
        log.append(("can_use_tool", request["tool_name"], request["input"]))
        reply(frame["request_id"], {"behavior": "allow", "updatedInput": {
            "command": "echo changed > b.txt"}})
    elif kind == "hook_callback":
        log.append(("hook", request["callback_id"], request["input"]))
        reply(frame["request_id"],
              hook_outputs[request["callback_id"]](request["input"]))
    elif kind == "mcp_message":
        log.append(("mcp", request["message"].get("method")))
        reply(frame["request_id"],
              {"mcp_response": mcp_reply(request["message"])})
    else:
        raise AssertionError("unexpected request: " + json.dumps(frame))
    return True

def until(kind, request_id=None):
    frames = []
    while True:
        frame = recv()
        if serve(frame):
            continue
        frames.append(frame)
        if frame["type"] == kind and (request_id is None or
                frame["response"]["request_id"] == request_id):
            return frames

send({"type": "control_request", "request_id": "req_init", "request": {
    "subtype": "initialize", "hooks": {
        "UserPromptSubmit": [{"matcher": None,
                              "hookCallbackIds": ["hook_prompt"]}],
        "PreToolUse": [{"matcher": "Bash", "hookCallbackIds": ["hook_pre"]}],
        "PostToolUse": [{"matcher": "Bash", "hookCallbackIds": ["hook_post"]}],
        "Stop": [{"matcher": None, "hookCallbackIds": ["hook_stop"]}]}}})
reply_frame = until("control_response", "req_init")[-1]
assert reply_frame["response"]["subtype"] == "success", reply_frame

send({"type": "control_request", "request_id": "req_mode", "request": {
    "subtype": "set_permission_mode", "mode": "plan"}})
assert until("control_response", "req_mode")[-1]["response"]["subtype"] == "error"
send({"type": "control_request", "request_id": "req_mcp", "request": {
    "subtype": "mcp_status"}})
status = until("control_response", "req_mcp")[-1]["response"]["response"]
assert status["mcpServers"] == [{"name": "calc", "status": "connected"}], status
# No model returns to the model that the session started with.
for request_id, model in (("req_other", "other-model"), ("req_none", None)):
    send({"type": "control_request", "request_id": request_id, "request": {
        "subtype": "set_model", "model": model}})
    reply_frame = until("control_response", request_id)[-1]
    assert reply_frame["response"]["subtype"] == "success", reply_frame

send({"type": "user", "session_id": "", "parent_tool_use_id": None,
      "message": {"role": "user", "content": "go"}})
frames = until("result")
init = frames[0]
assert init["subtype"] == "init", init
assert "Bash" in init["tools"] and "mcp__calc__add" in init["tools"], init
uses = [(b["name"], b["input"]) for f in frames if f["type"] == "assistant"
        for b in f["message"]["content"] if b["type"] == "tool_use"]
assert uses == [("Bash", {"command": "echo one > a.txt"}),
                ("Bash", {"command": "echo two > b.txt"}),
                ("mcp__calc__add", {"a": 2, "b": 3})], uses
result = frames[-1]
assert result["subtype"] == "success" and result["result"] == "second done", result
assert result["permission_denials"] == [{
    "tool_name": "Bash", "tool_use_id": "call_one",
    "tool_input": {"command": "echo one > a.txt"}}], result

asked = [e for e in log if e[0] == "can_use_tool"]
assert asked == [("can_use_tool", "Bash", {"command": "echo two > b.txt"})], log
hooks = [(e[1], e[2].get("tool_name"), e[2].get("stop_hook_active"))
         for e in log if e[0] == "hook"]
assert hooks == [("hook_prompt", None, None), ("hook_pre", "Bash", None),
                 ("hook_post", "Bash", None), ("hook_stop", None, False),
                 ("hook_stop", None, True)], hooks
prompt = next(e[2] for e in log if e[0] == "hook" and e[1] == "hook_prompt")
assert prompt["prompt"] == "go" and prompt["hook_event_name"] == "UserPromptSubmit", prompt
post = next(e[2] for e in log if e[0] == "hook" and e[1] == "hook_post")
assert post["tool_input"] == {"command": "echo changed > b.txt"}, post
assert ("mcp", "tools/call") in log, log

assert not os.path.exists(os.path.join(cwd, "a.txt"))
assert open(os.path.join(cwd, "b.txt")).read() == "changed\n"
proc.stdin.close()
proc.wait(timeout=10 * scale)
assert proc.returncode == 0, proc.stderr.read().decode()

# With no can_use_tool, a call that needs permission does not run.
proc = subprocess.Popen([binary, "--output-format", "stream-json",
                         "--verbose", "--input-format", "stream-json"],
                        cwd=cwd, stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        bufsize=0)
send({"type": "user", "session_id": "", "parent_tool_use_id": None,
      "message": {"role": "user", "content": "unasked"}})
result = until("result")[-1]
assert result["result"] == "nobody asked", result
assert result["permission_denials"] == [{
    "tool_name": "Bash", "tool_use_id": "call_three",
    "tool_input": {"command": "echo three > c.txt"}}], result
assert not os.path.exists(os.path.join(cwd, "c.txt"))
proc.stdin.close()
proc.wait(timeout=10 * scale)
assert proc.returncode == 0, proc.stderr.read().decode()
PYEOF

mock_stop 7
assert_request 0 'r["body"]["model"] == "mock-model"'
assert_request 0 'r["body"]["messages"][-1]["content"] == "go\n\nprompt-ctx"'
assert_request 1 'r["body"]["messages"][-1]["content"] == "permission to use Bash is denied"'
assert_request 2 'r["body"]["messages"][-1]["content"] == "after-bash"'
assert_request 3 'r["body"]["messages"][-1]["content"] == "5"'
assert_request 4 'r["body"]["messages"][-1]["content"] == "keep going"'
assert_request 6 'r["body"]["messages"][-1]["content"] == "permission to use Bash was not granted"'
pass
