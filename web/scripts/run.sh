#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Serve the fyai web UI: build the page if needed, then start the bridge that
# runs fyai and serves the page on one port.
#
#   scripts/run.sh                     # http://127.0.0.1:9331
#   scripts/run.sh --cwd ~/project     # another project for fyai
#   scripts/run.sh --fyai ~/bin/fyai   # another fyai program
#   scripts/run.sh --port 8080 --open  # another port, and a browser
#   scripts/run.sh --build             # build the page again first
#
# The bridge is the only process that starts fyai. It listens on loopback and
# runs tools without asking, so do not expose it to a network.
set -eu

START_DIR="$PWD"
cd "$(dirname "$0")/.."

PORT="${FYAI_BRIDGE_PORT:-9331}"
HOST="${FYAI_BRIDGE_HOST:-127.0.0.1}"
FYAI="${FYAI_BIN:-}"
CWD_ARGS=()
PASS=()
BUILD=0
OPEN=0

usage() {
	cat <<'EOF'
Serve the fyai web UI from the built page.

  scripts/run.sh                     http://127.0.0.1:9331
  scripts/run.sh --cwd ~/project     another project for fyai
  scripts/run.sh --fyai ~/bin/fyai   another fyai program
  scripts/run.sh --port 8080 --open  another port, and a browser
  scripts/run.sh --build             build the page again first
  scripts/run.sh -- --model gpt-5.5  further bridge options

Options: --fyai PATH, --cwd DIR, --port N, --host H, --build, --open, -h.
Environment: FYAI_BIN, FYAI_BRIDGE_PORT, FYAI_BRIDGE_HOST.

fyai comes from --fyai, else $FYAI_BIN, else ../build/fyai, else PATH.
EOF
	exit "${1:-0}"
}

while [ $# -gt 0 ]; do
	case "$1" in
	--fyai | --fyai-bin)
		if [ $# -lt 2 ] || [ -z "$2" ]; then
			echo "run.sh: --fyai needs the path of an fyai program" >&2
			exit 1
		fi
		FYAI="$2"
		shift 2
		;;
	--port) PORT="$2"; shift 2 ;;
	--host) HOST="$2"; shift 2 ;;
	--cwd) CWD_ARGS=(--cwd "$2"); shift 2 ;;
	--build) BUILD=1; shift ;;
	--open) OPEN=1; shift ;;
	--) shift; PASS=("$@"); break ;;
	-h | --help) usage 0 ;;
	*) echo "run.sh: unknown option '$1'" >&2; usage 1 >&2 ;;
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
	echo "run.sh: fyai not found at '${FYAI:-fyai}'; give --fyai PATH" >&2
	exit 1
fi

FYAI="$(readlink -f "$FYAI" 2>/dev/null || echo "$FYAI")"

if ! command -v node >/dev/null 2>&1; then
	echo "run.sh: node is required (20 or later)" >&2
	exit 1
fi

if [ ! -d node_modules ]; then
	echo "run.sh: installing the page's dependencies"
	npm ci
fi

if [ "$BUILD" = 1 ] || [ ! -f dist/index.html ]; then
	echo "run.sh: building the page"
	npm run build
fi

# An earlier bridge holds the port: say so rather than fail on the bind.
if curl -sf "http://$HOST:$PORT/api/fyai/info" >/dev/null 2>&1; then
	echo "run.sh: a bridge already answers on http://$HOST:$PORT" >&2
	exit 1
fi

# Every API request needs this token. The link carries it once; the browser
# keeps it as a cookie.
FYAI_BRIDGE_TOKEN="${FYAI_BRIDGE_TOKEN:-$(node -e "process.stdout.write(require('node:crypto').randomBytes(32).toString('hex'))")}"
export FYAI_BRIDGE_TOKEN

URL="http://$HOST:$PORT"
LOGIN_URL="$URL/api/fyai/login?token=$FYAI_BRIDGE_TOKEN"

if [ "$OPEN" = 1 ]; then
	(
		for _ in $(seq 100); do
			curl -sf "$URL/api/fyai/info" >/dev/null 2>&1 && break
			sleep 0.1
		done
		if command -v xdg-open >/dev/null 2>&1; then
			xdg-open "$LOGIN_URL" >/dev/null 2>&1 || true
		elif command -v open >/dev/null 2>&1; then
			open "$LOGIN_URL" >/dev/null 2>&1 || true
		fi
	) &
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

echo "run.sh: fyai $("$FYAI" --version 2>/dev/null | head -1)"
echo "run.sh: fyai path $FYAI"
echo "run.sh: project ${CWD_ARGS[1]}"

if [ ! -d "${CWD_ARGS[1]}/.fyai/arena" ]; then
	echo "run.sh: no fyai project at ${CWD_ARGS[1]}; run 'fyai init' there" >&2
fi

echo "run.sh: $URL   (Ctrl-C stops it)"

exec node server/bridge.mjs \
	--bin "$FYAI" \
	--host "$HOST" \
	--port "$PORT" \
	"${CWD_ARGS[@]+"${CWD_ARGS[@]}"}" \
	"${PASS[@]+"${PASS[@]}"}"
