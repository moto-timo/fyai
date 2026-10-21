#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Build the desktop app: the built page, the bridge, and a static fyai when
# one is bundled, in dist-app/.
#
#   scripts/package.sh                 # dist-app/fyai-linux-x64/fyai
#   scripts/package.sh --bundle-fyai   # build the static fyai first
#   scripts/package.sh --arch arm64
#
# Without a bundled fyai the app uses FYAI_BIN, the project build beside the
# page, or fyai on PATH, so a development machine needs nothing here.
set -eu

cd "$(dirname "$0")/.."

ARCH="x64"
BUNDLE=0

usage() {
	cat <<'EOF'
Build the fyai desktop app.

  scripts/package.sh                 dist-app/fyai-linux-x64/fyai
  scripts/package.sh --bundle-fyai   build the static fyai first
  scripts/package.sh --arch arm64    another architecture

Options: --arch ARCH, --bundle-fyai, -h.
EOF
	exit "${1:-0}"
}

while [ $# -gt 0 ]; do
	case "$1" in
	--arch)
		if [ $# -lt 2 ] || [ -z "$2" ]; then
			echo "package.sh: --arch needs an architecture" >&2
			exit 1
		fi
		ARCH="$2"
		shift 2
		;;
	--bundle-fyai) BUNDLE=1; shift ;;
	-h | --help) usage 0 ;;
	*) echo "package.sh: unknown option '$1'" >&2; usage 1 >&2 ;;
	esac
done

if [ ! -d node_modules ]; then
	echo "package.sh: installing the page's dependencies"
	npm ci
fi

echo "package.sh: building the page"
npm run build

EXTRA=()

if [ "$BUNDLE" = 1 ]; then
	bash scripts/bundle-fyai.sh
fi

if [ -x fyai-bundle/fyai ]; then
	EXTRA=(--extra-resource=fyai-bundle/fyai)
	echo "package.sh: bundling fyai-bundle/fyai"
else
	echo "package.sh: no fyai-bundle/fyai; the app finds fyai on the machine"
fi

rm -rf "dist-app/fyai-linux-$ARCH"

npx @electron/packager . fyai \
	--platform=linux \
	--arch="$ARCH" \
	--electron-version="$(node -p "require('electron/package.json').version")" \
	--out=dist-app \
	--overwrite \
	--prune=true \
	--ignore="^/(dist-app|fyai-bundle|node_modules|src|static|scripts|tests)(/|$)" \
	"${EXTRA[@]+"${EXTRA[@]}"}"

APP="dist-app/fyai-linux-$ARCH"
chmod 755 "$APP/fyai"

echo "package.sh: $APP/fyai"
if [ -x "$APP/resources/fyai" ]; then
	echo "package.sh: bundled fyai $(du -h "$APP/resources/fyai" | cut -f1)"
	file "$APP/resources/fyai" | sed 's/^/package.sh: /'
fi
