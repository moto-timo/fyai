#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Put a standalone fyai beside the page, so that a packaged desktop app can
# carry it and run on a machine that has no fyai of its own.
#
#   scripts/bundle-fyai.sh                 # build a portable one on this host
#   scripts/bundle-fyai.sh --from PATH     # copy an existing binary
#   scripts/bundle-fyai.sh --check         # report what would be bundled
#
# The result is fyai-bundle/fyai, built for the platform that runs the script,
# because the app is packaged for that platform. The build is the mostly-static
# one of the fyai repository (scripts/build-static-native.sh): the fyai
# libraries are linked in, and only the system libraries are needed: libSystem
# and the frameworks on macOS, the libc on Linux. The build files go to
# fyai-static-build/.
#
# --mode musl builds the fully static binary for a musl or an older Linux
# machine with Docker (scripts/build-static-docker.sh), but see the note in
# README.md: it sends "stream": 1 where the provider requires a boolean.
set -eu

cd "$(dirname "$0")/.."

OUT="fyai-bundle"
FROM=""
REPO="${FYAI_SRC:-../}"
MODE="${FYAI_STATIC_MODE:-mostly}"

usage() {
	cat <<'EOF'
Bundle a standalone fyai for the desktop app.

  scripts/bundle-fyai.sh                build a portable fyai on this host
  scripts/bundle-fyai.sh --from PATH    copy an existing binary
  scripts/bundle-fyai.sh --check        report what would be bundled

Options: --from PATH, --mode mostly|musl, --check, -h.
Environment: FYAI_SRC (the fyai repository, default the one above web/),
             FYAI_STATIC_MODE (mostly, the default, or musl).
`mostly` links the fyai dependencies statically over the system libraries;
`musl` is fully static, built with Docker, but bad JSON booleans.
FYAI_STATIC_BUILD names the directory for the build files.
EOF
	exit "${1:-0}"
}

CHECK=0
while [ $# -gt 0 ]; do
	case "$1" in
	--from)
		if [ $# -lt 2 ] || [ -z "$2" ]; then
			echo "bundle-fyai.sh: --from needs the path of a binary" >&2
			exit 1
		fi
		FROM="$2"
		shift 2
		;;
	--mode)
		if [ $# -lt 2 ] || [ -z "$2" ]; then
			echo "bundle-fyai.sh: --mode needs mostly or musl" >&2
			exit 1
		fi
		MODE="$2"
		shift 2
		;;
	--check) CHECK=1; shift ;;
	-h | --help) usage 0 ;;
	*) echo "bundle-fyai.sh: unknown option '$1'" >&2; usage 1 >&2 ;;
	esac
done

report() {
	local bin="$1"
	local other

	echo "bundle-fyai.sh: $bin"
	"$bin" --version 2>/dev/null | head -1 | sed 's/^/bundle-fyai.sh: /'
	if file "$bin" | grep -q "statically linked"; then
		echo "bundle-fyai.sh: static, so the app needs no fyai on the machine"
		return
	fi

	# The system libraries are the host's; anything else must travel.
	if [ "$(uname -s)" = Darwin ]; then
		other="$(otool -L "$bin" | tail -n +2 | awk '{print $1}' |
			grep -vE '^(/usr/lib/|/System/Library/)' || true)"
	else
		other="$(ldd "$bin" 2>/dev/null |
			awk '{print $1}' |
			grep -vE '^(linux-vdso|libc|libm|ld-linux|/lib.*ld-linux)' || true)"
	fi

	if [ -z "$other" ]; then
		echo "bundle-fyai.sh: needs only the system libraries, as every machine has"
	else
		echo "bundle-fyai.sh: needs these libraries, which the app does not carry:" >&2
		printf '  %s\n' "$other" >&2
		echo "bundle-fyai.sh: bundle a mostly or musl static build instead" >&2
	fi
}

if [ "$CHECK" = 1 ]; then
	if [ -x "$OUT/fyai" ]; then
		report "$OUT/fyai"
	else
		echo "bundle-fyai.sh: no $OUT/fyai yet"
	fi
	exit 0
fi

mkdir -p "$OUT"

if [ -n "$FROM" ]; then
	if [ ! -x "$FROM" ]; then
		echo "bundle-fyai.sh: '$FROM' is not an executable" >&2
		exit 1
	fi
	cp "$FROM" "$OUT/fyai"
	chmod 755 "$OUT/fyai"
	report "$OUT/fyai"
	exit 0
fi

if [ ! -d "$REPO/scripts" ] || [ ! -f "$REPO/scripts/build-static-native.sh" ]; then
	echo "bundle-fyai.sh: no fyai repository at '$REPO'; set FYAI_SRC" >&2
	exit 1
fi

if [ "$MODE" = musl ]; then
	if ! command -v docker >/dev/null 2>&1; then
		echo "bundle-fyai.sh: docker is needed for a musl fyai; use --from PATH" >&2
		exit 1
	fi
	echo "bundle-fyai.sh: building a musl fyai with Docker (this takes a while)"
	sh "$REPO/scripts/build-static-docker.sh" -m musl -o "$OUT/fyai"
else
	BUILD="${FYAI_STATIC_BUILD:-$PWD/fyai-static-build}"
	echo "bundle-fyai.sh: building a mostly-static fyai in $BUILD (this takes a while)"
	sh "$REPO/scripts/build-static-native.sh" -b "$BUILD" -o "$OUT/fyai"
fi
chmod 755 "$OUT/fyai"

report "$OUT/fyai"
