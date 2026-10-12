#!/bin/bash
# SPDX-License-Identifier: MIT
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start chat_basic_twice.json

"$PYTHON" - "$FYAI_BIN" "$TEST_DIR" "$MOCK_URL" <<'PYEOF' || fail "ACP v2 session lifecycle"
import json
import os
import select
import subprocess
import sys
import time

binary, cwd, url = sys.argv[1:]
cmd = [binary, "-k", "test-key", "--set", "api=chat-completions",
       "--set", "display/stream=false", "--set", "api_url=" + url + "/v1/chat/completions",
       "-m", "mock-model", "acp"]

def start():
    return subprocess.Popen(cmd, cwd=cwd, stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            bufsize=0)

def send(proc, ident, method, params):
    proc.stdin.write((json.dumps({"jsonrpc": "2.0", "id": ident,
                                  "method": method, "params": params}) + "\n").encode())
    proc.stdin.flush()

def recv(proc, timeout=20):
    deadline = time.monotonic() + timeout
    data = bytearray()
    while time.monotonic() < deadline:
        if not select.select([proc.stdout], [], [], max(0, deadline - time.monotonic()))[0]:
            break
        ch = os.read(proc.stdout.fileno(), 1)
        if not ch:
            raise AssertionError("ACP process closed: " + proc.stderr.read().decode())
        if ch == b"\n":
            return json.loads(data)
        data.extend(ch)
    raise AssertionError("timed out waiting for ACP frame: " + repr(data))

proc = start()
try:
    send(proc, "init", "initialize", {"protocolVersion": 2, "clientCapabilities": {}})
    assert recv(proc)["result"]["protocolVersion"] == 2
    send(proc, 1, "session/new", {"cwd": cwd, "mcpServers": []})
    sid = recv(proc)["result"]["sessionId"]
    assert sid.startswith("acp/")
    send(proc, 2, "session/list", {"cwd": cwd})
    assert any(s["sessionId"] == sid for s in recv(proc)["result"]["sessions"])
    send(proc, 20, "session/new", {"cwd": cwd, "mcpServers": [{"name": "client"}]})
    assert recv(proc)["error"]["code"] == -32602
    send(proc, 21, "session/new", {"cwd": cwd, "mcpServers": []})
    second = recv(proc)["result"]["sessionId"]
    send(proc, 3, "session/prompt", {"sessionId": sid,
                                    "prompt": [{"type": "text", "text": "hello ACP"}]})
    send(proc, 22, "session/prompt", {"sessionId": second,
                                     "prompt": [{"type": "text", "text": "hello again"}]})
    frames = []
    idle = set()
    while True:
        frame = recv(proc)
        frames.append(frame)
        if frame.get("method") == "session/update" and frame["params"]["update"].get("state") == "idle":
            idle.add(frame["params"]["sessionId"])
        if idle == {sid, second}:
            break
    ack = next(f for f in frames if f.get("id") == 3)
    assert ack["result"]["messageId"].startswith("msg_")
    updates = [f["params"]["update"] for f in frames if f.get("method") == "session/update"]
    assert any(u.get("sessionUpdate") == "user_message" for u in updates)
    assert any(u.get("sessionUpdate") == "agent_message_chunk" and
               "mock provider." in u.get("content", {}).get("text", "") for u in updates)
    assert all(u["stopReason"] == "end_turn" for u in updates if u.get("state") == "idle")
    assert next(f for f in frames if f.get("id") == 22)["result"]["messageId"]
    send(proc, 4, "session/close", {"sessionId": sid})
    assert recv(proc)["id"] == 4
finally:
    proc.stdin.close()
    proc.wait(timeout=10)
    assert proc.returncode == 0, proc.stderr.read().decode()

proc = start()
try:
    send(proc, 1, "initialize", {"protocolVersion": 2})
    assert recv(proc)["result"]["protocolVersion"] == 2
    send(proc, 2, "session/resume", {"sessionId": sid, "cwd": cwd,
                                     "mcpServers": [], "replayFrom": {"type": "start"}})
    frames = []
    while True:
        frame = recv(proc)
        frames.append(frame)
        if frame.get("id") == 2:
            break
    assert "result" in frames[-1]
    updates = [f["params"]["update"] for f in frames if f.get("method") == "session/update"]
    assert any(u.get("sessionUpdate") == "user_message" and
               u.get("messageId") == ack["result"]["messageId"] for u in updates)
    assert any(u.get("sessionUpdate") == "agent_message_chunk" and
               "mock provider." in u.get("content", {}).get("text", "") for u in updates)
finally:
    proc.stdin.close()
    proc.wait(timeout=10)
    assert proc.returncode == 0, proc.stderr.read().decode()
PYEOF

mock_stop 2
assert_request 0 'all("acp_message_id" not in m and "acp_content" not in m for m in r["body"]["messages"])'
assert_request 1 'all("acp_message_id" not in m and "acp_content" not in m for m in r["body"]["messages"])'
pass
