#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Build the desktop app: the built page, the bridge, and a static fyai when
# one is bundled, in dist-app/.
#
#   scripts/package.sh                 # dist-app/fyai-<os>-<arch>/
#   scripts/package.sh --bundle-fyai   # build the fyai it carries first
#   scripts/package.sh --arch arm64
#   scripts/package.sh --skip-build    # the page in dist/ is up to date
#   scripts/package.sh --no-fyai       # carry no fyai, even if one is built
#
# The platform is the one the script runs on, or --platform. Without a
# bundled fyai the app uses FYAI_BIN, the project build beside the page, or
# fyai on PATH, so a development machine needs nothing here.
set -eu

cd "$(dirname "$0")/.."

ARCH="x64"
PLATFORM=""
BUNDLE=0
SKIP_BUILD=0
NO_FYAI=0

case "$(uname -s)" in
Darwin) PLATFORM="darwin"; ARCH="$(uname -m | sed 's/x86_64/x64/')" ;;
Linux) PLATFORM="linux"; ARCH="$(uname -m | sed 's/x86_64/x64/; s/aarch64/arm64/')" ;;
esac

usage() {
	cat <<'EOF'
Build the fyai desktop app.

  scripts/package.sh                   dist-app/fyai-<os>-<arch>/
  scripts/package.sh --bundle-fyai     build the fyai it carries first
  scripts/package.sh --arch arm64      another architecture
  scripts/package.sh --skip-build      the page in dist/ is up to date
  scripts/package.sh --no-fyai         carry no fyai, even if one is built

Options: --arch ARCH, --platform linux|darwin, --bundle-fyai, --no-fyai, --skip-build, -h.
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
	--platform)
		if [ $# -lt 2 ] || [ -z "$2" ]; then
			echo "package.sh: --platform needs linux or darwin" >&2
			exit 1
		fi
		PLATFORM="$2"
		shift 2
		;;
	--bundle-fyai) BUNDLE=1; shift ;;
	--skip-build) SKIP_BUILD=1; shift ;;
	--no-fyai) NO_FYAI=1; shift ;;
	-h | --help) usage 0 ;;
	*) echo "package.sh: unknown option '$1'" >&2; usage 1 >&2 ;;
	esac
done

if [ ! -d node_modules ]; then
	echo "package.sh: installing the page's dependencies"
	npm ci
fi

if [ "$SKIP_BUILD" = 1 ] && [ -f dist/index.html ]; then
	echo "package.sh: using the page in dist/"
else
	echo "package.sh: building the page"
	npm run build
fi

EXTRA=()

if [ "$BUNDLE" = 1 ]; then
	bash scripts/bundle-fyai.sh
fi

if [ "$NO_FYAI" = 0 ] && [ -x fyai-bundle/fyai ]; then
	EXTRA=(--extra-resource=fyai-bundle/fyai)
	echo "package.sh: bundling fyai-bundle/fyai"
else
	echo "package.sh: no fyai-bundle/fyai; the app finds fyai on the machine"
fi

rm -rf "dist-app/fyai-$PLATFORM-$ARCH"

npx @electron/packager . fyai \
	--platform="$PLATFORM" \
	--arch="$ARCH" \
	--electron-version="$(node -p "require('electron/package.json').version")" \
	--out=dist-app \
	--overwrite \
	--prune=true \
	--ignore="^/(dist-app|fyai-bundle|node_modules|src|static|scripts|tests)(/|$)" \
	"${EXTRA[@]+"${EXTRA[@]}"}"

APP="dist-app/fyai-$PLATFORM-$ARCH"

if [ "$PLATFORM" = darwin ]; then
	APP="$APP/fyai.app"

	# The packager renames Electron and edits its Info.plist, which breaks the
	# signature of the bundle. macOS then reports a downloaded app as damaged,
	# not as unverified. Sign it again, ad hoc, so that it verifies and the
	# user can open it from the Gatekeeper prompt.
	if command -v codesign >/dev/null 2>&1; then
		codesign --force --deep --sign - "$APP"
		codesign --verify --deep --strict "$APP"
		echo "package.sh: signed $APP ad hoc"
	else
		echo "package.sh: no codesign; the app is not signed" >&2
	fi
fi
if [ "$PLATFORM" = linux ]; then
	chmod 755 "$APP/fyai"
fi

echo "package.sh: $APP"
if [ -x "$APP/resources/fyai" ]; then
	echo "package.sh: bundled fyai $(du -h "$APP/resources/fyai" | cut -f1)"
	file "$APP/resources/fyai" | sed 's/^/package.sh: /'
fi
