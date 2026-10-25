#!/bin/bash
# SPDX-License-Identifier: MIT
# An image block of an SDK user message: the bytes are attached to that message
# as an image part, so the request carries it, a message of an image alone is
# a prompt, and an image that cannot be attached stops the turn with a cause.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start claude_sdk_image.json

cat > catalog.yaml <<CAT
models:
- name: img-chat
  modalities: [text, image]
  capabilities: []
providers:
- name: chat-prov
  root_url: $MOCK_URL
  endpoints:
  - protocol: chat_completions
    endpoint: /v1/chat/completions
  models:
  - canonical_id: img-chat
    provider_model_id: img-chat
CAT
run_fyai catalog import catalog.yaml
assert_status 0

export MOCK_KEY=test-key
"$FYAI_BIN" --set api=chat-completions --set display/stream=false \
	--set "api_url=$MOCK_URL/v1/chat/completions" --set model=chat-prov/img-chat \
	--set 'api_key={type: env, value: MOCK_KEY}' >/dev/null 2>&1 ||
	fail "configure the project"

"$PYTHON" - "$FYAI_BIN" "$TEST_DIR" "$FYAI_TIMEOUT_SCALE" <<'PYEOF' || fail "SDK image blocks"
import base64
import json
import os
import select
import subprocess
import sys
import time

binary, cwd, scale = sys.argv[1], sys.argv[2], int(sys.argv[3])
# A PNG header is all fyai needs: it sniffs the type and reads the size from it.
png = (b"\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x04\x00\x00\x00\x03\x00"
       b"\x08\x06\x00\x00\x00")
b64 = base64.b64encode(png).decode()

def start():
    return subprocess.Popen(
        [binary, "--output-format", "stream-json", "--verbose",
         "--system-prompt", "", "--input-format", "stream-json"],
        cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, bufsize=0)

def send(proc, content):
    frame = {"type": "user", "session_id": "", "parent_tool_use_id": None,
             "message": {"role": "user", "content": content}}
    proc.stdin.write((json.dumps(frame) + "\n").encode())
    proc.stdin.flush()

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

def until_result(proc):
    while True:
        frame = recv(proc)
        if frame["type"] == "result":
            return frame

def image(data=b64, media="image/png"):
    return {"type": "image", "source": {"type": "base64",
                                        "media_type": media, "data": data}}

proc = start()
send(proc, [{"type": "text", "text": "what is this?"}, image()])
result = until_result(proc)
assert result["is_error"] is False and result["result"] == "Saw the image.", result

send(proc, [image()])
result = until_result(proc)
assert result["is_error"] is False, result
assert result["result"] == "Saw only the image.", result

# Bytes that are no image stop the turn, and the cause says which part.
send(proc, [{"type": "text", "text": "and this?"},
            image(base64.b64encode(b"not an image at all").decode())])
result = until_result(proc)
assert result["is_error"] is True, result
assert "image" in result["result"], result
proc.stdin.close()
proc.wait(timeout=10 * scale)
PYEOF

# The first request: the text and the image of one message, in the shape of the API.
assert_request 0 'any(m.get("role") == "user" and isinstance(m.get("content"), list) and any(p.get("type") == "text" and p.get("text") == "what is this?" for p in m["content"] if isinstance(p, dict)) and any(p.get("type") == "image_url" and p["image_url"]["url"].startswith("data:image/png;base64,iVBORw0KGgo") for p in m["content"] if isinstance(p, dict)) for m in r["body"]["messages"])'
# The second: an image alone. The image of the first message does not leave
# with it a second time, so the earlier message keeps its own.
assert_request 1 'sum(1 for m in r["body"]["messages"] if m.get("role") == "user" and isinstance(m.get("content"), list)) == 2'
assert_request 1 'r["body"]["messages"][-1]["content"] == [{"type": "image_url", "image_url": {"url": r["body"]["messages"][-1]["content"][0]["image_url"]["url"]}}]'

mock_stop 2
pass
