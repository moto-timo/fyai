#!/bin/bash
# SPDX-License-Identifier: MIT
# Fetch the pinned Claude Agent SDK for Python and run its end-to-end suite
# with fyai as the CLI. The suite calls a real model and costs money.
#
#   FYAI_SDK_MODEL     the model of every session (anthropic/claude-haiku-5.5)
#   FYAI_SDK_KEY_ENV   the variable that holds its key (ANTHROPIC_API_KEY)
#   FYAI_SDK_PYTEST    more pytest arguments, such as "-k hooks"
set -eu

FYAI_BIN="$(realpath "${1:?pass the fyai binary}")"
BUILD_DIR="$(realpath "${2:?pass the build directory}")"
SDK_REV="b6e9d12fe1cc98dde988ab7b7713c1feeee50c6c"
SDK_DIR="$BUILD_DIR/_deps/claude-agent-sdk-python"
VENV="$BUILD_DIR/_deps/claude-agent-sdk-venv"
RUN_DIR="$BUILD_DIR/claude-sdk-e2e"
MODEL="${FYAI_SDK_MODEL:-anthropic/claude-haiku-5.5}"
KEY_ENV="${FYAI_SDK_KEY_ENV:-ANTHROPIC_API_KEY}"

command -v git >/dev/null || { echo "git is required" >&2; exit 2; }
command -v uv >/dev/null || { echo "uv is required" >&2; exit 2; }
[ -n "${!KEY_ENV:-}" ] || { echo "set $KEY_ENV to the key of $MODEL" >&2; exit 2; }
# The suite checks for this variable whatever the model is.
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-unused}"

if [ ! -d "$SDK_DIR/.git" ]; then
	mkdir -p "$(dirname "$SDK_DIR")"
	git clone --depth 1 \
		https://github.com/anthropics/claude-agent-sdk-python.git "$SDK_DIR"
fi
if [ "$(git -C "$SDK_DIR" rev-parse HEAD)" != "$SDK_REV" ]; then
	git -C "$SDK_DIR" fetch --depth 1 origin "$SDK_REV"
	git -C "$SDK_DIR" checkout --detach "$SDK_REV"
fi
if [ ! -x "$VENV/bin/python" ]; then
	uv venv --quiet "$VENV"
fi
VIRTUAL_ENV="$VENV" uv pip install --quiet -e "$SDK_DIR[dev]"

# A private home, and a project that each test directory is inside. A source
# install of the SDK has no CLI of its own: it runs the claude on PATH.
mkdir -p "$RUN_DIR/home" "$RUN_DIR/bin" "$RUN_DIR/work"
export HOME="$RUN_DIR/home"
export XDG_STATE_HOME="$RUN_DIR/home/.local/state"
export XDG_CONFIG_HOME="$RUN_DIR/home/.config"
export FYAI_AUTH_STORAGE=file
cat > "$RUN_DIR/bin/claude" <<EOF
#!/bin/bash
# A session that names a Claude model runs on the model of the project
# instead. Another name goes through, so a test can name one that fails.
claude_model() {
	case "\$1" in
	haiku|sonnet|opus|claude-haiku-*|claude-sonnet-*|claude-opus-*) return 0 ;;
	esac
	return 1
}
args=()
while [ \$# -gt 0 ]; do
	case "\$1" in
	--model|--fallback-model)
		if [ \$# -gt 1 ] && claude_model "\$2"; then
			shift 2
			continue
		fi ;;
	--model=*|--fallback-model=*)
		if claude_model "\${1#*=}"; then
			shift
			continue
		fi ;;
	esac
	args+=("\$1")
	shift
done
exec "$FYAI_BIN" "\${args[@]}"
EOF
chmod +x "$RUN_DIR/bin/claude"
cd "$RUN_DIR/work"
printf 'model: %s\napi_key: {type: env, value: %s}\ndisplay:\n  markdown: false\n' \
	"$MODEL" "$KEY_ENV" > config.yaml
"$FYAI_BIN" init --force >/dev/null
rm -f config.yaml
# A test that runs in another directory, such as /tmp, uses the same arena.
mkdir -p "$XDG_CONFIG_HOME/fyai"
printf 'arena_dir: %s/.fyai/arena\n' "$RUN_DIR/work" > "$XDG_CONFIG_HOME/fyai/config.yaml"

echo "Claude Agent SDK e2e suite ($SDK_REV) on $MODEL"
# Tests that run in "." look at the files of the SDK, as its CI does.
cd "$SDK_DIR"
status=0
# shellcheck disable=SC2086
PATH="$RUN_DIR/bin:$PATH" "$VENV/bin/python" -m pytest "$SDK_DIR/e2e-tests" \
	-p no:cacheprovider -o addopts="" -rfEs \
	--basetemp="$RUN_DIR/work/pytest" \
	--junitxml="$BUILD_DIR/claude-sdk-e2e.xml" \
	${FYAI_SDK_PYTEST:-} || status=$?
exit "$status"
