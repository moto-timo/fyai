#!/bin/bash
# SPDX-License-Identifier: MIT
# The user card shows an attachment as the Markdown row that names it: the alt
# text describes the image, and the digest in the link is the one hook a later
# renderer resolves. The model is sent the native part, never this string.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start responses_basic.json

printf '\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x04\x00\x00\x00\x03\x00\x08\x06\x00\x00\x00' \
    >"$TEST_DIR/shot.png"

cat > catalog.yaml <<EOF
models:
- name: card-model
  modalities: [text, image]
  capabilities: []
providers:
- name: card-prov
  root_url: $MOCK_URL
  endpoints:
  - protocol: responses
    endpoint: /v1/responses
  models:
  - canonical_id: card-model
    provider_model_id: card-model
EOF
run_fyai catalog import catalog.yaml
assert_status 0

export OPENAI_API_KEY=test-key
pty_run "$TEST_DIR/pty.out" \
    "$FYAI_BIN" -k test-key --theme dark \
    --set display/markdown=true --set display/stream=false \
    --set tools=false -m card-prov/card-model -i <<'PTY'
rows: 40
cols: 140
timeout: 30
wait_timeout: 15
steps:
  - type: "/image add shot.png"
  - wait-screen: attached
  - type: "what is this?"
  - wait-screen: "image: PNG 1024x768"
  - wait: Hello from the mock responses provider.
    timeout: session
  - type: "/exit"
PTY

# The row is the alt text and the digest; the model got the native part.
assert_request 0 'any(p.get("type") == "input_text" and p.get("text") == "what is this?" for p in r["body"]["input"][-1]["content"] if isinstance(p, dict))'
assert_request 0 'any(p.get("type") == "input_image" for p in r["body"]["input"][-1]["content"] if isinstance(p, dict))'
assert_no_request 'any("fyai-media:" in str(p.get("text", "")) for m in r["body"].get("input", []) if isinstance(m, dict) and isinstance(m.get("content"), list) for p in m["content"] if isinstance(p, dict))'

# The session is its own branch; export the one the status line names.
branch="$("$PYTHON" - "$TEST_DIR/pty.out" <<'EOF'
import re, sys
data = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
m = re.search(r"session/\d{8}T\d{6}\.\d+", data)
if not m:
    raise SystemExit("no session branch in the capture")
print(m.group(0))
EOF
)" || fail "could not read the session branch"

# The exported document keeps the words and names the image by digest.
run_fyai export "$branch"
assert_status 0
assert_stdout_contains "what is this?"
assert_stdout_contains "![image: PNG 1024x768, 29 B](fyai-media:"

mock_stop 1
pass
