#!/bin/bash
# SPDX-License-Identifier: MIT
# A sandbox profile can give the tools a home of their own. A tree is mounted over
# the real home in the namespace of the tool: $HOME and the paths under it are
# unchanged, but the tool sees only the private versions that `copy` and `env`
# name, and the paths that the sandbox grants. A denied file is not in it, the
# originals never change, and a host that cannot mount stops the tool.
set -eu
[ "$(uname -s)" = Linux ] || exit 77
. "$(dirname "$0")/../harness.sh"

FYAI_TMPDIR_BASE="$(dirname "$FYAI_BIN")"
fyai_test_setup
REAL="$HOME"

mkdir -p "$HOME/.ssh" "$HOME/.config/tool" "$HOME/conf" "$HOME/tools" "$HOME/other"
printf 'secret\n' >"$HOME/.ssh/id_test"
printf 'rc-data\n' >"$HOME/.testrc"
printf 'tool-data\n' >"$HOME/.config/tool/settings"
printf 'conf-data\n' >"$HOME/conf/main"
printf 'granted-data\n' >"$HOME/tools/granted"
printf 'other-data\n' >"$HOME/other/data"
printf 'machine example login me password hunter2\n' >"$HOME/.netrc"
printf '[user]\n\tname = Tester\n' >"$HOME/.gitconfig"

# shell_with YAML COMMAND: run a command in the shell tool under a profile.
shell_with() {
	printf '%s\n' "$1" >"$TEST_DIR/home.yaml"
	run_fyai --config "$TEST_DIR/home.yaml" tool shell '{"command": "'"$2"'"}'
}

profile() {
	cat <<YAML
sandbox_profile: home
sandbox_profiles:
  home:
    extends: dev
    allow:
      - { path: ~/tools, mode: ro }
    home:
      private: true
      method: $1
      copy: [~/.testrc, ~/.config/tool, ~/.ssh/id_test]
      env: ["MYCONF=~/conf"]
YAML
}

# A host that cannot make a namespace stops the tool, and says why. The tool is
# the probe: `unshare` can fail where the cover of the tool still works.
shell_with "$(profile overlay)" 'echo marker-7391' || true
if ! grep -qF marker-7391 "$TEST_DIR/stdout"; then
	assert_stdout_not_contains marker-7391
	pass
	exit 0
fi

for method in copy overlay; do
	shell_with "$(profile $method)" \
		'echo home=$HOME; ls -A $HOME; cat ~/.testrc; cat ~/.config/tool/settings; cat ~/tools/granted; ls ~/.ssh 2>&1 || echo no-ssh; cat ~/conf/main; echo new > ~/conf/main; echo more > ~/conf/added; echo w > ~/written; echo written-ok'
	assert_stdout_contains "home=$REAL"
	assert_stdout_contains 'rc-data'
	assert_stdout_contains 'tool-data'
	assert_stdout_contains 'granted-data'
	assert_stdout_contains 'conf-data'
	assert_stdout_contains 'written-ok'
	# The real home is hidden: only the private tree is there.
	assert_stdout_not_contains 'other'
	assert_stdout_not_contains 'secret'
	# What the tool wrote stays in the private tree.
	[ "$(cat "$REAL/conf/main")" = conf-data ] || fail "$method changed the original"
	[ ! -e "$REAL/conf/added" ] || fail "$method added a file to the original"
	[ ! -e "$REAL/written" ] || fail "$method wrote the real home"
	! ls "${TMPDIR:-/tmp}"/fyai-home-* >/dev/null 2>&1 || fail "$method left a home directory"
done

# The yocto profile of the sample: the tool can make a user namespace, git finds its
# configuration, and ~/.netrc is not there, so a program that reads it gets "not found"
# and not "permission denied".
printf 'sandbox_profile: yocto\n' >"$TEST_DIR/home.yaml"
run_fyai --config "$TEST_DIR/home.yaml" tool shell '{"command": "unshare -Ur sh -c \"echo nested-ok\" 2>&1; cat ~/.gitconfig; cat ~/.netrc 2>&1"}'
assert_stdout_contains nested-ok
assert_stdout_contains Tester
assert_stdout_contains 'No such file'
assert_stdout_not_contains 'Permission denied'
assert_stdout_not_contains hunter2

# A host that cannot mount stops the tool: there is no fallback.
printf '%s\n' "$(profile overlay)" >"$TEST_DIR/home.yaml"
run_fyai --config "$TEST_DIR/home.yaml" --set sandbox_cover=none tool shell '{"command": "echo marker-5528"}' || true
assert_stdout_not_contains marker-5528
# --set is stored: name the cover again.
run_fyai --set sandbox_cover=auto config get sandbox_cover >/dev/null

# The project under the home stays visible and writable, with its arena hidden.
mkdir -p "$HOME/proj"
printf 'project-data\n' >"$HOME/proj/file"
(cd "$HOME/proj" && "$FYAI_BIN" init >/dev/null 2>&1)
(cd "$HOME/proj" && shell_with "$(profile overlay)" 'cat file; echo made > made; cat made; ls -A $HOME')
assert_stdout_contains project-data
assert_stdout_contains made
assert_stdout_not_contains 'other'
[ -f "$HOME/proj/made" ] || fail 'the tool did not write the project'

# A run of the model, with a mount of the profile after the home.
mkdir -p "$TEST_DIR/extra"
printf 'extra-data\n' >"$TEST_DIR/extra/file"
{
	profile overlay
	cat <<YAML
    mounts:
      - { kind: bind, source: "$TEST_DIR/extra", target: "$TEST_DIR/extra", mode: ro }
YAML
} >"$TEST_DIR/home.yaml"
mock_start sandbox_home.json
run_fyai --config "$TEST_DIR/home.yaml" --set api=chat-completions --set display/stream=false \
	 --set tools=true --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model \
	 --set sandbox_scope=exchange --set sandbox_cover=auto --new "go"
assert_status 0
mock_stop 2
"$PYTHON" - "$TEST_DIR/requests.jsonl" "$REAL" <<'PYEOF' || fail "the tool did not see its home"
import json
import sys

last = json.loads(open(sys.argv[1]).read().splitlines()[-1])["body"]
out = "".join(m["content"] for m in last["messages"] if m.get("role") == "tool")
assert "home=" + sys.argv[2] in out, out
assert "rc-data" in out and "new" in out and "done" in out, out
assert "other-data" not in out, out
assert any(l.strip().isdigit() and int(l) > 0 for l in out.splitlines()), out
PYEOF
[ "$(cat "$REAL/conf/main")" = conf-data ] || fail 'the overlay changed the original'
[ ! -e "$REAL/conf/added" ] || fail 'the overlay added a file to the original'
! ls "${TMPDIR:-/tmp}"/fyai-home-* >/dev/null 2>&1 || fail 'a home directory is left behind after the run'
pass
