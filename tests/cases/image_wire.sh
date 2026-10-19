#!/bin/bash
# SPDX-License-Identifier: MIT
# One image, three grammars, end to end through the mock provider: the image a
# user attached arrives in the shape each API carries, and a conversation that
# gained the image under one API replays it correctly under the next.
#
# The image part is derived at the request boundary, so this is the end-to-end
# counterpart of the provider/image_input unit test: the canonical message
# holds the bytes, and only the request body holds base64.
#
# Model modalities determine image support without endpoint capability flags.
# A model without the image modality rejects the message before a request.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start image_wire.json

# A PNG header is all fyai needs: it sniffs the type from the magic bytes
# and reads the size from the header, never from the pixels.
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x04\x00\x00\x00\x03\x00\x08\x06\x00\x00\x00' \
    >"$TEST_DIR/shot.png"

cat > catalog.yaml <<EOF
models:
- name: img-resp
  modalities: [text, image]
  capabilities: []
- name: img-chat
  modalities: [text, image]
  capabilities: []
- name: img-msg
  modalities: [text, image]
  capabilities: []
- name: text-only
  modalities: [text]
  capabilities: []
providers:
- name: resp-prov
  root_url: $MOCK_URL
  endpoints:
  - protocol: responses
    endpoint: /v1/responses
  models:
  - canonical_id: img-resp
    provider_model_id: img-resp
- name: chat-prov
  root_url: $MOCK_URL
  endpoints:
  - protocol: chat_completions
    endpoint: /v1/chat/completions
  models:
  - canonical_id: img-chat
    provider_model_id: img-chat
- name: msg-prov
  root_url: $MOCK_URL
  endpoints:
  - protocol: messages
    endpoint: /v1/messages
  models:
  - canonical_id: img-msg
    provider_model_id: img-msg
- name: text-prov
  root_url: $MOCK_URL
  endpoints:
  - protocol: responses
    endpoint: /v1/responses
  models:
  - canonical_id: text-only
    provider_model_id: text-only
EOF
run_fyai catalog import catalog.yaml
assert_status 0

# Responses: an input_text part and an input_image part of a data URL.
run_fyai --set display/stream=false --set tools=false \
	 -m resp-prov/img-resp --image "$TEST_DIR/shot.png" "what is this?"
assert_status 0
assert_stdout_contains "Saw the image under Responses."

assert_request 0 'r["path"] == "/v1/responses"'
assert_request 0 'r["body"]["model"] == "img-resp"'
assert_request 0 'isinstance(r["body"]["input"][-1]["content"], list)'
assert_request 0 'any(p.get("type") == "input_text" and p.get("text") == "what is this?" for p in r["body"]["input"][-1]["content"] if isinstance(p, dict))'
assert_request 0 'any(p.get("type") == "input_image" and p.get("image_url", "").startswith("data:image/png;base64,iVBORw0KGgo") for p in r["body"]["input"][-1]["content"] if isinstance(p, dict))'

# Chat Completions: the stored message replays as image_url + text.
run_fyai --set display/stream=false --set tools=false \
	 -m chat-prov/img-chat "and now?"
assert_status 0
assert_stdout_contains "Saw the image under Chat Completions."

assert_request 1 'r["path"] == "/v1/chat/completions"'
assert_request 1 'any(m.get("role") == "user" and isinstance(m.get("content"), list) and any(p.get("type") == "image_url" and p.get("image_url", {}).get("url", "").startswith("data:image/png;base64,iVBORw0KGgo") for p in m["content"] if isinstance(p, dict)) for m in r["body"]["messages"])'
assert_request 1 'any(m.get("role") == "user" and isinstance(m.get("content"), list) and any(p.get("type") == "text" and p.get("text") == "what is this?" for p in m["content"] if isinstance(p, dict)) for m in r["body"]["messages"])'
# A message with no image keeps the scalar content it always had.
assert_request 1 'any(m.get("role") == "user" and m.get("content") == "and now?" for m in r["body"]["messages"])'

# Messages: both user messages replay as image + text blocks, with the source
# carrying the media type and the base64 bytes.
run_fyai --set display/stream=false --set tools=false \
	 -m msg-prov/img-msg "and under Messages?"
assert_status 0
assert_stdout_contains "Saw the image under Messages."

assert_request 2 'r["path"] == "/v1/messages"'
assert_request 2 'any(m.get("role") == "user" and isinstance(m.get("content"), list) and any(b.get("type") == "image" and b.get("source", {}).get("type") == "base64" and b.get("source", {}).get("media_type") == "image/png" and b["source"].get("data", "").startswith("iVBORw0KGgo") for b in m["content"] if isinstance(b, dict)) for m in r["body"]["messages"])'
assert_request 2 'any(m.get("role") == "user" and isinstance(m.get("content"), list) and any(b.get("type") == "text" and b.get("text") == "what is this?" for b in m["content"] if isinstance(b, dict)) for m in r["body"]["messages"])'
assert_request 2 'any(m.get("role") == "user" and isinstance(m.get("content"), list) and any(b.get("type") == "text" and b.get("text") == "and under Messages?" for b in m["content"] if isinstance(b, dict)) for m in r["body"]["messages"])'

# This model has no image modality: the message
# is refused with a cause, and nothing is sent.
run_fyai --new --set display/stream=false --set tools=false \
	 -m text-prov/text-only --image "$TEST_DIR/shot.png" "look at this"
assert_status_nonzero
assert_stderr_contains "takes no image input"

mock_stop 3
pass
