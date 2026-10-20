#!/bin/bash
# SPDX-License-Identifier: MIT
# An image travels in the export: the directive of the message holds its bytes
# as !!binary, so an import into an unrelated arena restores the image part
# after the source file and the arena it was attached in are gone, and the
# next request sends the original bytes.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
mock_start image_wire.json

# A PNG header and a payload that is mostly bytes that are not UTF-8, so the
# export writes base64 and not escapes.
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x04\x00\x00\x00\x03\x00\x08\x06\x00\x00\x00' \
    >"$TEST_DIR/shot.png"
"$PYTHON" -c 'import sys; sys.stdout.buffer.write(bytes((i * 151 + 7) % 128 + 128 for i in range(4096)))' \
    >>"$TEST_DIR/shot.png"
expected="$("$PYTHON" -c 'import base64, sys; print(base64.b64encode(open(sys.argv[1], "rb").read()).decode())' "$TEST_DIR/shot.png")"

write_catalog() {
	cat > catalog.yaml <<EOF
models:
- name: img-resp
  modalities: [text, image]
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
EOF
	run_fyai catalog import catalog.yaml
	assert_status 0
}

write_catalog
run_fyai --set display/stream=false --set tools=false \
	 -m resp-prov/img-resp --image "$TEST_DIR/shot.png" "what is this?"
assert_status 0
mock_stop 1

run_fyai export -o "$TEST_DIR/first.md"
assert_status 0
grep -q '!!binary' "$TEST_DIR/first.md" || fail "the export holds no image bytes"
grep -q 'fyai-media:' "$TEST_DIR/first.md" || fail "the export prose names no image"

# Nothing of the source is left: not the file, and not the arena.
rm -f "$TEST_DIR/shot.png"
rm -rf "$TEST_DIR/.fyai" "$TEST_DIR/home"
export HOME="$TEST_DIR/home2"
mkdir -p "$HOME" "$TEST_DIR/second"
cd "$TEST_DIR/second"
run_fyai init
assert_status 0

run_fyai import -i "$TEST_DIR/first.md"
assert_status 0

# The image comes back the same, so a second export writes the same message.
run_fyai export -o again.md
assert_status 0
image_directive() {
	awk '/^<!-- meta:yaml$/ { inblk = 1; blk = ""; next }
	     inblk && $0 == "-->" { inblk = 0
				     if (blk ~ /!!binary/) printf "%s", blk
				     next }
	     inblk { blk = blk $0 "\n" }' "$1"
}
image_directive "$TEST_DIR/first.md" > expected.txt
image_directive again.md > actual.txt
[ -s expected.txt ] || fail "no image directive in the first export"
diff -u expected.txt actual.txt || fail "the image did not round-trip"

# The next request carries the bytes that were attached in the first arena.
mock_start image_wire.json
write_catalog
run_fyai --set display/stream=false --set tools=false \
	 -m resp-prov/img-resp "and now?"
assert_status 0
assert_stdout_contains "Saw the image under Responses."
assert_request 0 "any(p.get('type') == 'input_image' and p.get('image_url') == 'data:image/png;base64,$expected' for m in r['body']['input'] if isinstance(m.get('content'), list) for p in m['content'] if isinstance(p, dict))"
mock_stop 1

pass
