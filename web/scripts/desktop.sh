#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Open the web page as a desktop window. The bridge runs inside the app, so
# nothing else has to be started; fyai itself is the only program it needs.
#
#   scripts/desktop.sh                       # the repo build, or fyai on PATH
#   scripts/desktop.sh --fyai ~/bin/fyai     # another fyai program
#   scripts/desktop.sh --cwd ~/project       # another project for fyai
#
# The window loads the built page; run `npm run build` after a change of the
# page. Electron is a development dependency: it needs Node 20 or later and a
# graphical session.
set -eu

START_DIR="$PWD"
cd "$(dirname "$0")/.."

FYAI="${FYAI_BIN:-}"
CWD_DIR=""

usage() {
	cat <<'EOF'
Open the fyai web UI in a desktop window.

  scripts/desktop.sh                     the repo build, else fyai on PATH
  scripts/desktop.sh --fyai PATH         another fyai program
  scripts/desktop.sh --cwd DIR           another project for fyai

Options: --fyai PATH, --cwd DIR, -h. Environment: FYAI_BIN, FYAI_BRIDGE_PORT.
EOF
	exit "${1:-0}"
}

while [ $# -gt 0 ]; do
	case "$1" in
	--fyai | --fyai-bin)
		if [ $# -lt 2 ] || [ -z "$2" ]; then
			echo "desktop.sh: --fyai needs the path of an fyai program" >&2
			exit 1
		fi
		FYAI="$2"
		shift 2
		;;
	--cwd)
		if [ $# -lt 2 ] || [ -z "$2" ]; then
			echo "desktop.sh: --cwd needs a directory" >&2
			exit 1
		fi
		CWD_DIR="$2"
		shift 2
		;;
	-h | --help) usage 0 ;;
	*) echo "desktop.sh: unknown option '$1'" >&2; usage 1 >&2 ;;
	esac
done

if [ -n "$FYAI" ]; then
	case "$FYAI" in
	/*) ;;
	*) FYAI="$START_DIR/$FYAI" ;;
	esac
fi
if [ -z "$FYAI" ] && [ -x ../build/fyai ]; then
	FYAI="$(cd .. && pwd)/build/fyai"
fi
if [ -z "$FYAI" ]; then
	FYAI="$(command -v fyai || true)"
fi
if [ -z "$FYAI" ] || [ ! -x "$FYAI" ]; then
	echo "desktop.sh: fyai not found at '${FYAI:-fyai}'; give --fyai PATH" >&2
	exit 1
fi
FYAI="$(readlink -f "$FYAI" 2>/dev/null || echo "$FYAI")"

if [ -z "$CWD_DIR" ]; then
	if [ -f ../CMakeLists.txt ] && [ -d ../src ]; then
		CWD_DIR="$(cd .. && pwd)"
	else
		CWD_DIR="$START_DIR"
	fi
fi

if [ ! -d node_modules ]; then
	echo "desktop.sh: installing the page's dependencies"
	npm ci
fi

# Electron ships as a download that the install script fetches; a tree that
# was installed with scripts disabled has the package but not the program.
if [ ! -x node_modules/electron/dist/electron ]; then
	echo "desktop.sh: fetching the Electron program"
	node node_modules/electron/install.js
fi

if [ ! -f dist/index.html ]; then
	echo "desktop.sh: building the page"
	npm run build
fi

echo "desktop.sh: fyai $("$FYAI" --version 2>/dev/null | head -1)"
echo "desktop.sh: fyai path $FYAI"
echo "desktop.sh: project $CWD_DIR"

if [ ! -d "$CWD_DIR/.fyai/arena" ]; then
	echo "desktop.sh: no fyai project at $CWD_DIR; run 'fyai init' there" >&2
fi

export FYAI_BIN="$FYAI"
export FYAI_BRIDGE_CWD="$CWD_DIR"

exec node_modules/.bin/electron .
