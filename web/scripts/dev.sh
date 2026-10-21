#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Develop the page: the bridge runs fyai, and Vite serves the page and
# forwards /api, /v1, /props and /slots to it. Edit a file and the page
# reloads; the bridge keeps running.
#
#   scripts/dev.sh                     # page on http://127.0.0.1:5173
#   scripts/dev.sh --cwd ~/project     # another project for fyai
#   scripts/dev.sh --fyai ~/bin/fyai   # another fyai program
#   scripts/dev.sh --bridge-port 9440  # another bridge port
#
# Ctrl-C stops both. The built page is for scripts/run.sh; this script needs
# no build.
set -eu

START_DIR="$PWD"
cd "$(dirname "$0")/.."

BRIDGE_PORT="${FYAI_BRIDGE_PORT:-9331}"
BRIDGE_HOST="${FYAI_BRIDGE_HOST:-127.0.0.1}"
DEV_PORT="${FYAI_DEV_PORT:-5173}"
FYAI="${FYAI_BIN:-}"
CWD_ARGS=()
PASS=()

usage() {
	cat <<'EOF'
Run the page in development: Vite in front of the fyai bridge.

  scripts/dev.sh                       page on http://127.0.0.1:5173
  scripts/dev.sh --cwd ~/project       another project for fyai
  scripts/dev.sh --fyai ~/bin/fyai     another fyai program
  scripts/dev.sh --bridge-port 9440    another bridge port

Options: --fyai PATH, --cwd DIR, --bridge-port N, --bridge-host H,
         --dev-port N, -h.
Environment: FYAI_BIN, FYAI_BRIDGE_PORT, FYAI_BRIDGE_HOST, FYAI_DEV_PORT.

fyai comes from --fyai, else $FYAI_BIN, else ../build/fyai, else PATH.
EOF
	exit "${1:-0}"
}

while [ $# -gt 0 ]; do
	case "$1" in
	--fyai | --fyai-bin)
		if [ $# -lt 2 ] || [ -z "$2" ]; then
			echo "dev.sh: --fyai needs the path of an fyai program" >&2
			exit 1
		fi
		FYAI="$2"
		shift 2
		;;
	--cwd) CWD_ARGS=(--cwd "$2"); shift 2 ;;
	--bridge-port) BRIDGE_PORT="$2"; shift 2 ;;
	--bridge-host) BRIDGE_HOST="$2"; shift 2 ;;
	--dev-port) DEV_PORT="$2"; shift 2 ;;
	--) shift; PASS=("$@"); break ;;
	-h | --help) usage 0 ;;
	*) echo "dev.sh: unknown option '$1'" >&2; usage 1 >&2 ;;
	esac
done

# A path that was given is relative to where the script was started.
if [ -n "$FYAI" ]; then
	case "$FYAI" in
	/*) ;;
	*) FYAI="$START_DIR/$FYAI" ;;
	esac
fi

# fyai: the one asked for, else the one in the project above, else PATH.
if [ -z "$FYAI" ] && [ -x ../build/fyai ]; then
	FYAI="$(cd .. && pwd)/build/fyai"
fi
if [ -z "$FYAI" ]; then
	FYAI="$(command -v fyai || true)"
fi
if [ -z "$FYAI" ] || [ ! -x "$FYAI" ]; then
	echo "dev.sh: fyai not found at '${FYAI:-fyai}'; give --fyai PATH" >&2
	exit 1
fi

FYAI="$(readlink -f "$FYAI" 2>/dev/null || echo "$FYAI")"

if [ ! -d node_modules ]; then
	echo "dev.sh: installing the page's dependencies"
	npm ci
fi

# fyai works in the fyai project above this directory; a copy of the page
# elsewhere works in the directory the script was started from.
if [ ${#CWD_ARGS[@]} -eq 0 ]; then
	if [ -f ../CMakeLists.txt ] && [ -d ../src ]; then
		CWD_ARGS=(--cwd "$(cd .. && pwd)")
	else
		CWD_ARGS=(--cwd "$START_DIR")
	fi
fi

# The page forwards to the bridge through Vite's proxy.
export VITE_PUBLIC_BRIDGE_ORIGIN="http://$BRIDGE_HOST:$BRIDGE_PORT"

node server/bridge.mjs \
	--bin "$FYAI" \
	--host "$BRIDGE_HOST" \
	--port "$BRIDGE_PORT" \
	"${CWD_ARGS[@]+"${CWD_ARGS[@]}"}" \
	"${PASS[@]+"${PASS[@]}"}" &
BRIDGE_PID=$!

cleanup() {
	kill "$BRIDGE_PID" 2>/dev/null || true
	wait "$BRIDGE_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# A bridge that could not start must stop the script, not leave a dev server
# that answers a proxy with nothing behind it.
sleep 0.5
if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
	echo "dev.sh: the bridge did not start" >&2
	exit 1
fi

echo "dev.sh: page http://127.0.0.1:$DEV_PORT   bridge http://$BRIDGE_HOST:$BRIDGE_PORT"
echo "dev.sh: fyai $("$FYAI" --version 2>/dev/null | head -1)"
echo "dev.sh: fyai path $FYAI"
echo "dev.sh: project ${CWD_ARGS[1]}"

if [ ! -d "${CWD_ARGS[1]}/.fyai/arena" ]; then
	echo "dev.sh: no fyai project at ${CWD_ARGS[1]}; run 'fyai init' there" >&2
fi

npx vite dev --host 127.0.0.1 --port "$DEV_PORT" --strictPort
