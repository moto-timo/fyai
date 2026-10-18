#!/bin/bash
# SPDX-License-Identifier: MIT
# The prebuilt images of the embedded documents are the same at each build:
# an image holds the arena at address zero and nothing of the process. Also, a
# run with FYAI_NO_IMAGE parses the text and gives the same answer as a run
# with the image.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup
MKIMAGE="$(dirname "$FYAI_BIN")/fyai_mkimage"
[ -x "$MKIMAGE" ] || skip "no fyai_mkimage in this build"
DATA="$(cd "$TESTS_DIR/.." && pwd)/data"

for doc in commands catalog; do
	"$MKIMAGE" "$DATA/$doc.yaml" "$TEST_DIR/$doc.1.inc" IMAGE 2> "$TEST_DIR/note.1" ||
		fail "fyai_mkimage failed on $doc"
	"$MKIMAGE" "$DATA/$doc.yaml" "$TEST_DIR/$doc.2.inc" IMAGE 2> "$TEST_DIR/note.2" ||
		fail "fyai_mkimage failed on $doc"
	cmp -s "$TEST_DIR/$doc.1.inc" "$TEST_DIR/$doc.2.inc" ||
		fail "the image of $doc differs between two builds"
done

# The image and the text give the same registry and the same output.
run_fyai branch list --output json
assert_status 0
cp "$TEST_DIR/stdout" "$TEST_DIR/with-image"
FYAI_NO_IMAGE=1 run_fyai branch list --output json
assert_status 0
cmp -s "$TEST_DIR/stdout" "$TEST_DIR/with-image" ||
	fail "the output depends on the image"
run_fyai api
assert_status 0
cp "$TEST_DIR/stdout" "$TEST_DIR/with-image"
FYAI_NO_IMAGE=1 run_fyai api
assert_status 0
cmp -s "$TEST_DIR/stdout" "$TEST_DIR/with-image" ||
	fail "the model state depends on the image"

pass
