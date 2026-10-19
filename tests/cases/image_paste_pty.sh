#!/bin/bash
# SPDX-License-Identifier: MIT
# `/image paste` in a live session, through a clipboard helper found on PATH.
# No escape can read a clipboard, so fyai runs the program the desktop
# provides; here that is a stand-in `pngpaste` that writes the fixture to its
# standard output, exactly as the real one does.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup

# Leave only the helper this case provides: with no Wayland or X display the
# search skips wl-paste, xclip and xsel, and reaches pngpaste. It is looked up
# by name, thus the copy in the sandbox comes first on PATH.
unset WAYLAND_DISPLAY DISPLAY || true
mkdir -p "$TEST_DIR/bin"
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x04\x00\x00\x00\x03\x00\x08\x06\x00\x00\x00' \
    >"$TEST_DIR/shot.png"
cat >"$TEST_DIR/bin/pngpaste" <<EOF
#!/bin/sh
cat "$TEST_DIR/shot.png"
EOF
chmod +x "$TEST_DIR/bin/pngpaste"
export PATH="$TEST_DIR/bin:$PATH"

pty_run "$TEST_DIR/pty.out" \
    "$FYAI_BIN" -k test-key --theme dark -i <<'PTY'
rows: 30
cols: 120
timeout: 25
wait_timeout: 15
steps:
  - type: "/image paste"
  - wait-screen: attached
  - wait-screen: 1024x768
  - wait-screen: clipboard
  - type: "/image list"
  - wait-screen: Attachments
  - wait-screen: clipboard
  - type: "/image clear"
  - wait-screen: dropped 1 attachment
  - type: "/exit"
PTY

# A helper that writes nothing is named, and its cause says what it did, so a
# user can tell an empty clipboard from a missing program.
cat >"$TEST_DIR/bin/pngpaste" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TEST_DIR/bin/pngpaste"

pty_run "$TEST_DIR/pty-empty.out" \
    "$FYAI_BIN" -k test-key --theme dark -i <<'PTY'
rows: 30
cols: 120
timeout: 25
wait_timeout: 15
steps:
  - type: "/image paste"
  - wait-screen: could not read an image from the clipboard
  - wait-screen: pngpaste wrote nothing
  - type: "/exit"
PTY

# Desktop connection variables reach the helper; credentials do not.
export WAYLAND_DISPLAY=fyai-test-wayland DISPLAY=:987
export XDG_RUNTIME_DIR="$TEST_DIR/runtime"
export XAUTHORITY="$TEST_DIR/Xauthority"
export FYAI_CLIPBOARD_SECRET=private
cat >"$TEST_DIR/bin/wl-paste" <<EOF
#!/bin/sh
[ "\${WAYLAND_DISPLAY:-}" = fyai-test-wayland ] || exit 1
[ "\${DISPLAY:-}" = :987 ] || exit 1
[ "\${XDG_RUNTIME_DIR:-}" = "$TEST_DIR/runtime" ] || exit 1
[ "\${XAUTHORITY:-}" = "$TEST_DIR/Xauthority" ] || exit 1
[ -z "\${FYAI_CLIPBOARD_SECRET+x}" ] || exit 1
cat "$TEST_DIR/shot.png"
EOF
chmod +x "$TEST_DIR/bin/wl-paste"
run_fyai image paste --output json
assert_status 0
assert_stdout_contains 'image/png'

pass
