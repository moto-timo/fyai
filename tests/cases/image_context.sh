#!/bin/bash
# SPDX-License-Identifier: MIT
# An attachment counts as its reference, not as its pixels. The estimate of a
# conversation that carries a 1024x768 image must exceed the same conversation
# without it by the few hundred bytes of the digest and its metadata - never by
# w*h/750 tokens, which is what a renderer would need, not what the model sees.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start image_context.json

printf '\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x04\x00\x00\x00\x03\x00\x08\x06\x00\x00\x00' \
    >"$TEST_DIR/shot.png"

cat > catalog.yaml <<EOF
models:
- name: img-model
  modalities: [text, image]
  capabilities: []
providers:
- name: img-prov
  root_url: $MOCK_URL
  endpoints:
  - protocol: responses
    endpoint: /v1/responses
  models:
  - canonical_id: img-model
    provider_model_id: img-model
EOF
run_fyai catalog import catalog.yaml
assert_status 0

# estimated_tokens: read "~N tokens ..." from `fyai context --output json`.
estimated_tokens() {
	run_fyai context --output json
	assert_status 0
	"$PYTHON" - "$TEST_DIR/stdout" <<'EOF'
import json, re, sys
doc = json.load(open(sys.argv[1]))
m = re.match(r"~(\d+) tokens", doc["prompt_estimated"])
if not m:
    raise SystemExit("no estimate: %r" % (doc["prompt_estimated"],))
print(m.group(1))
EOF
}

run_fyai --set display/stream=false --set tools=false -m img-prov/img-model \
	 "describe the same thing"
assert_status 0
plain="$(estimated_tokens)"

# The same prompt, with the image attached, on a fresh branch.
run_fyai --new --set display/stream=false --set tools=false -m img-prov/img-model \
	 --image "$TEST_DIR/shot.png" "describe the same thing"
assert_status 0
with_image="$(estimated_tokens)"

[ "$with_image" -gt "$plain" ] || \
	fail "the reference did not count: $plain -> $with_image"
delta=$((with_image - plain))
# 1024x768 at the usual w*h/750 would be about 1048 tokens. The reference is
# a digest and a few numbers: well under a hundred bytes of tokens.
[ "$delta" -lt 300 ] || \
	fail "the estimate counted the pixels, not the reference: +$delta tokens"

mock_stop 2
pass
