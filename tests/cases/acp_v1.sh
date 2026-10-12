#!/bin/bash
# SPDX-License-Identifier: MIT
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start chat_basic.json

"$PYTHON" - "$FYAI_BIN" "$TEST_DIR" "$MOCK_URL" <<'PYEOF' || fail "ACP v1 session lifecycle"
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
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)

def send(proc, ident, method, params):
    proc.stdin.write((json.dumps({"jsonrpc": "2.0", "id": ident,
                                  "method": method, "params": params}) + "\n").encode())
    proc.stdin.flush()

def recv(proc):
    deadline = time.monotonic() + 20
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
    send(proc, 1, "initialize", {"protocolVersion": 1, "clientCapabilities": {}})
    init = recv(proc)["result"]
    assert init["protocolVersion"] == 1
    assert init["agentCapabilities"]["loadSession"] is True
    assert "list" in init["agentCapabilities"]["sessionCapabilities"]
    send(proc, 2, "session/new", {"cwd": cwd, "mcpServers": []})
    sid = recv(proc)["result"]["sessionId"]
    send(proc, 3, "session/prompt", {"sessionId": sid,
                                    "prompt": [{"type": "text", "text": "hello v1"}]})
    frames = []
    while True:
        frame = recv(proc)
        frames.append(frame)
        if frame.get("id") == 3:
            break
    assert frames[-1]["result"]["stopReason"] == "end_turn"
    updates = [f["params"]["update"] for f in frames if f.get("method") == "session/update"]
    assert any(u.get("sessionUpdate") == "user_message_chunk" for u in updates)
    assert any(u.get("sessionUpdate") == "agent_message_chunk" and
               "Hello from the mock provider." in u.get("content", {}).get("text", "") for u in updates)
    assert not any(u.get("sessionUpdate") == "state_update" for u in updates)
    send(proc, 4, "session/list", {"cwd": cwd})
    assert any(s["sessionId"] == sid for s in recv(proc)["result"]["sessions"])
finally:
    proc.stdin.close()
    proc.wait(timeout=10)
    assert proc.returncode == 0, proc.stderr.read().decode()

proc = start()
try:
    send(proc, 1, "initialize", {"protocolVersion": 1})
    assert recv(proc)["result"]["protocolVersion"] == 1
    send(proc, 2, "session/load", {"sessionId": sid, "cwd": cwd, "mcpServers": []})
    frames = []
    while True:
        frame = recv(proc)
        frames.append(frame)
        if frame.get("id") == 2:
            break
    assert "result" in frames[-1]
    updates = [f["params"]["update"] for f in frames if f.get("method") == "session/update"]
    assert any(u.get("sessionUpdate") == "user_message_chunk" for u in updates)
    assert any(u.get("sessionUpdate") == "agent_message_chunk" for u in updates)
finally:
    proc.stdin.close()
    proc.wait(timeout=10)
    assert proc.returncode == 0, proc.stderr.read().decode()
PYEOF

mock_stop 1
pass
